import SwiftUI
import UserNotifications

// MARK: - 首次啟動導覽與新功能

/// 導覽與新功能各用一個小視窗；關閉時釋放。
@MainActor
final class IntroWindowController: NSObject, NSWindowDelegate {
    static let shared = IntroWindowController()

    /// 這一版要在「新功能」裡介紹的版本號；升到這一版的既有使用者第一次啟動時會看到。
    static let whatsNewVersion = "4.1"

    private var window: NSWindow?
    private weak var monitor: SystemMonitor?
    var onOpenMainWindow: (() -> Void)?

    /// 啟動時決定要不要顯示：全新安裝顯示導覽；從舊版升級顯示新功能。
    func showIfNeeded(monitor: SystemMonitor, isExistingUser: Bool) {
        self.monitor = monitor
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "onboardingCompleted") {
            if isExistingUser {
                // 舊版沒有導覽：已經在用的人不必再看一次，直接介紹新功能。
                defaults.set(true, forKey: "onboardingCompleted")
            } else {
                defaults.set(Self.whatsNewVersion, forKey: "whatsNewSeenVersion")
                showOnboarding(monitor: monitor)
                return
            }
        }
        if defaults.string(forKey: "whatsNewSeenVersion") != Self.whatsNewVersion {
            defaults.set(Self.whatsNewVersion, forKey: "whatsNewSeenVersion")
            showWhatsNew(monitor: monitor)
        }
    }

    func showOnboarding(monitor: SystemMonitor) {
        present(OnboardingView(monitor: monitor, close: { [weak self] in self?.finishOnboarding() }), size: NSSize(width: 620, height: 560))
    }

    func showWhatsNew(monitor: SystemMonitor) {
        present(WhatsNewView(monitor: monitor, close: { [weak self] in self?.window?.close() }), size: NSSize(width: 560, height: 700))
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        window?.close()
        onOpenMainWindow?()
    }

    private func present<Content: View>(_ content: Content, size: NSSize) {
        window?.close()
        let glass = monitor?.glassStyle ?? false
        let root = content
            .frame(width: size.width, height: size.height)
            .background { if glass { GlassWindowBackground(frost: monitor?.glassFrost ?? 0.6).ignoresSafeArea() } }
            .tint(monitor?.accentColor ?? .blue)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = "MyNetBatt"
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
        window.delegate = self
        window.setContentSize(size)
        window.center()
        switch monitor?.appearanceMode {
        case 1: window.appearance = NSAppearance(named: .aqua)
        case 2: window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 導覽沒按完就關掉也算看過，下次不再跳出。
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        window = nil
    }
}

// MARK: 導覽

private struct OnboardingView: View {
    @Bindable var monitor: SystemMonitor
    let close: () -> Void
    @State private var page = 0
    @State private var notificationsGranted: Bool?

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: menuBar
                case 2: permissions
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 34)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            .id(page)

            HStack {
                HStack(spacing: 7) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? monitor.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: index == page ? 18 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: page)
                Spacer()
                if page > 0 {
                    Button("上一步") { withAnimation(.snappy) { page -= 1 } }
                        .controlSize(.large)
                }
                Button(page == pageCount - 1 ? "開始使用" : "繼續") {
                    if page == pageCount - 1 { close() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("歡迎使用 MyNetBatt").font(.system(size: 30, weight: .bold))
            Text("電池、網路、系統效能與周邊裝置，都在選單列一眼看完。")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                feature("battery.100percent.bolt", .green, "電池健康與供電", "健康度趨勢、充電器與線材診斷、低耗電模式自動化")
                feature("arrow.up.arrow.down", .teal, "網路與 App 用量", "即時網速、每小時用量，以及每個 App 用了多少流量")
                feature("rectangle.3.group", .orange, "桌面小工具", "電池、數據用量、儲存空間、Wi‑Fi、周邊電量")
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("menubar.rectangle", .blue, "選單列", "選擇要放在選單列的項目，之後隨時可以在「設定 › 選單列」修改。")
            VStack(spacing: 0) {
                toggleRow("network", .teal, "網速與流量圖", $monitor.showNetModule)
                Divider().padding(.leading, 44)
                toggleRow("battery.100percent", .green, "電池電量", $monitor.showBatModule)
                Divider().padding(.leading, 44)
                toggleRow("cpu", .purple, "CPU 使用率", $monitor.showCpuItem)
                Divider().padding(.leading, 44)
                toggleRow("memorychip", .orange, "記憶體使用率", $monitor.showMemItem)
                Divider().padding(.leading, 44)
                toggleRow("internaldrive", .indigo, "儲存空間使用率", $monitor.showDiskItem)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .cardSurface(cornerRadius: 14)
            Text("點一下選單列的網路或電池圖示會打開小視窗；更多資訊在「監控中心」。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("hand.raised.fill", .indigo, "權限", "以下都可以略過，之後在設定裡再開啟。")
            VStack(spacing: 0) {
                permissionRow("bell.badge.fill", .red, "通知", "低電量、充滿、高溫與周邊裝置電量提醒") {
                    if notificationsGranted == true {
                        Label("已允許", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(notificationsGranted == false ? "開啟系統設定" : "允許") {
                            if notificationsGranted == false {
                                monitor.openNotificationSettings()
                            } else {
                                Task {
                                    let granted = await BatteryNotifier.shared.requestAuthorization()
                                    notificationsGranted = granted
                                    if granted { monitor.notifyLowBattery = true }
                                }
                            }
                        }
                    }
                }
                Divider().padding(.leading, 44)
                permissionRow("wifi", .blue, "Wi‑Fi 名稱", "macOS 需要定位權限才會提供 Wi‑Fi 名稱；不會記錄位置") {
                    if monitor.wifiInfo?.ssid != nil {
                        Label("已允許", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("允許") { monitor.requestWiFiNameAccess() }
                    }
                }
                Divider().padding(.leading, 44)
                permissionRow("power", .green, "開機時自動啟動", "登入後自動在選單列顯示") {
                    Toggle("開機時自動啟動", isOn: $monitor.isAutoStartEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .cardSurface(cornerRadius: 14)
            Spacer(minLength: 0)
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: notificationsGranted = true
            case .denied: notificationsGranted = false
            default: notificationsGranted = nil
            }
        }
    }

    private var finish: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
            Text("一切就緒").font(.system(size: 28, weight: .bold))
            VStack(alignment: .leading, spacing: 14) {
                feature("cursorarrow.click.2", .blue, "點選單列圖示", "打開網路或電池小視窗，齒輪按鈕進入設定")
                feature("rectangle.3.group", .orange, "加入桌面小工具", "在桌面上按右鍵 › 編輯小工具，搜尋「MyNetBatt」")
                feature("keyboard", .purple, "設定快捷鍵", "在「設定 › 進階」為監控中心與懸浮視窗設定快捷鍵")
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func header(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            IconChip(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconChip(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: symbol, color: color, size: 28)
            Text(title)
            Spacer()
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 8)
    }

    private func permissionRow<Accessory: View>(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(.vertical, 10)
    }
}

// MARK: 新功能

private struct WhatsNewView: View {
    @Bindable var monitor: SystemMonitor
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 72, height: 72)
                Text("MyNetBatt \(IntroWindowController.whatsNewVersion)").font(.system(size: 26, weight: .bold))
                Text("連接埠與線材，一目了然").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 34)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    item("cable.connector.horizontal", .blue, "連接埠分頁", "每個連接埠正在傳什麼、實際連線速度、是 Mac、線材還是裝置在限速，以及接了哪些顯示器與 Thunderbolt 設備。")
                    item("menubar.arrow.up.rectangle", .teal, "選單列連接埠狀態", "點一下就看到各連接埠的連線速度、線材規格與充電狀態；可以顯示輸入功率，線材限速時圖示會出現橘點。")
                    item("battery.100percent.bolt", .green, "為什麼沒在充電", "電池頁會說明正在充電、已充滿、充電暫停（充電上限或最佳化電池充電），或接著充電器電池仍在放電。")
                    item("bell.badge.fill", .red, "連接埠插拔通知", "接上裝置或線材時告訴你連線速度與線材規格，線材限速時特別提醒。")
                    item("list.bullet.rectangle", .gray, "技術細節", "支援的傳輸方式、插拔次數、過電流次數與線材識別碼，可在連接埠頁隨時開關。")
                }
                .padding(.horizontal, 44)
            }

            Button("繼續") { close() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.vertical, 22)
        }
    }

    private func item(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            IconChip(symbol: symbol, color: color, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
