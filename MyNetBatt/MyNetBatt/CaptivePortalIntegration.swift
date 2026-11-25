import SwiftUI
import AppKit
import UserNotifications

// MARK: - Wi‑Fi 自動登入（整合）
// 核心在 WiFiAutoLogin/ 資料夾，和獨立 App「Wi‑Fi 自動登入」共用同一份程式，
// 由那個專案的 tools/sync-mynetbatt.sh 同步過來；不要直接改 WiFiAutoLogin/ 裡的檔案。
// 這裡只放 MyNetBatt 自己的部分：啟動設定、登入頁視窗、小視窗卡片、監控中心面板與設定區塊。

enum CaptivePortalIntegration {
    /// 在 applicationDidFinishLaunching 呼叫。
    static func start() {
        CaptiveConfig.keyPrefix = "captive."            // 偏好設定不和 MyNetBatt 自己的撞名
        CaptiveConfig.logFolder = "MyNetBatt/WiFiAutoLogin"
        CaptiveConfig.requestLocationOnLaunch = false    // MyNetBatt 有自己的「允許讀取 Wi‑Fi 名稱」流程
        CaptiveConfig.notify = { title, body, openPortal in
            BatteryNotifier.shared.post(id: "captive.\(openPortal ? "attention" : "success")", title: title, body: body,
                                        sound: true, userInfo: openPortal ? ["openCaptivePortal": true] : [:])
        }
        CaptiveConfig.openPortal = { learn, ruleID in CaptivePortalWindow.show(learn: learn, ruleID: ruleID) }
        CaptiveEngine.shared.start()
    }

    /// 結束時：正在重開 Wi‑Fi 就先打開。
    static func stop() {
        CaptiveWiFi.shared.restoreIfNeeded()
    }
}

/// 登入頁視窗（手動登入／教學模式），每次從關閉狀態打開都放在畫面正中間。
@MainActor
enum CaptivePortalWindow {
    private static var window: NSWindow?
    private static var model: PortalWindowModel?

    static func show(learn: Bool, ruleID: UUID? = nil) {
        var isNew = false
        if window == nil {
            isNew = true
            let m = PortalWindowModel()
            let w = NSWindow(contentViewController: NSHostingController(rootView: PortalView(model: m)))
            w.title = String(localized: "登入頁")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 860, height: 680))
            w.isReleasedWhenClosed = false
            window = w
            model = m
        }
        if isNew { model?.loadPortal() }
        if learn { model?.startLearning(ruleID: ruleID) }
        guard let w = window else { return }
        if !w.isVisible {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                let area = screen.visibleFrame, size = w.frame.size
                w.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 共用的狀態文字與顏色

extension CaptiveStatus {
    var tint: Color {
        switch self {
        case .online: return .green
        case .loggingIn, .reconnecting, .starting: return .blue
        case .captive, .attention, .offline: return .orange
        case .paused, .wifiOff, .notConnected: return .gray
        }
    }

    var chipSymbol: String {
        switch self {
        case .online: return "checkmark.shield.fill"
        case .loggingIn, .reconnecting, .starting: return "arrow.triangle.2.circlepath"
        case .captive, .attention: return "exclamationmark.shield.fill"
        case .offline: return "wifi.exclamationmark"
        case .paused: return "pause.fill"
        case .wifiOff, .notConnected: return "wifi.slash"
        }
    }
}

// MARK: - 網路小視窗頁首的開關（取代原本的卡片）

/// 網路小視窗頁首、Wi‑Fi 名稱旁的膠囊：左半邊點了跳出狀態與動作，右半邊是開關。
/// 需要使用者處理時（被踢、這個網路還不在清單、要先允許讀取 Wi‑Fi 名稱）圖示變橘色並加小紅點。
struct CaptiveHeaderToggle: View {
    @Bindable var monitor: SystemMonitor
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var wifi = CaptiveWiFi.shared
    @ObservedObject private var store = CaptiveStore.shared
    @State private var showStatus = false

    private var rule: NetworkRule? {
        guard let r = engine.currentRule, store.ruleIndex(id: r.id) != nil else { return nil }
        return r
    }

    private enum Action { case nothing, attention, needLocation, addRule }

    private var action: Action {
        if store.paused { return .nothing }
        if case .attention = engine.status { return .attention }
        guard rule == nil else { return .nothing }
        if engine.ssid == nil, !wifi.locationAuthorized { return engine.status == .captive ? .needLocation : .nothing }
        if engine.ssid != nil || engine.portalURL != nil { return engine.status == .captive ? .addRule : .nothing }
        return .nothing
    }

    /// 只在真的需要處理時提醒；一般網路不在清單裡不算。
    private var needsAttention: Bool { action != .nothing }

    var body: some View {
        HStack(spacing: 4) {
            Button { showStatus.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.paused ? "shield.slash" : engine.status.chipSymbol)
                        .font(.caption.bold())
                        .foregroundStyle(store.paused ? Color.secondary : (needsAttention ? .orange : engine.status.tint))
                        .overlay(alignment: .topTrailing) {
                            if needsAttention {
                                Circle().fill(.red).frame(width: 6, height: 6).offset(x: 3, y: -2)
                            }
                        }
                    Text("自動登入").font(.caption.weight(.semibold))
                        .foregroundStyle(store.paused ? .secondary : .primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Wi‑Fi 自動登入的狀態"))
            .popover(isPresented: $showStatus, arrowEdge: .bottom) { statusPopover }

            Toggle("", isOn: Binding(get: { !store.paused }, set: { engine.setPaused(!$0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.leading, 9).padding(.trailing, 5)
        .frame(height: 28)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
        .fixedSize()
    }

    private var statusPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wi‑Fi 自動登入", systemImage: "checkmark.shield")
                .font(.subheadline.bold())
            HStack(alignment: .top, spacing: 10) {
                IconChip(symbol: store.paused ? "pause.fill" : engine.status.chipSymbol,
                         color: store.paused ? .gray : engine.status.tint, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.paused ? CaptiveStatus.paused.title : engine.status.title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            switch action {
            case .attention:
                HStack(spacing: 8) {
                    Button("打開登入頁") { showStatus = false; CaptivePortalWindow.show(learn: false) }
                    Button("教學模式") { showStatus = false; CaptivePortalWindow.show(learn: true, ruleID: rule?.id) }
                }
                .controlSize(.small)
            case .needLocation:
                // 讀不到 Wi‑Fi 名稱就沒辦法加入清單：用 MyNetBatt 原本的按鈕要定位權限
                WiFiNameAccessButton(monitor: monitor)
            case .addRule:
                addRuleButton
            case .nothing:
                // 一般網路不提醒，但仍可以從這裡加入清單
                if !store.paused, rule == nil, engine.ssid != nil { addRuleButton }
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    private var addRuleButton: some View {
        Button {
            store.addRule(ssid: engine.ssid, portalHost: engine.portalURL?.host)
            engine.checkNow()
        } label: {
            Label("把「\(engine.ssid ?? engine.portalURL?.host ?? "")」加入自動登入", systemImage: "plus.circle")
        }
        .controlSize(.small)
    }

    private var detail: String {
        if store.paused { return String(localized: "已關閉，不會自動登入或重連") }
        if case .attention(let msg) = engine.status { return msg }
        let count = store.loginsToday
        if let rule {
            let base = rule.steps.isEmpty ? String(localized: "被踢時會自動按「同意／確認」") : String(localized: "被踢時會照教學的動作自動登入")
            return count > 0 ? String(localized: "\(base) · 今天自動登入 \(count) 次") : base
        }
        if engine.status == .captive { return String(localized: "這個網路需要登入，加入清單後就會自動處理") }
        if engine.ssid == nil, !wifi.locationAuthorized { return String(localized: "要先允許讀取 Wi‑Fi 名稱，才能把這個網路加入自動登入") }
        return String(localized: "這個網路不在自動登入清單")
    }
}

// MARK: - 監控中心「網路」頁的面板

struct CaptivePortalPanel: View {
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var store = CaptiveStore.shared

    var body: some View {
        Panel(title: "Wi‑Fi 自動登入", symbol: "checkmark.shield.fill", color: .teal, accessory: {
            Toggle("啟用", isOn: Binding(get: { !store.paused }, set: { engine.setPaused(!$0) }))
                .toggleStyle(.switch).controlSize(.small)
        }) {
            Text("醫院、咖啡店等公用 Wi‑Fi 被踢掉、需要再按「同意／確認」時，在背景自動按下並恢復網路。只處理下面清單裡的網路，不會幫你填帳號密碼。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                IconChip(symbol: engine.status.chipSymbol, color: engine.status.tint, size: 24)
                Text(engine.status.title).font(.subheadline.weight(.semibold))
                if case .attention(let msg) = engine.status {
                    Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Text("今天自動登入 \(store.loginsToday) 次").font(.caption).foregroundStyle(.secondary)
                Button { engine.checkNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("立即檢查")
                Button { CaptivePortalWindow.show(learn: false) } label: { Image(systemName: "safari") }
                    .buttonStyle(.plain).help("打開登入頁")
            }
            CaptiveNetworksView()
                .frame(height: 230)
            DisclosureGroup("紀錄") {
                CaptiveLogView().frame(height: 220)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - 設定頁的區塊

struct CaptivePortalSettingsSection: View {
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var store = CaptiveStore.shared

    var body: some View {
        Section {
            Toggle("啟用 Wi‑Fi 自動登入", isOn: Binding(get: { !store.paused }, set: { engine.setPaused(!$0) }))
            Picker("多久檢查一次網路", selection: $store.checkInterval) {
                Text("10 秒").tag(10.0)
                Text("20 秒").tag(20.0)
                Text("30 秒").tag(30.0)
                Text("1 分鐘").tag(60.0)
            }
            .onChange(of: store.checkInterval) { _, _ in engine.restartTimer() }
            .disabled(store.paused)
            Toggle("自動登入成功時通知", isOn: $store.notifyOnSuccess)
                .disabled(store.paused)
        } header: {
            Text("Wi‑Fi 自動登入")
        } footer: {
            Text("網路清單、教學模式與紀錄在監控中心的「網路」頁。清單是空的時候只在換網路或醒來時檢查一次。")
        }
    }
}
