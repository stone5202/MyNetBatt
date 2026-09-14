import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement

// MARK: - App 進入點
@main
struct MyNetBattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - 系統控制核心
class AppDelegate: NSObject, NSApplicationDelegate {
    var netItem: NSStatusItem!
    var batItem: NSStatusItem!
    var netPopover: NSPopover!
    var batPopover: NSPopover!
    var settingsWindow: NSWindow!
    
    let monitor = SystemMonitor()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        setupPopovers()
        setupStatusBar()
        setupSettingsWindow()
        
        monitor.layoutChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusBarWidths() }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsWindow), name: NSNotification.Name("OpenSettings"), object: nil)
        
        updateStatusBarWidths()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }
    
    @objc func openSettingsWindow() {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupPopovers() {
        netPopover = NSPopover()
        netPopover.behavior = .transient
        netPopover.contentSize = NSSize(width: 320, height: 420)
        netPopover.contentViewController = NSHostingController(rootView: NetworkPopoverView(monitor: monitor))

        batPopover = NSPopover()
        batPopover.behavior = .transient
        batPopover.contentSize = NSSize(width: 280, height: 420)
        batPopover.contentViewController = NSHostingController(rootView: BatteryPopoverView(monitor: monitor))
    }
    
    private func setupStatusBar() {
        netItem = NSStatusBar.system.statusItem(withLength: 1)
        if let button = netItem.button {
            let host = NSHostingView(rootView: NetworkBarView(monitor: monitor).allowsHitTesting(false))
            host.layer?.backgroundColor = NSColor.clear.cgColor
            button.addSubview(host)
            button.action = #selector(toggleNetPopover)
        }

        batItem = NSStatusBar.system.statusItem(withLength: 1)
        if let button = batItem.button {
            let host = NSHostingView(rootView: BatteryBarView(monitor: monitor).allowsHitTesting(false))
            host.layer?.backgroundColor = NSColor.clear.cgColor
            button.addSubview(host)
            button.action = #selector(toggleBatPopover)
        }
    }
    
    @objc func updateStatusBarWidths() {
        if let btn = netItem.button {
            var nW: CGFloat = 6
            if monitor.showNetChart { nW += 32 }
            if monitor.showNetSpeed { nW += 48 }
            if monitor.showNetChart && monitor.showNetSpeed { nW += 4 }
            let finalNetWidth = max(nW, 1)
            netItem.length = finalNetWidth
            btn.subviews.first?.frame = NSRect(x: 0, y: 0, width: finalNetWidth, height: 22)
        }
        
        if let btn = batItem.button {
            var bW: CGFloat = 8
            if monitor.showBatText { bW += 38 } // 微調縮減電池寬度，但確保 100% 不會變成 ...
            if monitor.showBatIcon { bW += 18 }
            if monitor.showBatText && monitor.showBatIcon { bW += 4 }
            let finalBatWidth = max(bW, 1)
            batItem.length = finalBatWidth
            btn.subviews.first?.frame = NSRect(x: 0, y: 0, width: finalBatWidth, height: 22)
        }
        
        netItem.isVisible = monitor.showNetModule
        batItem.isVisible = monitor.showBatModule
    }
    
    private func setupSettingsWindow() {
        let hostingController = NSHostingController(rootView: MainWindowView(monitor: monitor))
        settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.title = "MyNetBatt 監控中心"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
    }

    @objc func toggleNetPopover(_ sender: AnyObject?) {
        if netPopover.isShown { netPopover.performClose(sender) }
        else { if let btn = netItem.button { netPopover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) } }
    }

    @objc func toggleBatPopover(_ sender: AnyObject?) {
        if batPopover.isShown { batPopover.performClose(sender) }
        else { if let btn = batItem.button { batPopover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) } }
    }
}

// MARK: - 主視窗：側邊欄控制中心
struct MainWindowView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var selectedTab: String? = "battery"
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("控制中心").font(.headline).padding(.horizontal)
                    Spacer()
                }
                .padding(.vertical, 16)
                
                Divider()
                
                List(selection: $selectedTab) {
                    Label("電池狀態", systemImage: "battery.100").tag("battery")
                    Label("網路監控", systemImage: "network").tag("network")
                    Label("系統效能", systemImage: "cpu").tag("system")
                }
                .listStyle(SidebarListStyle())
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Toggle("開機自啟", isOn: $monitor.isAutoStartEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .padding()
                }
            }
        } detail: {
            Group {
                if selectedTab == "battery" {
                    BatteryDetailView(monitor: monitor)
                } else if selectedTab == "network" {
                    NetworkDetailView(monitor: monitor)
                } else {
                    SystemDetailView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
        .frame(minWidth: 850, minHeight: 650)
    }
}

// MARK: - 系統效能視窗
struct SystemDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("硬體與系統效能").font(.largeTitle.bold())
            
            VStack(spacing: 12) {
                SystemInfoRow(icon: "macbook", color: .gray, title: "Mac 型號", value: monitor.macModelStr)
                SystemInfoRow(icon: "cpu", color: .purple, title: "處理器 (CPU)", value: monitor.cpuModelStr)
                SystemInfoRow(icon: "memorychip", color: .orange, title: "顯示卡 (GPU)", value: monitor.gpuModelStr)
            }
            .padding(16).background(Color.secondary.opacity(0.1)).cornerRadius(12)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                SystemCard(icon: "speedometer", title: "CPU 負載", value: String(format: "%.1f %%", monitor.currentCpuUsage), progress: monitor.currentCpuUsage, color: .purple)
                SystemCard(icon: "memorychip.fill", title: "實體記憶體", value: monitor.ramUsageStr, progress: monitor.ramUsagePct, color: .blue)
                SystemCard(icon: "arrow.up.arrow.down.circle.fill", title: "Swap 虛擬記憶體", value: monitor.swapUsageStr, progress: monitor.swapUsagePct, color: .orange)
                SystemCard(icon: "internaldrive.fill", title: "儲存空間", value: monitor.diskUsageStr, progress: monitor.diskUsagePct, color: .indigo)
            }
            
            Text("CPU 即時負載趨勢").font(.headline).foregroundColor(.secondary).padding(.top, 4)
            Chart {
                ForEach(monitor.cpuHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.purple.opacity(0.4), .clear]), startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(minHeight: 120).chartYScale(domain: 0...100).chartXAxis(.hidden)
            
            Spacer()
        }
    }
}

struct SystemCard: View {
    let icon: String
    let title: String
    let value: String
    let progress: Double
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(title).font(.headline)
                Spacer()
            }
            Text(value).font(.subheadline).monospacedDigit().bold()
            ProgressView(value: progress, total: 100.0).tint(color)
        }
        .padding(16).background(Color.secondary.opacity(0.1)).cornerRadius(12)
    }
}

struct SystemInfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(color).frame(width: 24)
            Text(title).foregroundColor(.secondary).font(.headline)
            Spacer()
            Text(value).bold().font(.headline)
        }
    }
}

// MARK: - 網路詳細視窗
struct NetworkDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("網路流量監控").font(.largeTitle.bold())
            
            HStack {
                Text("上傳流量").font(.title3.bold())
                Spacer()
                Text("↑ \(monitor.upSpeedStr)").foregroundColor(.green).font(.title2.bold().monospacedDigit())
            }
            Chart {
                ForEach(monitor.trafficHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("上傳", data.uploadSpeed)).foregroundStyle(.green)
                    AreaMark(x: .value("時間", data.time), y: .value("上傳", data.uploadSpeed))
                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.green.opacity(0.3), .clear]), startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(minHeight: 120).chartXAxis(.hidden)
            
            HStack {
                Text("下載流量").font(.title3.bold())
                Spacer()
                Text("↓ \(monitor.downSpeedStr)").foregroundColor(.cyan).font(.title2.bold().monospacedDigit())
            }
            Chart {
                ForEach(monitor.trafficHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("下載", data.downloadSpeed)).foregroundStyle(.cyan)
                    AreaMark(x: .value("時間", data.time), y: .value("下載", data.downloadSpeed))
                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.cyan.opacity(0.3), .clear]), startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(minHeight: 120).chartXAxis(.hidden)
            
            Spacer()
            Divider()
            HStack(spacing: 20) {
                Toggle("啟用網路模組", isOn: $monitor.showNetModule)
                Toggle("狀態列圖表", isOn: $monitor.showNetChart)
                Toggle("狀態列數字", isOn: $monitor.showNetSpeed)
                Spacer()
            }
            .toggleStyle(.switch).tint(.cyan)
        }
        .padding(24)
    }
}

// MARK: - 電池詳細視窗
struct BatteryDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("電池與電源狀態").font(.largeTitle.bold())
            
            HStack(spacing: 20) {
                Image(systemName: monitor.batteryIcon)
                    .resizable().scaledToFit().frame(height: 50).foregroundColor(monitor.batteryColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.batteryStatus).font(.system(size: 40, weight: .bold).monospacedDigit())
                    Text(monitor.batteryPowerSource).font(.title3).foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 10)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                InfoBox(title: "供電來源", value: monitor.batSourceType, icon: "powerplug.fill", color: .green)
                InfoBox(title: "時間預估", value: monitor.batTimeRemain, icon: "hourglass", color: .blue)
                InfoBox(title: "健康度", value: monitor.batHealth, icon: "heart.fill", color: .red)
                InfoBox(title: "循環次數", value: monitor.batCycle, icon: "arrow.3.trianglepath", color: .purple)
                InfoBox(title: "電池溫度", value: monitor.batTemp, icon: "thermometer", color: .orange)
                InfoBox(title: "即時功率", value: monitor.batWatts, icon: "bolt.fill", color: .yellow)
            }
            
            Text("電量變化趨勢").font(.title3.bold()).foregroundColor(.secondary).padding(.top, 16)
            Chart {
                ForEach(monitor.batteryHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("電量", data.level))
                        .foregroundStyle(monitor.batteryColor)
                        .interpolationMethod(.monotone)
                }
            }
            .frame(minHeight: 130).chartYScale(domain: 0...100).chartXAxis(.hidden)
            
            Spacer()
            Divider()
            HStack(spacing: 20) {
                Toggle("啟用電池模組", isOn: $monitor.showBatModule)
                Toggle("狀態列圖示", isOn: $monitor.showBatIcon)
                Toggle("狀態列百分比", isOn: $monitor.showBatText)
                Spacer()
            }
            .toggleStyle(.switch).tint(.green)
        }
        .padding(24)
    }
}

// MARK: - 網路子視窗 (Popover)
struct NetworkPopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("網路流量 (30秒)").font(.headline)
            
            Text("↑ 上傳").font(.caption).foregroundColor(.green)
            Chart {
                ForEach(monitor.trafficHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("上傳", data.uploadSpeed)).foregroundStyle(.green)
                    AreaMark(x: .value("時間", data.time), y: .value("上傳", data.uploadSpeed))
                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.green.opacity(0.3), .clear]), startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(height: 80).chartYAxis { AxisMarks(position: .leading) }.chartXAxis(.hidden)
            
            Text("↓ 下載").font(.caption).foregroundColor(.cyan)
            Chart {
                ForEach(monitor.trafficHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("下載", data.downloadSpeed)).foregroundStyle(.cyan)
                    AreaMark(x: .value("時間", data.time), y: .value("下載", data.downloadSpeed))
                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.cyan.opacity(0.3), .clear]), startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(height: 80).chartYAxis { AxisMarks(position: .leading) }.chartXAxis(.hidden)
            
            Divider()
            HStack(spacing: 12) {
                Toggle("流量圖表", isOn: $monitor.showNetChart)
                Toggle("流量數字", isOn: $monitor.showNetSpeed)
                Spacer()
            }
            .toggleStyle(.switch).tint(.blue).controlSize(.mini)
            
            Divider()
            HStack {
                Button("結束程式") { NSApplication.shared.terminate(nil) }.controlSize(.small)
                Spacer()
                Text("啟用").font(.caption).foregroundColor(.secondary)
                Toggle("", isOn: $monitor.showNetModule).labelsHidden().toggleStyle(.switch).tint(.blue).controlSize(.mini)
                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil) }) {
                    Image(systemName: "gearshape.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(16).frame(width: 320)
    }
}

// MARK: - 電池子視窗 (Popover)
struct BatteryPopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("電池詳細資訊").font(.headline)
            
            HStack(spacing: 16) {
                Image(systemName: monitor.batteryIcon)
                    .resizable().scaledToFit().frame(height: 30).foregroundColor(monitor.batteryColor)
                VStack(alignment: .leading) {
                    Text(monitor.batteryStatus).font(.system(size: 24, weight: .bold).monospacedDigit())
                    Text(monitor.batteryPowerSource).font(.caption).foregroundColor(.secondary)
                }
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                InfoBox(title: "供電來源", value: monitor.batSourceType, icon: "powerplug.fill", color: .green)
                InfoBox(title: "預估時間", value: monitor.batTimeRemain, icon: "hourglass", color: .blue)
                InfoBox(title: "健康度", value: monitor.batHealth, icon: "heart.fill", color: .red)
                InfoBox(title: "循環", value: monitor.batCycle, icon: "arrow.3.trianglepath", color: .purple)
                InfoBox(title: "溫度", value: monitor.batTemp, icon: "thermometer", color: .orange)
                InfoBox(title: "功率", value: monitor.batWatts, icon: "bolt.fill", color: .yellow)
            }
            
            Divider()
            HStack(spacing: 12) {
                Toggle("電池圖示", isOn: $monitor.showBatIcon)
                Toggle("電量百分比", isOn: $monitor.showBatText)
                Spacer()
            }
            .toggleStyle(.switch).tint(.green).controlSize(.mini)
            
            Divider()
            HStack {
                Button("結束程式") { NSApplication.shared.terminate(nil) }.controlSize(.small)
                Spacer()
                Text("啟用").font(.caption).foregroundColor(.secondary)
                Toggle("", isOn: $monitor.showBatModule).labelsHidden().toggleStyle(.switch).tint(.green).controlSize(.mini)
                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil) }) {
                    Image(systemName: "gearshape.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(16).frame(width: 280)
    }
}

// MARK: - UI 共用元件
struct InfoBox: View {
    let title: String
    let value: String
    var icon: String? = nil
    var color: Color = .secondary
    
    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(8)
    }
}

struct NetworkBarView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 4) {
            if monitor.showNetChart {
                MiniGraphView(
                    history: Array(monitor.trafficHistory.suffix(5)),
                    globalMaxDl: monitor.trafficHistory.map(\.downloadSpeed).max() ?? 1,
                    globalMaxUl: monitor.trafficHistory.map(\.uploadSpeed).max() ?? 1
                )
            }
            if monitor.showNetSpeed {
                VStack(alignment: .leading, spacing: -2) {
                    Text("↑ \(monitor.upSpeedStr)").foregroundColor(.green)
                    Text("↓ \(monitor.downSpeedStr)").foregroundColor(.cyan)
                }
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .frame(width: 48, alignment: .leading)
            }
        }
        .padding(.horizontal, 2).frame(maxHeight: .infinity)
    }
}

struct BatteryBarView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 2) {
            if monitor.showBatText {
                Text(monitor.batteryStatus).font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            if monitor.showBatIcon {
                Image(systemName: monitor.batteryIcon)
                    .foregroundColor(monitor.batteryColor) // 確保顏色隨電量變化生效
            }
        }
        .padding(.horizontal, 2).frame(maxHeight: .infinity)
    }
}

struct MiniGraphView: View {
    var history: [TrafficData]
    var globalMaxDl: Double
    var globalMaxUl: Double
    
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.red.opacity(0.15)))
            guard history.count > 1 else { return }
            
            let maxDl = max(globalMaxDl, 102400)
            let maxUl = max(globalMaxUl, 102400)
            var dlPath = Path(); var ulPath = Path()
            let maxPoints = 5
            let stepX = size.width / CGFloat(maxPoints - 1)
            
            for (i, data) in history.enumerated() {
                let x = CGFloat(i) * stepX
                let dlY = size.height - (CGFloat(data.downloadSpeed / maxDl) * size.height)
                let ulY = size.height - (CGFloat(data.uploadSpeed / maxUl) * size.height)
                if i == 0 { dlPath.move(to: CGPoint(x: x, y: dlY)); ulPath.move(to: CGPoint(x: x, y: ulY)) }
                else { dlPath.addLine(to: CGPoint(x: x, y: dlY)); ulPath.addLine(to: CGPoint(x: x, y: ulY)) }
            }
            
            var dlArea = dlPath; dlArea.addLine(to: CGPoint(x: CGFloat(history.count - 1) * stepX, y: size.height)); dlArea.addLine(to: CGPoint(x: 0, y: size.height)); dlArea.closeSubpath()
            context.fill(dlArea, with: .color(.cyan.opacity(0.3)))
            
            var ulArea = ulPath; ulArea.addLine(to: CGPoint(x: CGFloat(history.count - 1) * stepX, y: size.height)); ulArea.addLine(to: CGPoint(x: 0, y: size.height)); ulArea.closeSubpath()
            context.fill(ulArea, with: .color(.green.opacity(0.3)))
            
            context.stroke(dlPath, with: .color(.cyan), lineWidth: 1.0)
            context.stroke(ulPath, with: .color(.green), lineWidth: 1.0)
        }
        .frame(width: 30, height: 16).cornerRadius(3)
    }
}

// MARK: - 資料結構與監控邏輯
struct TrafficData: Identifiable { let id = UUID(); let time: Date; let downloadSpeed: Double; let uploadSpeed: Double }
struct BatteryData: Identifiable { let id = UUID(); let time: Date; let level: Int }
struct SimpleData: Identifiable { let id = UUID(); let time: Date; let value: Double }

@MainActor
class SystemMonitor: ObservableObject {
    let layoutChanged = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()

    @Published var showNetModule: Bool { didSet { UserDefaults.standard.set(showNetModule, forKey: "showNetModule") } }
    @Published var showBatModule: Bool { didSet { UserDefaults.standard.set(showBatModule, forKey: "showBatModule") } }
    @Published var showNetChart: Bool { didSet { UserDefaults.standard.set(showNetChart, forKey: "showNetChart") } }
    @Published var showNetSpeed: Bool { didSet { UserDefaults.standard.set(showNetSpeed, forKey: "showNetSpeed") } }
    @Published var showBatIcon: Bool { didSet { UserDefaults.standard.set(showBatIcon, forKey: "showBatIcon") } }
    @Published var showBatText: Bool { didSet { UserDefaults.standard.set(showBatText, forKey: "showBatText") } }
    
    @Published var isAutoStartEnabled: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if isAutoStartEnabled {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
            } catch { print("Auto Start Error: \(error)") }
        }
    }

    @Published var upSpeedStr: String = "0 B/s"
    @Published var downSpeedStr: String = "0 B/s"
    @Published var trafficHistory: [TrafficData] = []
    
    @Published var batteryStatus: String = "--%"
    @Published var batteryIcon: String = "battery.100"
    @Published var batteryColor: Color = .green
    @Published var batteryPowerSource: String = "讀取中..."
    @Published var batHealth: String = "--"
    @Published var batCycle: String = "--"
    @Published var batTemp: String = "--"
    @Published var batWatts: String = "--"
    @Published var batSourceType: String = "--"
    @Published var batTimeRemain: String = "--"
    @Published var batteryHistory: [BatteryData] = []
    
    @Published var cpuModelStr: String = "讀取中..."
    @Published var macModelStr: String = "讀取中..."
    @Published var gpuModelStr: String = "讀取中..."
    @Published var ramUsageStr: String = "讀取中..."
    @Published var ramUsagePct: Double = 0.0
    @Published var swapUsageStr: String = "讀取中..."
    @Published var swapUsagePct: Double = 0.0
    @Published var diskUsageStr: String = "讀取中..."
    @Published var diskUsagePct: Double = 0.0
    @Published var currentCpuUsage: Double = 0.0
    @Published var cpuHistory: [SimpleData] = []

    private var lastInBytes: UInt64 = 0
    private var lastOutBytes: UInt64 = 0

    init() {
        UserDefaults.standard.register(defaults: [
            "showNetModule": true, "showBatModule": true,
            "showNetChart": true, "showNetSpeed": true,
            "showBatIcon": true, "showBatText": true
        ])
        showNetModule = UserDefaults.standard.bool(forKey: "showNetModule")
        showBatModule = UserDefaults.standard.bool(forKey: "showBatModule")
        showNetChart = UserDefaults.standard.bool(forKey: "showNetChart")
        showNetSpeed = UserDefaults.standard.bool(forKey: "showNetSpeed")
        showBatIcon = UserDefaults.standard.bool(forKey: "showBatIcon")
        showBatText = UserDefaults.standard.bool(forKey: "showBatText")

        Publishers.MergeMany(
            $showNetModule.map { _ in }, $showBatModule.map { _ in },
            $showNetChart.map { _ in }, $showNetSpeed.map { _ in },
            $showBatIcon.map { _ in }, $showBatText.map { _ in }
        )
        .sink { [weak self] in self?.layoutChanged.send() }
        .store(in: &cancellables)

        startNetworkSpeedMonitor()
        startDetailedBatteryMonitor()
        startSystemInfoMonitor()
    }
    
    nonisolated private func runCommand(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private func extract(pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        if match.numberOfRanges > 1 {
            let range = Range(match.range(at: 1), in: text)!
            return String(text[range])
        }
        return nil
    }

    private func startNetworkSpeedMonitor() {
        Task { while !Task.isCancelled { fetchNetworkTraffic(); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
    }
    
    private func startDetailedBatteryMonitor() {
        Task { while !Task.isCancelled { fetchDynamicBatteryInfo(); try? await Task.sleep(nanoseconds: 3_000_000_000) } }
    }
    
    private func startSystemInfoMonitor() {
        Task { while !Task.isCancelled { fetchSystemInfo(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }

    private func fetchSystemInfo() {
        Task.detached {
            var cpuModel = self.runCommand("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cpuModel.isEmpty { cpuModel = "Apple Silicon Processor" }
            
            let macModel = self.runCommand("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let gpuModel = cpuModel.contains("Apple") ? "Apple 整合繪圖核心 (GPU)" : "內建顯示晶片"
            
            // 計算 RAM
            let memBytes = ProcessInfo.processInfo.physicalMemory
            let totalRamGb = Double(memBytes) / 1_073_741_824.0
            let vmStatOut = self.runCommand("/usr/bin/vm_stat", [])
            var pageSize: Double = 16384
            var activePages = 0.0, wiredPages = 0.0, compressedPages = 0.0
            
            for line in vmStatOut.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let valStr = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                    let val = Double(valStr) ?? 0.0
                    if key.contains("page size of") { pageSize = val }
                    else if key == "Pages active" { activePages = val }
                    else if key == "Pages wired down" { wiredPages = val }
                    else if key == "Pages occupied by compressor" { compressedPages = val }
                }
            }
            let usedRamGb = ((activePages + wiredPages + compressedPages) * pageSize) / 1_073_741_824.0
            let ramStr = String(format: "%.1f GB / %.0f GB", usedRamGb, totalRamGb)
            let rPct = (usedRamGb / totalRamGb) * 100.0
            
            // 計算 Swap
            let sysctlSwap = self.runCommand("/usr/sbin/sysctl", ["vm.swapusage"])
            var swapStr = "0 MB"
            var sPct = 0.0
            if let usedVal = self.extract(pattern: "used = ([0-9.]+[M|G]?)", from: sysctlSwap) {
                swapStr = usedVal.contains("M") || usedVal.contains("G") ? usedVal : "\(usedVal) M"
                if let totalVal = self.extract(pattern: "total = ([0-9.]+)[M|G]?", from: sysctlSwap),
                   let u = Double(usedVal.replacingOccurrences(of: "M", with: "").replacingOccurrences(of: "G", with: "")),
                   let t = Double(totalVal), t > 0 {
                    sPct = (u / t) * 100.0
                }
            }
            
            // 計算 SSD
            var dStr = "-- GB / -- GB"
            var dPct = 0.0
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
               let free = attrs[.systemFreeSize] as? NSNumber, let total = attrs[.systemSize] as? NSNumber {
                let tGB = total.doubleValue / 1_073_741_824.0
                let fGB = free.doubleValue / 1_073_741_824.0
                let uGB = tGB - fGB
                dStr = String(format: "%.0f GB / %.0f GB", uGB, tGB)
                dPct = (uGB / tGB) * 100.0
            }
            
            // 計算 CPU (取 top -l 2 的第二次結果來獲得準確負載)
            let topOut = self.runCommand("/usr/bin/top", ["-l", "2", "-n", "0"])
            var cUsage = 0.0
            let lines = topOut.components(separatedBy: .newlines).filter { $0.contains("CPU usage:") }
            if let lastLine = lines.last,
               let idleStr = self.extract(pattern: "([0-9.]+)\\s*%", from: lastLine.components(separatedBy: "sys,").last ?? lastLine),
               let idle = Double(idleStr) {
                cUsage = 100.0 - idle
            } else if let fallbackIdle = self.extract(pattern: "([0-9.]+)%\\s*idle", from: lines.last ?? ""), let idle = Double(fallbackIdle) {
                cUsage = 100.0 - idle
            }
            
            let fCpu = cpuModel, fMac = macModel, fGpu = gpuModel, fRam = ramStr, fSwap = swapStr, fUsage = cUsage
            let fRamPct = rPct, fSwapPct = sPct, fDisk = dStr, fDiskPct = dPct
            await MainActor.run {
                self.cpuModelStr = fCpu; self.macModelStr = fMac; self.gpuModelStr = fGpu
                self.ramUsageStr = fRam; self.ramUsagePct = fRamPct
                self.swapUsageStr = fSwap; self.swapUsagePct = fSwapPct
                self.diskUsageStr = fDisk; self.diskUsagePct = fDiskPct
                self.currentCpuUsage = fUsage
                self.cpuHistory.append(SimpleData(time: Date(), value: fUsage))
                if self.cpuHistory.count > 30 { self.cpuHistory.removeFirst() }
            }
        }
    }

    private func fetchDynamicBatteryInfo() {
        Task.detached {
            var tempPct = 0
            var tempCharging = false
            var tempPlugged = false
            var batType = "電池供電"
            var timeRemain = "計算中..."
            
            let pmOutput = self.runCommand("/usr/bin/pmset", ["-g", "batt"])
            tempPlugged = pmOutput.contains("AC Power")
            tempCharging = tempPlugged && !pmOutput.contains("discharging") && !pmOutput.contains("charged")
            if tempPlugged { batType = "變壓器 (AC)" }
            
            if let val = self.extract(pattern: "(\\d+)%", from: pmOutput) { tempPct = Int(val) ?? 0 }
            
            if let t = self.extract(pattern: "(\\d+:\\d+) remaining", from: pmOutput) { timeRemain = "\(t) 可用" }
            else if let t = self.extract(pattern: "(\\d+:\\d+) until full", from: pmOutput) { timeRemain = "\(t) 充滿" }
            else if tempPct == 100 || pmOutput.contains("charged") { timeRemain = "已充滿" }
            
            var cycle = "--", tempStr = "--", healthPctStr = "--%"
            var maxCap = 0.0, designCap = 0.0, voltage = 0.0, amperage = 0.0
            
            for line in pmOutput.components(separatedBy: .newlines) {
                let clean = line.replacingOccurrences(of: " ", with: "")
                if clean.contains("temperature=") {
                    if let t = Double(clean.components(separatedBy: "=").last ?? "0"), t > 0 { tempStr = String(format: "%.1f°C", t > 200 ? t / 100.0 : t) }
                }
            }
            
            let ioOutput1 = self.runCommand("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery"])
            let ioOutput2 = self.runCommand("/usr/sbin/ioreg", ["-r", "-c", "IOPMPowerSource"])
            let combinedOutput = ioOutput1 + "\n" + ioOutput2
            
            for line in combinedOutput.components(separatedBy: .newlines) {
                let clean = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "").lowercased()
                if clean.contains("cyclecount=") { cycle = clean.components(separatedBy: "=").last ?? cycle }
                
                if tempStr == "--" && (clean.contains("temperature=") || clean.contains("batterytemperature=")) {
                    let parts = clean.components(separatedBy: "=")
                    if let valStr = parts.last, let t = Double(valStr), t > 5 {
                        let finalT = t > 200 ? t / 100.0 : t
                        if finalT > 10 && finalT < 90 { tempStr = String(format: "%.1f°C", finalT) }
                    }
                }
                
                if clean.contains("maxcapacity=") || clean.contains("applerawmaxcapacity=") {
                    if let c = Double(clean.components(separatedBy: "=").last ?? "0"), c > 0 { maxCap = c }
                }
                if clean.contains("designcapacity=") {
                    if let d = Double(clean.components(separatedBy: "=").last ?? "0"), d > 0 { designCap = d }
                }
                if clean.contains("voltage=") || clean.contains("batteryvoltage=") {
                    if let v = Double(clean.components(separatedBy: "=").last ?? "0"), v > 0 { voltage = v }
                }
                if clean.contains("amperage=") || clean.contains("instantamperage=") {
                    let vStr = clean.components(separatedBy: "=").last ?? "0"
                    if let uVal = UInt64(vStr) { amperage = Double(Int64(bitPattern: uVal)) }
                    else if let iVal = Int64(vStr) { amperage = Double(iVal) }
                }
            }
            
            let spOutput = self.runCommand("/usr/sbin/system_profiler", ["SPPowerDataType"])
            for line in spOutput.components(separatedBy: .newlines) {
                if line.contains("Cycle Count:") { cycle = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? cycle }
                if line.contains("Maximum Capacity:") { healthPctStr = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? healthPctStr }
            }
            if healthPctStr == "--%" && designCap > 0 && maxCap > 0 { healthPctStr = "\(Int((maxCap / designCap) * 100))%" }
            
            let powerWatts = abs((voltage * amperage) / 1_000_000.0)
            let wattsStr = powerWatts > 0 ? String(format: "%.2f W", powerWatts) : "--"
            
            var tIcon = "battery.100"
            var tColor = Color.primary
            
            if tempCharging {
                if tempPct > 80 { tIcon = "battery.100.bolt" }
                else if tempPct > 50 { tIcon = "battery.75.bolt" }
                else if tempPct > 25 { tIcon = "battery.50.bolt" }
                else { tIcon = "battery.25.bolt" }
                tColor = .green
            } else {
                if tempPct > 80 { tIcon = "battery.100"; tColor = .primary }
                else if tempPct > 60 { tIcon = "battery.75"; tColor = .primary }
                else if tempPct > 35 { tIcon = "battery.50"; tColor = .primary }
                else if tempPct > 15 { tIcon = "battery.25"; tColor = .orange }
                else { tIcon = "battery.0"; tColor = .red }
            }
            
            let fSource = tempCharging ? "充電中" : (tempPlugged ? "已接上電源" : "放電中")
            let fStatus = "\(tempPct)%"
            let fIcon = tIcon, fColor = tColor, fTemp = tempStr, fWatts = wattsStr, fPct = tempPct, fCycle = cycle, fHealth = healthPctStr
            let fType = batType, fTime = timeRemain
            
            await MainActor.run {
                self.batteryStatus = fStatus; self.batteryPowerSource = fSource
                self.batSourceType = fType; self.batTimeRemain = fTime
                self.batTemp = fTemp; self.batWatts = fWatts; self.batCycle = fCycle; self.batHealth = fHealth
                self.batteryIcon = fIcon; self.batteryColor = fColor
                self.batteryHistory.append(BatteryData(time: Date(), level: fPct))
                if self.batteryHistory.count > 60 { self.batteryHistory.removeFirst() }
            }
        }
    }
    
    private func fetchNetworkTraffic() {
        Task.detached {
            let output = self.runCommand("/usr/sbin/netstat", ["-ib"])
            var totalIn: UInt64 = 0, totalOut: UInt64 = 0
            for line in output.components(separatedBy: .newlines) where line.hasPrefix("en") {
                let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if cols.count >= 10, let iBytes = UInt64(cols[6]), let oBytes = UInt64(cols[9]) {
                    totalIn += iBytes; totalOut += oBytes
                }
            }
            let fIn = totalIn, fOut = totalOut
            await MainActor.run { self.calculateSpeed(currentIn: fIn, currentOut: fOut) }
        }
    }
    
    private func calculateSpeed(currentIn: UInt64, currentOut: UInt64) {
        if lastInBytes == 0 { lastInBytes = currentIn; lastOutBytes = currentOut; return }
        let inDiff = currentIn >= lastInBytes ? currentIn - lastInBytes : 0
        let outDiff = currentOut >= lastOutBytes ? currentOut - lastOutBytes : 0
        lastInBytes = currentIn; lastOutBytes = currentOut
        self.upSpeedStr = formatBytes(outDiff); self.downSpeedStr = formatBytes(inDiff)
        self.trafficHistory.append(TrafficData(time: Date(), downloadSpeed: Double(inDiff), uploadSpeed: Double(outDiff)))
        if trafficHistory.count > 30 { trafficHistory.removeFirst() }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return String(format: "%4d B/s", bytes) }
        else if bytes < 1024 * 1024 { return String(format: "%4.1f KB/s", Double(bytes) / 1024) }
        else { return String(format: "%4.1f MB/s", Double(bytes) / (1024 * 1024)) }
    }
}
