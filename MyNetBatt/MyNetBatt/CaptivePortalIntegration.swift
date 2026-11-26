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
        #if DEBUG
        // 截圖用：-captiveDemo attention｜busy｜online，只設畫面上的狀態，不跑自動登入
        if let demo = UserDefaults.standard.string(forKey: "captiveDemo") {
            let status: CaptiveStatus = demo == "attention" ? .attention(String(localized: "找不到同意按鈕，請用「教學模式」按一次"))
                : demo == "busy" ? .loggingIn : .online
            CaptiveEngine.shared.demo(status: status, ssid: nil)
            return
        }
        #endif
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
        case .loggingIn, .reconnecting, .starting: return "shield.lefthalf.filled"
        case .captive, .attention: return "exclamationmark.shield.fill"
        case .offline: return "wifi.exclamationmark"
        case .paused: return "shield.slash"
        case .wifiOff, .notConnected: return "wifi.slash"
        }
    }
}

// MARK: - 網路小視窗：頁首盾牌按鈕＋需要處理時的提醒條（方案五）

/// 小視窗頁首、提醒條、狀態框共用的判斷與外觀。
/// 共用狀態規則：形狀＋顏色一起表示狀態（不只靠顏色），只有「需要處理」才有紅點。
@MainActor
struct CaptivePresentation {
    enum Action: Equatable { case nothing, attention(String), needLocation, addRule, enableRule(UUID) }

    let symbol: String
    let tint: Color?            // nil＝灰色（關閉、不在清單）
    let action: Action
    let busy: Bool              // 登入中／重連中：圖示脈動
    let title: String
    let detail: String
    let rule: NetworkRule?          // 這個網路的規則（啟用中才有）
    let disabledRule: NetworkRule?  // 這個網路有規則但被停用

    var needsAttention: Bool { action != .nothing }

    init(engine: CaptiveEngine, store: CaptiveStore, wifi: CaptiveWiFi) {
        let matched = engine.currentRule.flatMap { r in store.ruleIndex(id: r.id).map { store.rules[$0] } }
        let rule = matched?.enabled == true ? matched : nil
        let disabledRule = matched?.enabled == false ? matched : nil
        self.rule = rule
        self.disabledRule = disabledRule
        // 綠色只代表「這個網路受保護而且現在有網路」；沒網路、停用都不顯示綠色
        let protected = rule != nil && engine.status == .online
        var symbol = protected ? "checkmark.shield.fill" : "shield"
        var tint: Color? = protected ? .green : nil
        var action = Action.nothing
        var busy = false
        if store.paused {
            symbol = "shield.slash"; tint = nil
        } else {
            switch engine.status {
            case .attention(let msg):
                symbol = "exclamationmark.shield.fill"; tint = .orange; action = .attention(msg)
            case .loggingIn, .reconnecting, .starting:
                symbol = "shield.lefthalf.filled"; tint = .blue; busy = true
            case .captive where rule == nil:
                // 這個網路要登入但沒有啟用中的規則：停用的就請使用者啟用；讀不到名稱就先要權限；否則請使用者加入清單
                if let disabledRule {
                    action = .enableRule(disabledRule.id)
                } else if engine.ssid == nil, !wifi.locationAuthorized {
                    action = .needLocation
                } else if engine.ssid != nil || engine.portalURL != nil {
                    action = .addRule
                }
                if action != .nothing { symbol = "exclamationmark.shield.fill"; tint = .orange }
            default:
                break
            }
        }
        self.symbol = symbol
        self.tint = tint
        self.action = action
        self.busy = busy
        self.title = store.paused ? CaptiveStatus.paused.title : engine.status.title
        self.detail = Self.detail(engine: engine, store: store, wifi: wifi, rule: rule, disabled: disabledRule != nil)
    }

    /// 提醒條上的一行字
    var stripMessage: String {
        switch action {
        case .attention(let msg): return msg
        case .needLocation: return String(localized: "要先允許讀取 Wi‑Fi 名稱，才能自動登入")
        case .addRule: return String(localized: "這個網路需要登入，還沒加入自動登入")
        case .enableRule: return String(localized: "這個網路需要登入，但它的自動登入已停用")
        case .nothing: return ""
        }
    }

    private static func detail(engine: CaptiveEngine, store: CaptiveStore, wifi: CaptiveWiFi, rule: NetworkRule?, disabled: Bool) -> String {
        if store.paused { return String(localized: "已關閉，不會自動登入或重連") }
        if case .attention(let msg) = engine.status { return msg }
        let count = store.loginsToday
        if let rule {
            let base = rule.steps.isEmpty ? String(localized: "被踢時會自動按「同意／確認」") : String(localized: "被踢時會照教學的動作自動登入")
            return count > 0 ? String(localized: "\(base) · 今天自動登入 \(count) 次") : base
        }
        if disabled { return String(localized: "這個網路的自動登入已停用") }
        if engine.status == .captive { return String(localized: "這個網路需要登入，加入清單後就會自動處理") }
        if engine.ssid == nil, !wifi.locationAuthorized { return String(localized: "要先允許讀取 Wi‑Fi 名稱，才能把這個網路加入自動登入") }
        return String(localized: "這個網路不在自動登入清單")
    }

    /// 底色：有狀態色時帶色，灰色時跟「⋯」一樣淡；深色模式稍微加深才看得到邊界
    func background(_ scheme: ColorScheme) -> Color {
        if let tint { return tint.opacity(scheme == .dark ? 0.24 : 0.18) }
        return Color.secondary.opacity(scheme == .dark ? 0.14 : 0.08)
    }
}

/// 把目前網路加入自動登入清單（狀態框與提醒條共用）
@MainActor
private func captiveAddCurrentNetwork() {
    let engine = CaptiveEngine.shared
    CaptiveStore.shared.addRule(ssid: engine.ssid, portalHost: engine.portalURL?.host)
    engine.checkNow()
}

/// 重新啟用這個網路的規則
@MainActor
private func captiveEnableRule(_ id: UUID) {
    let store = CaptiveStore.shared
    guard let i = store.ruleIndex(id: id) else { return }
    store.rules[i].enabled = true
    CaptiveEngine.shared.checkNow()
}

/// 目前網路的名稱（加入清單、無障礙標籤用）
@MainActor
private var captiveCurrentName: String {
    CaptiveEngine.shared.ssid ?? CaptiveEngine.shared.portalURL?.host ?? String(localized: "這個網路")
}

/// 頁首、「⋯」旁邊的盾牌按鈕：和「⋯」一樣 34×28，點了跳出狀態框（開關在框裡）。
struct CaptiveHeaderButton: View {
    @Bindable var monitor: SystemMonitor
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var wifi = CaptiveWiFi.shared
    @ObservedObject private var store = CaptiveStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showStatus = false

    var body: some View {
        let p = CaptivePresentation(engine: engine, store: store, wifi: wifi)
        Button { showStatus.toggle() } label: {
            Image(systemName: p.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.tint ?? Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: p.busy)
                .frame(width: 34, height: 28)
                .background(p.background(scheme))
                .clipShape(Capsule())
                .overlay(alignment: .topTrailing) {
                    if p.needsAttention {
                        Circle().fill(Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Wi‑Fi 自動登入：\(p.title)"))
        .accessibilityLabel(String(localized: "Wi‑Fi 自動登入：\(p.title)"))
        .popover(isPresented: $showStatus, arrowEdge: .bottom) {
            CaptiveStatusPopover(monitor: monitor) { showStatus = false }
        }
    }
}

/// 點盾牌跳出的狀態框：標題列右邊是開關，下面是狀態與需要時的動作。
struct CaptiveStatusPopover: View {
    @Bindable var monitor: SystemMonitor
    let close: () -> Void
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var wifi = CaptiveWiFi.shared
    @ObservedObject private var store = CaptiveStore.shared

    var body: some View {
        let p = CaptivePresentation(engine: engine, store: store, wifi: wifi)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wi‑Fi 自動登入").font(.subheadline.bold())
                Spacer()
                Toggle("", isOn: Binding(get: { !store.paused }, set: { engine.setPaused(!$0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(Text("Wi‑Fi 自動登入"))
            }
            HStack(alignment: .top, spacing: 10) {
                IconChip(symbol: p.symbol, color: p.tint ?? .gray, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.subheadline.weight(.semibold))
                    Text(p.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            switch p.action {
            case .attention:
                HStack(spacing: 8) {
                    Button("打開登入頁") { close(); CaptivePortalWindow.show(learn: false) }
                        .buttonStyle(.borderedProminent)
                    Button("教學模式") { close(); CaptivePortalWindow.show(learn: true, ruleID: p.rule?.id) }
                }
                .controlSize(.small)
            case .needLocation:
                WiFiNameAccessButton(monitor: monitor)
            case .addRule:
                addButton(prominent: true)
            case .enableRule(let id):
                Button("啟用這個網路的自動登入") { captiveEnableRule(id) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .nothing:
                // 一般網路不提醒，但仍可以從這裡加入清單
                if !store.paused, p.rule == nil, engine.ssid != nil { addButton(prominent: false) }
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    @ViewBuilder
    private func addButton(prominent: Bool) -> some View {
        let b = Button { captiveAddCurrentNetwork() } label: {
            Label("把「\(engine.ssid ?? engine.portalURL?.host ?? "")」加入自動登入", systemImage: "plus.circle")
        }
        .controlSize(.small)
        if prominent { b.buttonStyle(.borderedProminent) } else { b }
    }
}

/// 需要處理時才從頁首下面滑出的一行提醒：說明＋一顆主要按鈕，處理完自動收起。
struct CaptiveAttentionStrip: View {
    @Bindable var monitor: SystemMonitor
    @ObservedObject private var engine = CaptiveEngine.shared
    @ObservedObject private var wifi = CaptiveWiFi.shared
    @ObservedObject private var store = CaptiveStore.shared
    @Environment(\.colorScheme) private var scheme

    /// 白字在按鈕上要夠清楚：比系統橘深一點
    private static let actionTint = Color(red: 0.70, green: 0.36, blue: 0.0)

    var body: some View {
        let p = CaptivePresentation(engine: engine, store: store, wifi: wifi)
        Group {
            if p.needsAttention {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(p.stripMessage)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .help(p.stripMessage)
                    Spacer(minLength: 4)
                    actionButton(p.action)
                        .buttonStyle(.borderedProminent)
                        .tint(Self.actionTint)
                        .controlSize(.small)
                }
                .padding(.vertical, 6).padding(.leading, 10).padding(.trailing, 6)
                .background(Color.orange.opacity(scheme == .dark ? 0.22 : 0.16),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: p.needsAttention)
    }

    @ViewBuilder
    private func actionButton(_ action: CaptivePresentation.Action) -> some View {
        switch action {
        case .attention:
            Button("打開登入頁") { CaptivePortalWindow.show(learn: false) }
                .accessibilityLabel(Text("打開「\(captiveCurrentName)」的登入頁"))
        case .needLocation:
            Button("允許…") { monitor.requestWiFiNameAccess() }
                .accessibilityLabel(Text("允許讀取 Wi‑Fi 名稱"))
        case .addRule:
            Button("加入清單") { captiveAddCurrentNetwork() }
                .accessibilityLabel(Text("把「\(captiveCurrentName)」加入自動登入"))
        case .enableRule(let id):
            Button("啟用") { captiveEnableRule(id) }
                .accessibilityLabel(Text("啟用「\(captiveCurrentName)」的自動登入"))
        case .nothing: EmptyView()
        }
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
            Toggle("登入成功後關閉系統跳出的登入視窗", isOn: $store.closeSystemWindow)
                .disabled(store.paused)
        } header: {
            Text("Wi‑Fi 自動登入")
        } footer: {
            Text("網路清單、教學模式與紀錄在監控中心的「網路」頁。清單是空的時候只在換網路或醒來時檢查一次。")
        }
    }
}
