import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

/// 屬性的預設值在 init 註冊 defaults 之前就會求值，因此直接讀取並自帶預設值。
nonisolated func storedSetting<T>(_ key: String, _ fallback: T) -> T {
    UserDefaults.standard.object(forKey: key) as? T ?? fallback
}

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

    // MARK: 選單列樣式
    /// 0 = 上傳＋下載、1 = 僅上傳、2 = 僅下載
    var netSpeedStyle: Int = storedSetting("netSpeedStyle", 0) { didSet { UserDefaults.standard.set(netSpeedStyle, forKey: "netSpeedStyle"); layoutChanged.send() } }
    var showNetArrow: Bool = storedSetting("showNetArrow", true) { didSet { UserDefaults.standard.set(showNetArrow, forKey: "showNetArrow"); layoutChanged.send() } }
    var netBarCompact: Bool = storedSetting("netBarCompact", false) { didSet { UserDefaults.standard.set(netBarCompact, forKey: "netBarCompact"); layoutChanged.send() } }
    /// 以系統電池圖示的尺寸自繪（約 27×12.5 pt）；關閉時使用較小的 SF Symbol。
    var batIconLarge: Bool = storedSetting("batIconLarge", true) { didSet { UserDefaults.standard.set(batIconLarge, forKey: "batIconLarge"); layoutChanged.send() } }

    // MARK: 其他選單列項目（點擊會打開監控中心的系統效能頁）
    var showCpuItem: Bool = storedSetting("showCpuItem", false) { didSet { UserDefaults.standard.set(showCpuItem, forKey: "showCpuItem"); layoutChanged.send() } }
    var showMemItem: Bool = storedSetting("showMemItem", false) { didSet { UserDefaults.standard.set(showMemItem, forKey: "showMemItem"); layoutChanged.send() } }
    var showDiskItem: Bool = storedSetting("showDiskItem", false) { didSet { UserDefaults.standard.set(showDiskItem, forKey: "showDiskItem"); layoutChanged.send() } }

    // MARK: 小視窗內容
    var popNetShowTotals: Bool = storedSetting("popNetShowTotals", true) { didSet { UserDefaults.standard.set(popNetShowTotals, forKey: "popNetShowTotals") } }
    var popNetShowActive: Bool = storedSetting("popNetShowActive", true) { didSet { UserDefaults.standard.set(popNetShowActive, forKey: "popNetShowActive") } }
    var popNetShowAppUsage: Bool = storedSetting("popNetShowAppUsage", true) { didSet { UserDefaults.standard.set(popNetShowAppUsage, forKey: "popNetShowAppUsage") } }
    var popNetShowDisk: Bool = storedSetting("popNetShowDisk", true) { didSet { UserDefaults.standard.set(popNetShowDisk, forKey: "popNetShowDisk") } }
    var popNetShowBarToggles: Bool = storedSetting("popNetShowBarToggles", true) { didSet { UserDefaults.standard.set(popNetShowBarToggles, forKey: "popNetShowBarToggles") } }
    var popBatShowChart: Bool = storedSetting("popBatShowChart", true) { didSet { UserDefaults.standard.set(popBatShowChart, forKey: "popBatShowChart") } }

    /// 暫停時仍顯示即時網速，但不再把用量累計進每日／每月紀錄。
    var usageTrackingPaused: Bool = storedSetting("usageTrackingPaused", false) { didSet { UserDefaults.standard.set(usageTrackingPaused, forKey: "usageTrackingPaused") } }

    /// 監控中心目前選取的分頁；選單列項目與齒輪按鈕可指定要打開的分頁。
    var mainWindowTab: String = "battery"

    // MARK: 外觀
    @ObservationIgnored let appearanceChanged = PassthroughSubject<Void, Never>()
    /// 0 = 自動、1 = 淺色、2 = 深色
    var appearanceMode: Int = storedSetting("appearanceMode", 0) { didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode"); appearanceChanged.send() } }
    var accentColorIndex: Int = storedSetting("accentColorIndex", 0) { didSet { UserDefaults.standard.set(accentColorIndex, forKey: "accentColorIndex") } }

    // MARK: 懸浮視窗
    /// 視窗層級的設定（顯示、不透明度、陰影）改變時通知 AppDelegate；內容樣式由 SwiftUI 直接觀察。
    @ObservationIgnored let floatWindowChanged = PassthroughSubject<Void, Never>()
    var showFloatWindow: Bool = storedSetting("showFloatWindow", false) { didSet { UserDefaults.standard.set(showFloatWindow, forKey: "showFloatWindow"); floatWindowChanged.send() } }
    /// 0 = 小、1 = 中、2 = 大
    var floatSize: Int = storedSetting("floatSize", 1) { didSet { UserDefaults.standard.set(floatSize, forKey: "floatSize") } }
    var floatOpacity: Double = storedSetting("floatOpacity", 1.0) { didSet { UserDefaults.standard.set(floatOpacity, forKey: "floatOpacity"); floatWindowChanged.send() } }
    var floatBlur: Bool = storedSetting("floatBlur", true) { didSet { UserDefaults.standard.set(floatBlur, forKey: "floatBlur") } }
    var floatShadow: Bool = storedSetting("floatShadow", true) { didSet { UserDefaults.standard.set(floatShadow, forKey: "floatShadow"); floatWindowChanged.send() } }
    var floatBorder: Bool = storedSetting("floatBorder", true) { didSet { UserDefaults.standard.set(floatBorder, forKey: "floatBorder") } }
    var floatShowNet: Bool = storedSetting("floatShowNet", true) { didSet { UserDefaults.standard.set(floatShowNet, forKey: "floatShowNet") } }
    var floatShowBattery: Bool = storedSetting("floatShowBattery", true) { didSet { UserDefaults.standard.set(floatShowBattery, forKey: "floatShowBattery") } }
    var floatShowSystem: Bool = storedSetting("floatShowSystem", false) { didSet { UserDefaults.standard.set(floatShowSystem, forKey: "floatShowSystem") } }

    // MARK: 電池通知
    var notifyLowBattery: Bool = storedSetting("notifyLowBattery", false) {
        didSet { UserDefaults.standard.set(notifyLowBattery, forKey: "notifyLowBattery"); if notifyLowBattery { ensureNotificationPermission() } }
    }
    var notifyFullyCharged: Bool = storedSetting("notifyFullyCharged", false) {
        didSet { UserDefaults.standard.set(notifyFullyCharged, forKey: "notifyFullyCharged"); if notifyFullyCharged { ensureNotificationPermission() } }
    }
    var notificationSound: Bool = storedSetting("notificationSound", true) { didSet { UserDefaults.standard.set(notificationSound, forKey: "notificationSound") } }
    /// 使用者在系統設定拒絕通知時為 true，設定頁據此顯示提示。
    var notificationPermissionDenied = false
    @ObservationIgnored var lowBatteryNotified = false
    @ObservationIgnored var fullChargeNotified = false
    @ObservationIgnored var hasBatteryNotificationBaseline = false

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
    /// 累計量除以累計時間（自開機或上次重置起）的平均速度。
    var avgUpStr: String = "0 B/s"
    var avgDownStr: String = "0 B/s"
    var hourlyTraffic = HourlyTraffic(day: "")
    /// 選單列樣式用：上傳加下載的即時速度，以及今天累計的上傳／下載量。
    var totalSpeedStr: String = "0 B/s"
    var todayUpStr: String = "0 B"
    var todayDownStr: String = "0 B"
    @ObservationIgnored var lastHourlyTrafficSave: Date?
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

    /// 充電中顯示本次充電的進度，結束後保留上一次充電的起訖電量與耗時。
    var chargeSessionText: String = storedSetting("lastChargeSummary", "")
    @ObservationIgnored var chargeSessionStart: Date?
    @ObservationIgnored var chargeSessionStartLevel = 0

    /// 每天一筆的健康度與循環次數，用來看電池長期衰退的趨勢；最多保留兩年。
    var batteryHealthLog: [BatteryHealthEntry] = []

    /// 「重置總數據量」時記下的網卡累計值；顯示的累計量為目前值減去這個基準。
    /// 網卡計數在重開機後歸零，因此基準只在同一次開機期間有效。
    @ObservationIgnored var trafficBaselineIn: UInt64 = 0
    @ObservationIgnored var trafficBaselineOut: UInt64 = 0
    /// 累計量的起算時間（開機時間或重置當下），用來算平均速度。
    @ObservationIgnored var trafficBaselineTime: TimeInterval = SystemReaders.bootTime

    /// 每分鐘新增一筆、最多 2880 筆；寫入由 saveBatteryHistory() 節流，不在每次變動時整包編碼。
    var batteryHistory: [BatteryData] = []

    var cpuModelStr: String = "讀取中..."
    var macModelStr: String = "讀取中..."
    var gpuModelStr: String = "讀取中..."
    var ramUsageStr: String = "讀取中..."
    var ramUsagePct: Double = 0.0
    var memoryPressurePct: Double = 0.0
    /// 1 = 正常、2 = 警告、4 = 嚴重
    var memoryPressureLevel: Int = 1
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
    /// 以 "yyyy-MM" 為 key 的每月用量，保留 12 個月；每日明細（appUsageHistory）只保留 31 天。
    var appUsageMonthly: [String: [String: UInt64]] = [:]
    /// 與上面兩份紀錄相同的 key，值為 [上傳, 下載]。加入這份紀錄之前的用量沒有區分方向，
    /// 合計與兩者相加的差額在畫面上顯示為「未分類」。
    var appUsageSplit: [String: [String: [UInt64]]] = [:]
    var appUsageMonthlySplit: [String: [String: [UInt64]]] = [:]
    /// 未連上 Wi‑Fi 時為 nil。
    var wifiInfo: WiFiInfo?
    @ObservationIgnored var wifiLocationAuthorizer: WiFiLocationAuthorizer?
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
    @ObservationIgnored let appUsageMonthlyDefaultsKey = "appUsageMonthlyV1"
    @ObservationIgnored let appUsageSplitDefaultsKey = "appUsageSplitV1"
    @ObservationIgnored let appUsageMonthlySplitDefaultsKey = "appUsageMonthlySplitV1"

    /// 每日用量紀錄的 key 固定使用西曆與 POSIX locale，避免使用者切換曆法（如民國曆）後
    /// 舊 key 解析錯誤，導致過期清理誤刪或永遠保留紀錄。
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
        if let data = UserDefaults.standard.data(forKey: appUsageMonthlyDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: UInt64]].self, from: data) {
            appUsageMonthly = decoded
        } else {
            // 第一次升級到有每月統計的版本：以既有的每日紀錄建立每月統計。
            for (dayKey, usage) in appUsageHistory {
                let monthKey = String(dayKey.prefix(7))
                for (name, bytes) in usage { appUsageMonthly[monthKey, default: [:]][name, default: 0] += bytes }
            }
        }

        if let data = UserDefaults.standard.data(forKey: appUsageSplitDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: [UInt64]]].self, from: data) {
            appUsageSplit = decoded
        }
        if let data = UserDefaults.standard.data(forKey: appUsageMonthlySplitDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: [UInt64]]].self, from: data) {
            appUsageMonthlySplit = decoded
        }

        if let data = UserDefaults.standard.data(forKey: "batteryHealthLogV1"),
           let decoded = try? JSONDecoder().decode([BatteryHealthEntry].self, from: data) {
            batteryHealthLog = decoded
        }
        // kern.boottime 會隨系統校時微幅變動，容許 5 分鐘的誤差。
        if abs(UserDefaults.standard.double(forKey: "trafficBaselineBoot") - SystemReaders.bootTime) < 300 {
            trafficBaselineIn = UInt64(max(0, UserDefaults.standard.double(forKey: "trafficBaselineIn")))
            trafficBaselineOut = UInt64(max(0, UserDefaults.standard.double(forKey: "trafficBaselineOut")))
            let resetTime = UserDefaults.standard.double(forKey: "trafficBaselineTime")
            if resetTime > SystemReaders.bootTime { trafficBaselineTime = resetTime }
        }
        if let data = UserDefaults.standard.data(forKey: "hourlyTrafficV1"),
           let decoded = try? JSONDecoder().decode(HourlyTraffic.self, from: data),
           decoded.upload.count == 24, decoded.download.count == 24 {
            hourlyTraffic = decoded
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

    static let accentPalette: [(name: String, color: Color)] = [
        ("藍色", .blue), ("紫色", .purple), ("粉紅色", .pink), ("紅色", .red),
        ("橘色", .orange), ("黃色", .yellow), ("綠色", .green), ("青色", .cyan)
    ]

    var accentColor: Color {
        Self.accentPalette.indices.contains(accentColorIndex) ? Self.accentPalette[accentColorIndex].color : .blue
    }

    /// 疊在強調色上的文字顏色；黃色與青色偏亮，改用黑色才看得清楚。
    var accentContrastColor: Color {
        [5, 7].contains(accentColorIndex) ? .black : .white
    }

    /// 選單列網速文字的寬度；狀態列項目的長度（AppDelegate）與畫面共用同一個值。
    var netSpeedTextWidth: CGFloat { netSpeedTextWidth(style: netSpeedStyle) }

    /// 各種網速樣式（NetSpeedLabel.styleNames）的寬度；4、5 是兩欄並排。
    func netSpeedTextWidth(style: Int) -> CGFloat {
        let twoLine = style == 0 || style == 5
        var width: CGFloat = twoLine ? (netBarCompact ? 32 : 40) : (netBarCompact ? 42 : 56)
        if showNetArrow { width += twoLine ? 8 : 10 }
        return style >= 4 ? width * 2 + 6 : width
    }

    /// 選單列顯示的網速文字；窄版省略空白與「/s」。
    func barSpeedText(upload: Bool) -> String {
        barText(upload ? upSpeedStr : downSpeedStr, arrow: upload ? "↑" : "↓")
    }

    func barText(_ speed: String, arrow: String) -> String {
        var text = speed
        if netBarCompact {
            text = text.replacingOccurrences(of: "/s", with: "").replacingOccurrences(of: " ", with: "")
        }
        return showNetArrow ? "\(arrow) \(text)" : text
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
