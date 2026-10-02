import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

/// 使用 Observation：每個畫面只在它實際讀取的屬性改變時才重算，
/// 不會因為任何一個取樣結果更新就讓所有畫面（包括狀態列）一起重繪。
@MainActor
@Observable
final class SystemMonitor {
    @ObservationIgnored let layoutChanged = PassthroughSubject<Void, Never>()
    @ObservationIgnored var cancellables = Set<AnyCancellable>()

    var showNetModule: Bool { didSet { UserDefaults.standard.set(showNetModule, forKey: "showNetModule"); layoutChanged.send() } }
    var showBatModule: Bool { didSet { UserDefaults.standard.set(showBatModule, forKey: "showBatModule"); layoutChanged.send() } }
    var showNetChart: Bool { didSet { UserDefaults.standard.set(showNetChart, forKey: "showNetChart"); layoutChanged.send() } }
    var showNetSpeed: Bool { didSet { UserDefaults.standard.set(showNetSpeed, forKey: "showNetSpeed"); layoutChanged.send() } }
    var showBatIcon: Bool { didSet { UserDefaults.standard.set(showBatIcon, forKey: "showBatIcon"); layoutChanged.send() } }
    var showBatText: Bool { didSet { UserDefaults.standard.set(showBatText, forKey: "showBatText"); layoutChanged.send() } }
    
    var selectedColorIndex: Int {
        didSet { UserDefaults.standard.set(selectedColorIndex, forKey: "selectedColorIndex"); updateBatteryColor() }
    }

    var lowBatteryThreshold: Int = 20 {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") }
    }

    var isAutoStartEnabled: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard !isRevertingAutoStart else { return }
            do {
                if isAutoStartEnabled {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
            } catch {
                print("Auto Start Error: \(error)")
                // 註冊／取消失敗時讓開關回到系統實際狀態；以旗標避免還原時再次觸發註冊。
                isRevertingAutoStart = true
                isAutoStartEnabled = SMAppService.mainApp.status == .enabled
                isRevertingAutoStart = false
            }
        }
    }
    @ObservationIgnored private var isRevertingAutoStart = false

    var upSpeedStr: String = "0 B/s"
    var downSpeedStr: String = "0 B/s"
    var totalUpStr: String = "0 MB"
    var totalDownStr: String = "0 MB"
    var trafficHistory: [TrafficData] = []
    
    var batteryStatus: String = "--"
    var batPct: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var tempDisplayInFahrenheit: Bool = UserDefaults.standard.bool(forKey: "tempDisplayInFahrenheit") {
        didSet { UserDefaults.standard.set(tempDisplayInFahrenheit, forKey: "tempDisplayInFahrenheit") }
    }
    var batteryIcon: String = "battery.100"
    var batteryColor: Color = .green
    var batteryPowerSource: String = "讀取中..."
    var batHealth: String = "--"
    var batCycle: String = "--"
    var batTemp: String = "--"
    var batTempDouble: Double = 0.0
    var batWatts: String = "--"
    var batSourceType: String = "--"
    var batTimeRemain: String = "--"

    /// 每分鐘新增一筆、最多 2880 筆；寫入由 saveBatteryHistory() 節流，不在每次變動時整包編碼。
    var batteryHistory: [BatteryData] = []

    var cpuModelStr: String = "讀取中..."
    var macModelStr: String = "讀取中..."
    var gpuModelStr: String = "讀取中..."
    var ramUsageStr: String = "讀取中..."
    var ramUsagePct: Double = 0.0
    var swapUsageStr: String = "讀取中..."
    var swapUsagePct: Double = 0.0
    var diskUsageStr: String = "讀取中..."
    var diskUsedStr: String = "-- GB"
    var diskFreeStr: String = "-- GB"
    var diskTotalStr: String = "-- GB"
    var diskUsagePct: Double = 0.0
    var storageVolumes: [StorageVolumeInfo] = []
    var currentCpuUsage: Double = 0.0
    var cpuHistory: [SimpleData] = []
    var currentGpuUsage: Double = 0.0
    var gpuHistory: [SimpleData] = []
    var appNetworkUsages: [AppNetworkUsage] = []
    var appNetworkStatus: String = "建立程序流量基準中…"
    var appUsageHistory: [String: [String: UInt64]] = [:]
    var networkInterfaceName: String = "--"
    var networkLocalIP: String = "--"
    var networkGateway: String = "--"
    var networkDNS: String = "--"
    var networkPublicIP: String = "--"
    var networkDetailStatus: String = "讀取中…"
    var thunderboltDevices: [ThunderboltDeviceInfo] = []
    var thunderboltStatus: String = "讀取中…"

    @ObservationIgnored var lastInBytes: UInt64 = 0
    @ObservationIgnored var lastOutBytes: UInt64 = 0
    @ObservationIgnored var lastAppNetworkBytes: [String: (incoming: UInt64, outgoing: UInt64)] = [:]
    @ObservationIgnored var lastAppNetworkSampleTime: Date?
    @ObservationIgnored let appUsageHistoryDefaultsKey = "appUsageHistoryV2"

    /// 每日用量紀錄的 key 固定使用西曆與 POSIX locale，避免使用者切換曆法（如民國曆）後
    /// 舊 key 解析錯誤，導致 14 天清理誤刪或永遠保留紀錄。
    static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    @ObservationIgnored private var wakeRefreshTask: Task<Void, Never>?
    /// 正在執行中的背景取樣；同一種取樣尚未完成時不再疊加新的一輪。
    @ObservationIgnored var inFlightFetches = Set<String>()
    @ObservationIgnored var lastAppUsageSave: Date?
    /// 目前正在顯示各 App 用量的畫面（網路小視窗、監控中心網路頁）；有任何一個時加快 nettop 取樣。
    @ObservationIgnored var perAppUsageViewers = Set<String>()
    @ObservationIgnored var lastPublicIPCheck: Date?
    @ObservationIgnored var lastPublicIPNetworkKey = ""
    @ObservationIgnored var deviceChangeObserver: DeviceChangeObserver?
    @ObservationIgnored var deviceRefreshTask: Task<Void, Never>?
    @ObservationIgnored var networkPathMonitor: NWPathMonitor?
    @ObservationIgnored var networkRefreshTask: Task<Void, Never>?
    @ObservationIgnored var lastBatteryHistorySave: Date?

    init() {
        UserDefaults.standard.register(defaults: [
            "showNetModule": true, "showBatModule": true, "showNetChart": true,
            "showNetSpeed": true, "showBatIcon": true, "showBatText": true,
            "selectedColorIndex": 4, "lowBatteryThreshold": 20
        ])
        showNetModule = UserDefaults.standard.bool(forKey: "showNetModule"); showBatModule = UserDefaults.standard.bool(forKey: "showBatModule")
        showNetChart = UserDefaults.standard.bool(forKey: "showNetChart"); showNetSpeed = UserDefaults.standard.bool(forKey: "showNetSpeed")
        showBatIcon = UserDefaults.standard.bool(forKey: "showBatIcon"); showBatText = UserDefaults.standard.bool(forKey: "showBatText")
        selectedColorIndex = UserDefaults.standard.integer(forKey: "selectedColorIndex")
        lowBatteryThreshold = UserDefaults.standard.integer(forKey: "lowBatteryThreshold")

        if let data = UserDefaults.standard.data(forKey: "batteryHistory"),
           let decoded = try? JSONDecoder().decode([BatteryData].self, from: data) {
            // Older builds stored transient read failures as 0%. Remove those
            // impossible samples when loading so they no longer distort charts.
            batteryHistory = decoded.filter { (1...100).contains($0.level) }
        }
        if let data = UserDefaults.standard.data(forKey: appUsageHistoryDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: UInt64]].self, from: data) {
            appUsageHistory = decoded
        }


        updateBatteryColor()
        startNetworkSpeedMonitor()
        startPerAppNetworkMonitor()
        startNetworkDetailsMonitor()
        startDetailedBatteryMonitor()
        startBatteryHealthMonitor()
        startSystemInfoMonitor()
        startStorageMonitor()
        startThunderboltMonitor()
        deviceChangeObserver = DeviceChangeObserver { [weak self] in self?.scheduleDeviceRefresh() }
    }

    var batteryTimeTitle: String {
        if isPluggedIn {
            return (batPct >= 100 || !isCharging) ? "狀態" : "預估充滿時間"
        }
        return "預估剩餘時間"
    }

    var batteryPowerTitle: String {
        isPluggedIn ? "充電功率" : "輸出功率"
    }

    var isLowBatteryWarning: Bool {
        batPct > 0 && batPct <= lowBatteryThreshold && !isPluggedIn
    }

    var displayedBatteryColor: Color {
        isLowBatteryWarning ? .red : batteryColor
    }

    var batTempDisplay: String {
        guard batTempDouble > 0 else { return tempDisplayInFahrenheit ? "--°F" : "--°C" }
        if tempDisplayInFahrenheit {
            let fahrenheit = batTempDouble * 9.0 / 5.0 + 32.0
            return String(format: "%.1f°F", fahrenheit)
        }
        return String(format: "%.1f°C", batTempDouble)
    }

    /// 網卡、路由及部分 IOKit 資料會在睡眠期間失效；喚醒後清掉舊基準並分段重抓。
    func handleSystemWake() {
        lastInBytes = 0
        lastOutBytes = 0
        lastAppNetworkBytes.removeAll()
        lastAppNetworkSampleTime = nil
        upSpeedStr = "0 B/s"
        downSpeedStr = "0 B/s"

        wakeRefreshTask?.cancel()
        wakeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 2, 8] {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                self.fetchNetworkTraffic()
                self.fetchNetworkDetails()
                self.fetchDynamicBatteryInfo()
                self.fetchSystemInfo()
            }
            self.fetchBatteryHealthInfo()
            self.fetchThunderboltDevices()
        }
    }


    /// 只在值真的改變時才寫入。Observation 對每次賦值都會通知讀取該屬性的畫面，
    /// 取樣結果常常和上一輪相同（例如電量維持 100%），直接賦值會讓狀態列無謂重繪。
    func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SystemMonitor, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
