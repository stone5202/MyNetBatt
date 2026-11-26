// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation
import Combine

@MainActor
final class CaptiveStore: ObservableObject {
    static let shared = CaptiveStore()
    private let defaults = UserDefaults.standard
    private func k(_ name: String) -> String { CaptiveConfig.keyPrefix + name }

    @Published var rules: [NetworkRule] { didSet { saveRules() } }
    @Published var checkInterval: Double { didSet { defaults.set(checkInterval, forKey: k("checkInterval")) } }
    @Published var notifyOnSuccess: Bool { didSet { defaults.set(notifyOnSuccess, forKey: k("notifyOnSuccess")) } }
    /// 自動登入成功後，把 macOS 自己跳出的登入視窗（Captive Network Assistant）關掉
    @Published var closeSystemWindow: Bool { didSet { defaults.set(closeSystemWindow, forKey: k("closeSystemWindow")) } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: k("paused")) } }
    /// 最近的自動登入時間（統計用，最多留 200 筆）
    @Published private(set) var loginDates: [Date] { didSet { defaults.set(loginDates, forKey: k("loginDates")) } }

    /// 測試用：啟動參數 `-testTrustHost 127.0.0.1` 會把這個登入頁網域當成信任（不寫進設定）
    let testTrustHost: String? = UserDefaults.standard.string(forKey: "testTrustHost")

    private init() {
        let p = CaptiveConfig.keyPrefix
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: (p + "rules")),
           let decoded = try? JSONDecoder().decode([NetworkRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        let interval = defaults.double(forKey: (p + "checkInterval"))
        checkInterval = interval >= 2 ? interval : 20
        notifyOnSuccess = defaults.object(forKey: (p + "notifyOnSuccess")) as? Bool ?? true
        closeSystemWindow = defaults.object(forKey: (p + "closeSystemWindow")) as? Bool ?? true
        paused = defaults.bool(forKey: (p + "paused"))
        loginDates = defaults.array(forKey: (p + "loginDates")) as? [Date] ?? []
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: k("rules")) }
    }

    func rule(for ssid: String?, host: String?) -> NetworkRule? {
        if let r = rules.first(where: { $0.matches(ssid: ssid, host: host) }) { return r }
        if let t = testTrustHost, let host, t == host { return NetworkRule(portalHost: t) }
        return nil
    }

    func ruleIndex(id: UUID) -> Int? { rules.firstIndex { $0.id == id } }

    /// 加入目前的網路；已經有就回傳原本那一筆。
    @discardableResult
    func addRule(ssid: String?, portalHost: String?) -> NetworkRule {
        if let existing = rule(for: ssid, host: portalHost), ruleIndex(id: existing.id) != nil {
            // 補上缺的欄位
            if let i = ruleIndex(id: existing.id) {
                if rules[i].ssid == nil, let ssid { rules[i].ssid = ssid }
                if let portalHost { rules[i].addHost(portalHost) }
                return rules[i]
            }
        }
        let r = NetworkRule(ssid: ssid, portalHost: portalHost)
        rules.append(r)
        return r
    }

    func saveSteps(_ steps: [LearnedStep], ssid: String?, portalHost: String?) -> NetworkRule {
        let r = addRule(ssid: ssid, portalHost: portalHost)
        if let i = ruleIndex(id: r.id) { rules[i].steps = steps; return rules[i] }
        return r
    }

    func recordLogin() {
        if CaptiveConfig.testMode { return }
        loginDates.append(Date())
        if loginDates.count > 200 { loginDates.removeFirst(loginDates.count - 200) }
    }

    var loginsToday: Int {
        let cal = Calendar.current
        return loginDates.filter { cal.isDateInToday($0) }.count
    }
}
