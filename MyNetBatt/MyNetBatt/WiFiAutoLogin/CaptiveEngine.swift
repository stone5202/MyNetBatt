// 共用核心（見 CaptiveModels.swift 開頭說明）
import Combine
import Foundation
import Network
import AppKit
import UserNotifications

enum CaptiveStatus: Equatable {
    case starting, paused, wifiOff, notConnected, online, captive, loggingIn, offline, reconnecting
    case attention(String)

    var title: String {
        switch self {
        case .starting: return String(localized: "啟動中")
        case .paused: return String(localized: "已暫停")
        case .wifiOff: return String(localized: "Wi‑Fi 已關閉")
        case .notConnected: return String(localized: "沒有連上 Wi‑Fi")
        case .online: return String(localized: "已連網")
        case .captive: return String(localized: "需要登入")
        case .loggingIn: return String(localized: "自動登入中…")
        case .offline: return String(localized: "連上 Wi‑Fi 但沒有網路")
        case .reconnecting: return String(localized: "重新連線 Wi‑Fi 中…")
        case .attention: return String(localized: "需要你處理")
        }
    }

    var symbol: String {
        switch self {
        case .online: return "wifi"
        case .loggingIn, .reconnecting, .starting: return "arrow.triangle.2.circlepath"
        case .captive, .attention: return "wifi.exclamationmark"
        case .paused: return "pause.circle"
        case .wifiOff, .notConnected, .offline: return "wifi.slash"
        }
    }
}

/// 主流程：偵測網路變化、定時檢查、遇到登入頁就自動處理、斷線就重開 Wi‑Fi。
@MainActor
final class CaptiveEngine: ObservableObject {
    static let shared = CaptiveEngine()

    @Published private(set) var status: CaptiveStatus = .starting
    @Published private(set) var ssid: String?
    @Published private(set) var lastCheck: Date?
    /// 這次連線看到的登入頁（換網路就清掉）
    var portalURL: URL? { tracker.portalURL }

    private let store = CaptiveStore.shared
    let log = CaptiveLog.shared
    private let wifi = CaptiveWiFi.shared

    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var debounce: Task<Void, Never>?
    private var checking = false
    private var recheckRequested = false
    private var recheckForce = false
    private var tracker = NetworkTracker()
    private var notifiedUntrusted: Set<String> = []
    /// 每次暫停、換網路就加一；進行中的自動登入看到號碼變了就停
    private var generation = 0

    var probeURL: URL {
        if let s = UserDefaults.standard.string(forKey: "probeURL"), let u = URL(string: s) { return u }
        return CaptiveProbe.defaultURL
    }

    var currentRule: NetworkRule? { store.rule(for: ssid, host: portalURL?.host) }

    // MARK: - 啟動

    private(set) var started = false

    func start() {
        started = true
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { _ in
            Task { @MainActor in CaptiveEngine.shared.scheduleCheck(after: 2) }
        }
        m.start(queue: .main)
        monitor = m

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let engine = CaptiveEngine.shared
                engine.log.add(String(localized: "電腦醒來，檢查網路"))
                engine.scheduleCheck(after: 4)
            }
        }
        restartTimer()
        scheduleCheck(after: 1)
    }

    func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(2, store.checkInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(periodic: true) }
        }
        // 開著選單或拖曳視窗時也要繼續檢查
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 防抖：只取消「還在等」的那段，真正的檢查另外開工作，不會被取消到一半。
    func scheduleCheck(after seconds: Double) {
        guard started else { return }   // 測試、截圖模式不跑主流程
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            Task { @MainActor in await self?.check() }
        }
    }

    func setPaused(_ paused: Bool) {
        store.paused = paused
        generation += 1     // 進行中的自動登入會停下
        log.add(paused ? String(localized: "已暫停自動登入") : String(localized: "恢復自動登入"))
        if paused { setStatus(.paused) } else { scheduleCheck(after: 0.2) }
    }

    /// 使用者按「立即檢查」：清掉等待時間，馬上再試一次。
    func checkNow() {
        tracker.clearWaiting()
        tracker.resetReconnect()
        Task { await check(force: true) }
    }

    // MARK: - 檢查

    /// periodic：計時器觸發的定時檢查。清單裡沒有啟用的網路時不做定時連網檢查（省得一直連 Apple），
    /// 只在換網路、睡醒、手動檢查時檢查。
    func check(force: Bool = false, periodic: Bool = false) async {
        if checking {
            recheckRequested = true
            recheckForce = recheckForce || force
            return
        }
        if store.paused && !force { setStatus(.paused); return }
        checking = true
        defer {
            checking = false
            if recheckRequested {
                let f = recheckForce
                recheckRequested = false
                recheckForce = false
                Task { await self.check(force: f) }
            }
        }

        let snap = wifi.snapshot()
        let trusted = snap.ssid.map { store.rule(for: $0, host: nil)?.enabled == true } ?? false
        if tracker.observe(associated: snap.associated, ssid: snap.ssid, trusted: trusted, now: Date()) {
            generation += 1
        }
        ssid = snap.ssid
        lastCheck = Date()

        guard snap.powerOn else {
            setStatus(.wifiOff)
            return
        }
        guard snap.associated else {
            setStatus(.notConnected)
            await maybeReconnect(associated: false)
            return
        }

        if periodic, !force, store.testTrustHost == nil, !store.rules.contains(where: { $0.enabled }) { return }

        let gen = generation
        let result = await CaptiveProbe.check(probeURL)
        // 檢查途中換了網路或暫停了：這次結果不算
        if gen != generation || wifi.snapshot().ssid != snap.ssid {
            scheduleCheck(after: 0.5)
            return
        }
        switch result {
        case .online:
            tracker.recordOnline()
            setStatus(.online)

        case .captive(let url):
            tracker.setPortal(url)
            // 只用「這次」看到的登入頁網域比對，不沿用之前別的網路的
            let rule = store.rule(for: snap.ssid, host: url?.host)
            if let rule, rule.enabled {
                await autoLogin(rule: rule, start: url ?? probeURL, ssid: snap.ssid)
            } else {
                setStatus(.captive)
                notifyUntrusted(name: snap.ssid ?? url?.host ?? String(localized: "這個 Wi‑Fi"))
            }

        case .offline(let why):
            tracker.recordOffline()
            if status != .offline { log.add(String(localized: "連上 Wi‑Fi 但沒有網路（\(why)）"), .warning) }
            setStatus(.offline)
            await maybeReconnect(associated: true)

        case .inconclusive(let why):
            // 不算斷線、不重開 Wi‑Fi
            if lastInconclusive != why { log.add(String(localized: "這次無法判斷網路狀態（\(why)）"), .warning) }
            lastInconclusive = why

        case .cancelled:
            break
        }
        if case .inconclusive = result {} else { lastInconclusive = nil }
    }
    private var lastInconclusive: String?

    private func setStatus(_ new: CaptiveStatus) {
        guard new != status else { return }
        let old = status
        status = new
        switch new {
        case .online where old != .loggingIn && old != .starting:
            log.add(String(localized: "已連網\(ssid.map { String(localized: "（\($0)）") } ?? "")"), .success)
        case .captive:
            log.add(String(localized: "「\(ssid ?? portalURL?.host ?? String(localized: "這個網路"))」需要登入，但不在自動登入清單"), .warning)
        case .wifiOff:
            log.add(String(localized: "Wi‑Fi 已關閉"))
        case .notConnected where old != .reconnecting:
            log.add(String(localized: "沒有連上 Wi‑Fi"))
        default: break
        }
    }

    // MARK: - 自動登入

    private func autoLogin(rule: NetworkRule, start: URL, ssid loginSSID: String?) async {
        if let msg = tracker.waiting(rule: rule.id, now: Date()) {   // 這個網路剛失敗過，先等一下
            setStatus(.attention(msg))
            return
        }
        setStatus(.loggingIn)
        log.add(String(localized: "「\(rule.displayName)」需要登入，自動處理中"))
        let gen = generation
        let shouldContinue: () -> Bool = { [weak self] in
            guard let self else { return false }
            return gen == self.generation && !self.store.paused
                && Self.ruleStillActive(rule, in: self.store.rules, testTrustHost: self.store.testTrustHost)
                && self.wifi.snapshot().ssid == loginSSID
        }
        // 先直接送表單（綁 Wi‑Fi 介面、不開網頁，最快）；看不懂的頁面、讀不到或有教學步驟才用網頁
        var outcome: AgentOutcome?
        if rule.steps.isEmpty {
            outcome = await DirectPortal.run(startURL: start, probeURL: probeURL, shouldContinue: shouldContinue,
                                             log: { [log] in log.add($0) })
        }
        if outcome == nil {
            let agent = PortalAgent()
            outcome = await agent.run(startURL: start, steps: rule.steps, probeURL: probeURL,
                                      shouldContinue: shouldContinue, log: { [log] in log.add($0) })
        }
        guard let outcome else { return }
        if gen != generation || store.paused {
            log.add(String(localized: "自動登入已中止（暫停或換了網路）"))
            if store.paused { setStatus(.paused) } else { scheduleCheck(after: 0.5) }
            return
        }
        switch outcome {
        case .success(let text):
            // 只有成功才記下登入頁網域（沒有定位權限時用來認網路）
            // 記下這次被轉去的登入頁網域（同一個網路可能有好幾台防火牆）。
            // 用一開始被轉去的網址，不用網頁最後停的地方（可能是登入後跳去的醫院首頁）。
            if let host = start.host, host != probeURL.host, let i = store.ruleIndex(id: rule.id),
               store.rules[i].addHost(host) {
                log.add(String(localized: "記下「\(rule.displayName)」的登入頁：\(host)"))
            }
            store.recordLogin()
            tracker.recordOnline()
            setStatus(.online)
            let what = text.map { String(localized: "按下「\($0)」") } ?? String(localized: "網路已恢復")
            log.add(String(localized: "自動登入成功（\(what)）"), .success)
            if store.closeSystemWindow { CaptiveSystemWindow.closeAfterLogin(log: log) }
            if store.notifyOnSuccess {
                CaptiveConfig.notify(String(localized: "已自動重新連上網路"), String(localized: "\(rule.displayName)：\(what)"), false)
            }
        case .needsInput(let field):
            fail(String(localized: "登入頁要輸入\(field)，請自己登入"), retryIn: 300, rule: rule)
        case .noButton(let names):
            if !names.isEmpty { log.add(String(localized: "頁面上的按鈕：\(names.joined(separator: String(localized: "、")))")) }
            fail(String(localized: "找不到同意按鈕，請用「教學模式」按一次"), retryIn: 120, rule: rule)
        case .failed(let msg):
            fail(msg, retryIn: 90, rule: rule)
        case .cancelled:
            scheduleCheck(after: 0.5)
        }
    }

    private func fail(_ message: String, retryIn seconds: TimeInterval, rule: NetworkRule) {
        let first = tracker.recordFailure(rule: rule.id, message: message, retryIn: seconds, now: Date())
        setStatus(.attention(message))
        log.add(message, .warning)
        if first {
            CaptiveConfig.notify(String(localized: "「\(rule.displayName)」沒辦法自動登入"), message + String(localized: "（按這裡打開登入頁）"), true)
        }
    }

    private func notifyUntrusted(name: String) {
        guard !notifiedUntrusted.contains(name) else { return }
        notifiedUntrusted.insert(name)
        CaptiveConfig.notify(String(localized: "「\(name)」需要登入"), String(localized: "要讓它以後自動按同意，請把它加入自動登入清單。"), true)
    }

    // MARK: - 斷線重連

    private func maybeReconnect(associated: Bool) async {
        guard let target = tracker.reconnectTarget(
            associated: associated, currentSSID: ssid,
            allows: { [store] s in
                guard let r = store.rule(for: s, host: nil) else { return false }
                return r.enabled && r.autoReconnect
            }, now: Date()) else { return }
        tracker.didReconnect(now: Date())
        setStatus(.reconnecting)
        log.add(associated ? String(localized: "「\(target)」一直沒有網路，重新連線 Wi‑Fi（第 \(tracker.reconnectAttempts) 次）")
                           : String(localized: "「\(target)」斷線了，重新連線 Wi‑Fi（第 \(tracker.reconnectAttempts) 次）"), .warning)
        let ok = await wifi.powerCycle()
        if !ok { log.add(String(localized: "重開 Wi‑Fi 失敗，請手動開啟 Wi‑Fi"), .warning) }
        scheduleCheck(after: 10)
    }

    /// 自動登入途中規則還有效嗎：要還在清單裡而且啟用（被刪掉就停）。
    /// 測試模式（-testTrustHost）的臨時規則不在清單裡，依網域判斷。
    nonisolated static func ruleStillActive(_ rule: NetworkRule, in rules: [NetworkRule], testTrustHost: String?) -> Bool {
        if let r = rules.first(where: { $0.id == rule.id }) { return r.enabled }
        if let t = testTrustHost, rule.portalHost == t { return true }
        return false
    }

    // MARK: - 測試用

    /// 截圖用：直接設定畫面上的狀態（只在 -snapshot 時呼叫）
    func demo(status: CaptiveStatus, ssid: String?) {
        self.status = status
        self.ssid = ssid
        self.lastCheck = Date()
    }

    /// `-autoLoginOnce`：檢查一次，被攔就（不看清單）直接自動登入，結束碼 0＝成功。
    func runOnceForTest() async -> Int32 {
        let r = await CaptiveProbe.check(probeURL)
        log.add("連網檢查：\(r.label)")
        guard case .captive(let url) = r else { return r == .online ? 2 : 3 }
        var outcome = await DirectPortal.run(startURL: url ?? probeURL, probeURL: probeURL,
                                             shouldContinue: { true }, log: { [log] in log.add($0) })
        if outcome == nil {
            let agent = PortalAgent()
            outcome = await agent.run(startURL: url ?? probeURL, steps: [], probeURL: probeURL,
                                      shouldContinue: { true }, log: { [log] in log.add($0) })
        }
        guard let outcome else { return 1 }
        switch outcome {
        case .success(let t): log.add("成功：\(t ?? "-")", .success); return 0
        case .needsInput(let f): log.add("需要輸入：\(f)"); return 4
        case .noButton(let n): log.add("找不到按鈕：\(n)"); return 5
        case .failed(let m): log.add("失敗：\(m)"); return 1
        case .cancelled: return 6
        }
    }
}

// MARK: - 系統的登入視窗

/// macOS 偵測到登入頁時會自己跳出「Captive Network Assistant」視窗。我們已經登入成功的話，它會一直留在畫面上，
/// 所以確認連網後幫使用者關掉（和使用者自己按關閉一樣，用一般的結束要求，不強制結束）。
/// 視窗有時比我們晚跳出來，所以 1、4、10 秒後各看一次。
@MainActor
enum CaptiveSystemWindow {
    static let bundleID = "com.apple.CaptiveNetworkAssistant"

    static func closeAfterLogin(log: CaptiveLog) {
        Task { @MainActor in
            var closed = false
            for delay in [1.0, 3.0, 6.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // 這段時間又斷線（例如被踢）就不關，讓使用者看得到登入頁
                guard CaptiveEngine.shared.status == .online else { return }
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where app.terminate() {
                    closed = true
                }
            }
            if closed { log.add(String(localized: "已關閉系統的登入視窗")) }
        }
    }
}
