import SwiftUI
import Charts

// MARK: - 監控中心

/// 側邊欄的分頁。rawValue 沿用舊版的字串（選單列項目、齒輪按鈕會直接指定分頁）。
enum MainTab: String, CaseIterable, Identifiable {
    case overview, battery, network, system, storage, devices, ports, settings, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "總覽"
        case .battery: return "電池"
        case .network: return "網路"
        case .system: return "系統效能"
        case .storage: return "儲存空間"
        case .devices: return "周邊裝置"
        case .ports: return "連接埠"
        case .settings: return "設定"
        case .about: return "關於"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .battery: return "battery.100percent.bolt"
        case .network: return "network"
        case .system: return "cpu.fill"
        case .storage: return "internaldrive.fill"
        case .devices: return "keyboard.fill"
        case .ports: return "cable.connector.horizontal"
        case .settings: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: return .blue
        case .battery: return .green
        case .network: return .teal
        case .system: return .purple
        case .storage: return .indigo
        case .devices: return .orange
        case .ports: return .blue
        case .settings: return .gray
        case .about: return Color(white: 0.5)
        }
    }

    static let monitoring: [MainTab] = [.overview, .battery, .network, .system, .storage, .devices, .ports]
}

struct MainWindowView: View {
    @Bindable var monitor: SystemMonitor

    private var tab: MainTab { MainTab(rawValue: monitor.mainWindowTab) ?? .overview }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 240)
        } detail: {
            Group {
                switch tab {
                case .overview: OverviewView(monitor: monitor)
                case .battery: BatteryDetailView(monitor: monitor)
                case .network: NetworkDetailView(monitor: monitor)
                case .system: SystemDetailView(monitor: monitor)
                case .storage: StorageDetailView(monitor: monitor)
                case .devices: DevicesDetailView(monitor: monitor)
                case .ports: PortsDetailView(monitor: monitor)
                case .settings: SettingsDetailView(monitor: monitor)
                case .about: AboutView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 切換分頁不加淡入淡出：過場時新舊頁面都是半透明，玻璃質感的底色會跟著變淡、露出視窗後方的畫面。
            // 玻璃質感時拿掉設定表單與內容區的不透明底色，露出視窗的玻璃材質。
            .scrollContentBackground(monitor.glassStyle ? .hidden : .automatic)
            .background { if monitor.glassStyle { GlassWindowBackground(frost: monitor.glassFrost).ignoresSafeArea() } }
            // 玻璃質感時標題列是透明的：在標題列的位置再鋪一層材質，捲上去的內容才不會和視窗標題疊在一起。
            .overlay(alignment: .top) {
                if monitor.glassStyle {
                    GeometryReader { geo in
                        GlassWindowBackground(frost: monitor.glassFrost)
                            .frame(height: geo.safeAreaInsets.top)
                            .offset(y: -geo.safeAreaInsets.top)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 920, minHeight: 660)
        .tint(monitor.accentColor)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MyNetBatt").font(.headline)
                    Text("版本 \(AppInfo.version)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("監控")
                    ForEach(MainTab.monitoring) { SidebarRow(monitor: monitor, tab: $0) }
                    sectionLabel("App").padding(.top, 10)
                    SidebarRow(monitor: monitor, tab: .settings)
                    SidebarRow(monitor: monitor, tab: .about)
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 0) {
                Divider()
                Toggle("開機時自動啟動", isOn: $monitor.isAutoStartEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }
}

/// 側邊欄的一列：系統設定風格的彩色圖示底塊；選取時填滿 App 的強調色，滑鼠移過時先給一層淡底。
/// （系統的側邊欄 List 選取色只跟隨 macOS 強調色，不吃 .tint，所以自己畫。）
private struct SidebarRow: View {
    @Bindable var monitor: SystemMonitor
    let tab: MainTab
    @State private var hovering = false

    var body: some View {
        let isSelected = monitor.mainWindowTab == tab.rawValue
        Button { monitor.mainWindowTab = tab.rawValue } label: {
            HStack(spacing: 9) {
                IconChip(symbol: tab.symbol, color: tab.color, size: 22)
                Text(tab.title)
                    .foregroundStyle(isSelected ? monitor.accentContrastColor : Color.primary)
                Spacer(minLength: 0)
                if tab == .devices, !monitor.peripherals.isEmpty {
                    Text("\(monitor.peripherals.count)")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(isSelected ? monitor.accentContrastColor.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                isSelected ? monitor.accentColor : (hovering ? Color.secondary.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "--" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "--" }
    static let repositoryURL = URL(string: "https://github.com/stone5202/MyNetBatt")!
    static let releasesURL = URL(string: "https://github.com/stone5202/MyNetBatt/releases")!
    static let issuesURL = URL(string: "https://github.com/stone5202/MyNetBatt/issues")!
}

/// 監控中心在玻璃質感時的底：透出後方內容的系統材質，再壓一層底色讓文字好讀。
/// 深色材質疊在亮色內容上會變成中灰，卡片外的文字（尤其設定頁沒有卡片襯底）不夠清楚；
/// 所有分頁用同一個程度，切換時背景才一致。
struct GlassWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 設定的霧化程度（0～1）；預設 0.6 時深色疊黑 62%、淺色疊白 50%。深色的範圍是 45%～90%。
    let frost: Double

    var body: some View {
        ZStack {
            BehindWindowMaterial()
            if colorScheme == .dark {
                // 深色材質疊在亮色內容上會變成中灰，白字看不清楚，所以最通透時也保留 45% 的黑；
                // 0.6 以下變化較緩，預設值的外觀不變。
                Color.black.opacity(frost < 0.6 ? 0.45 + 0.17 * frost / 0.6 : 0.62 + 0.28 * (frost - 0.6) / 0.4)
            } else {
                Color.white.opacity(0.14 + 0.6 * frost)
            }
        }
    }
}

// MARK: - 總覽

struct OverviewView: View {
    @Bindable var monitor: SystemMonitor
    private let columns = [GridItem(.adaptive(minimum: 236), spacing: 14)]

    private func open(_ tab: MainTab) { monitor.mainWindowTab = tab.rawValue }

    var body: some View {
        PageScroll {
            PageHeader(
                title: "總覽",
                subtitle: [monitor.macModelStr, Date().formatted(date: .complete, time: .omitted)].filter { !$0.isEmpty && $0 != String(localized: "讀取中...") }.joined(separator: " · "),
                symbol: MainTab.overview.symbol, color: MainTab.overview.color
            )

            LazyVGrid(columns: columns, spacing: 14) {
                batteryTile
                networkTile
                systemTile
                storageTile
                wifiTile
                devicesTile
            }

            HStack(alignment: .top, spacing: 14) {
                Panel(title: "今日 App 數據用量", symbol: "app.badge", color: .teal, accessory: {
                    Text(monitor.formatBytesForUI(monitor.appDataUsageTotal(days: 1)))
                        .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }) {
                    OverviewAppUsage(monitor: monitor)
                }
                Panel(title: "過去 48 小時電量", symbol: "chart.bar.fill", color: .green) {
                    BatteryHistoryChart(history: monitor.batteryHistory, height: 120)
                }
            }
        }
        .onAppear { monitor.setBatteryDetailVisible(true, source: "overview") }
        .onDisappear { monitor.setBatteryDetailVisible(false, source: "overview") }
    }

    private var batteryTile: some View {
        OverviewTile(title: "電池", symbol: "battery.100percent", color: .green, action: { open(.battery) }) {
            HStack(spacing: 16) {
                RingGauge(fraction: Double(monitor.batPct) / 100, color: monitor.displayedBatteryColor, lineWidth: 9) {
                    VStack(spacing: 0) {
                        Text("\(monitor.batPct)%").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        if monitor.isPluggedIn {
                            Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(monitor.batteryPowerSource).font(.callout.weight(.semibold)).lineLimit(2)
                    tileLine(monitor.batteryTimeTitle, monitor.batTimeRemain)
                    tileLine(String(localized: "健康度"), monitor.batHealth)
                    tileLine(String(localized: "循環次數"), monitor.batCycle)
                }
            }
        }
    }

    private var networkTile: some View {
        OverviewTile(title: "網路", symbol: "arrow.up.arrow.down", color: .teal, action: { open(.network) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    speed("arrow.up", monitor.upSpeedStr, Palette.upload)
                    speed("arrow.down", monitor.downSpeedStr, Palette.download)
                }
                Chart(monitor.trafficHistory) { point in
                    AreaMark(x: .value("t", point.time), y: .value("down", point.downloadSpeed))
                        .foregroundStyle(LinearGradient(colors: [Palette.download.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", point.time), y: .value("down", point.downloadSpeed), series: .value("s", "down"))
                        .foregroundStyle(Palette.download).interpolationMethod(.monotone)
                    LineMark(x: .value("t", point.time), y: .value("up", point.uploadSpeed), series: .value("s", "up"))
                        .foregroundStyle(Palette.upload).interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 46)
                Text("今日 ↑ \(monitor.todayUpStr)  ↓ \(monitor.todayDownStr)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var systemTile: some View {
        OverviewTile(title: "系統效能", symbol: "cpu.fill", color: .purple, action: { open(.system) }) {
            HStack(spacing: 14) {
                miniRing("CPU", monitor.currentCpuUsage, .purple)
                miniRing("記憶體", monitor.ramUsagePct, monitor.memoryPressureLevel >= 4 ? .red : (monitor.memoryPressureLevel >= 2 ? .yellow : .blue))
                miniRing("GPU", monitor.currentGpuUsage, .green)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var storageTile: some View {
        OverviewTile(title: "儲存空間", symbol: "internaldrive.fill", color: .indigo, action: { open(.storage) }) {
            HStack(spacing: 16) {
                RingGauge(fraction: monitor.diskUsagePct / 100, color: monitor.diskUsagePct > 90 ? .red : .indigo, lineWidth: 9) {
                    VStack(spacing: 0) {
                        Text(String(format: "%.0f%%", monitor.diskUsagePct)).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("已使用").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Macintosh HD").font(.callout.weight(.semibold))
                    tileLine(String(localized: "可用"), monitor.diskFreeStr)
                    tileLine(String(localized: "容量"), monitor.diskTotalStr)
                    let external = monitor.storageVolumes.filter { !$0.isInternal }.count
                    if external > 0 { tileLine(String(localized: "外接磁碟"), "\(external)") }
                }
            }
        }
    }

    private var wifiTile: some View {
        OverviewTile(title: "連線", symbol: monitor.wifiInfo == nil ? "network" : "wifi", color: .blue, action: { open(.network) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    if let wifi = monitor.wifiInfo {
                        SignalStrengthBars(bars: SystemMonitor.signalBars(rssi: wifi.rssi), color: .blue).frame(width: 26, height: 20)
                    }
                    Text(monitor.wifiInfo?.ssid ?? (monitor.wifiInfo != nil ? "Wi‑Fi" : monitor.networkInterfaceName))
                        .font(.title3.weight(.semibold)).lineLimit(1)
                }
                tileLine(String(localized: "本機 IP"), monitor.networkLocalIP)
                tileLine(String(localized: "公網 IP"), monitor.networkPublicIP)
                if let wifi = monitor.wifiInfo { tileLine(String(localized: "訊號"), wifi.rssiText) }
            }
        }
    }

    private var devicesTile: some View {
        OverviewTile(title: "周邊裝置", symbol: "keyboard.fill", color: .orange, action: { open(.devices) }) {
            if monitor.peripherals.isEmpty {
                Text("沒有連線中、會回報電量的藍牙周邊。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(monitor.peripherals.prefix(4)) { device in
                        VStack(spacing: 5) {
                            RingGauge(fraction: Double(device.primaryLevel ?? 0) / 100, color: PeripheralCard.color(device.primaryLevel), lineWidth: 5) {
                                Image(systemName: device.symbol).font(.system(size: 15))
                            }
                            .frame(width: 50, height: 50)
                            Text(device.primaryLevel.map { "\($0)%" } ?? "--").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        .help(device.name)
                    }
                }
            }
        }
    }

    private func tileLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.caption)
    }

    private func speed(_ symbol: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func miniRing(_ title: LocalizedStringKey, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RingGauge(fraction: value / 100, color: color, lineWidth: 7) {
                Text("\(Int(value.rounded()))%").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 62, height: 62)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 今天用量最多的 5 個 App。
private struct OverviewAppUsage: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        let items = Array(monitor.appDataUsageItems(days: 1).prefix(5))
        let peak = Double(max(items.map(\.bytes).max() ?? 1, 1))
        if items.isEmpty {
            Text("今天還沒有 App 用量紀錄。").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            VStack(spacing: 9) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        AppIconView(pid: item.pid, name: item.name, bundlePath: item.bundlePath, size: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name).font(.callout).lineLimit(1)
                                Spacer()
                                Text(monitor.formatBytesForUI(item.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            MeterBar(value: Double(item.bytes), total: peak, color: .teal, height: 4)
                        }
                    }
                }
            }
        }
    }
}

/// 四格訊號強度。
struct SignalStrengthBars: View {
    let bars: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: geo.size.width * 0.08) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < bars ? AnyShapeStyle(color) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(height: geo.size.height * CGFloat(index + 1) / 4)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel(Text("訊號 \(bars) 格"))
    }
}
