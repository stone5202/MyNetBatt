import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

@MainActor
class SystemMonitor: ObservableObject {
    let layoutChanged = PassthroughSubject<Void, Never>()
    var cancellables = Set<AnyCancellable>()

    @Published var showNetModule: Bool { didSet { UserDefaults.standard.set(showNetModule, forKey: "showNetModule") } }
    @Published var showBatModule: Bool { didSet { UserDefaults.standard.set(showBatModule, forKey: "showBatModule") } }
    @Published var showNetChart: Bool { didSet { UserDefaults.standard.set(showNetChart, forKey: "showNetChart") } }
    @Published var showNetSpeed: Bool { didSet { UserDefaults.standard.set(showNetSpeed, forKey: "showNetSpeed") } }
    @Published var showBatIcon: Bool { didSet { UserDefaults.standard.set(showBatIcon, forKey: "showBatIcon") } }
    @Published var showBatText: Bool { didSet { UserDefaults.standard.set(showBatText, forKey: "showBatText") } }
    
    @Published var selectedColorIndex: Int {
        didSet { UserDefaults.standard.set(selectedColorIndex, forKey: "selectedColorIndex"); updateBatteryColor() }
    }

    @Published var isAutoStartEnabled: Bool = SMAppService.mainApp.status == .enabled {
        didSet { do { if isAutoStartEnabled { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } } else { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } } } catch { print("Auto Start Error: \(error)") } }
    }

    @Published var upSpeedStr: String = "0 B/s"
    @Published var downSpeedStr: String = "0 B/s"
    @Published var totalUpStr: String = "0 MB"
    @Published var totalDownStr: String = "0 MB"
    @Published var trafficHistory: [TrafficData] = []
    
    @Published var batteryStatus: String = "--"
    @Published var batPct: Int = 0
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false
    @Published var isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var isChangingLowPowerMode: Bool = false
    @Published var tempDisplayInFahrenheit: Bool = UserDefaults.standard.bool(forKey: "tempDisplayInFahrenheit") {
        didSet { UserDefaults.standard.set(tempDisplayInFahrenheit, forKey: "tempDisplayInFahrenheit") }
    }
    @Published var batteryIcon: String = "battery.100"
    @Published var batteryColor: Color = .green
    @Published var batteryPowerSource: String = "讀取中..."
    @Published var batHealth: String = "--"
    @Published var batCycle: String = "--"
    @Published var batTemp: String = "--"
    @Published var batTempDouble: Double = 0.0
    @Published var batWatts: String = "--"
    @Published var batSourceType: String = "--"
    @Published var batTimeRemain: String = "--"

    @Published var batteryHistory: [BatteryData] = [] {
        didSet {
            if let encoded = try? JSONEncoder().encode(batteryHistory) {
                UserDefaults.standard.set(encoded, forKey: "batteryHistory")
            }
        }
    }

    @Published var cpuModelStr: String = "讀取中..."
    @Published var macModelStr: String = "讀取中..."
    @Published var gpuModelStr: String = "讀取中..."
    @Published var ramUsageStr: String = "讀取中..."
    @Published var ramUsagePct: Double = 0.0
    @Published var swapUsageStr: String = "讀取中..."
    @Published var swapUsagePct: Double = 0.0
    @Published var diskUsageStr: String = "讀取中..."
    @Published var diskUsedStr: String = "-- GB"
    @Published var diskFreeStr: String = "-- GB"
    @Published var diskTotalStr: String = "-- GB"
    @Published var diskUsagePct: Double = 0.0
    @Published var storageVolumes: [StorageVolumeInfo] = []
    @Published var currentCpuUsage: Double = 0.0
    @Published var cpuHistory: [SimpleData] = []
    @Published var currentGpuUsage: Double = 0.0
    @Published var gpuHistory: [SimpleData] = []
    @Published var appNetworkUsages: [AppNetworkUsage] = []
    @Published var appNetworkStatus: String = "建立程序流量基準中…"
    @Published var appUsageHistory: [String: [String: UInt64]] = [:]
    @Published var networkInterfaceName: String = "--"
    @Published var networkLocalIP: String = "--"
    @Published var networkGateway: String = "--"
    @Published var networkDNS: String = "--"
    @Published var networkPublicIP: String = "--"
    @Published var networkDetailStatus: String = "讀取中…"
    @Published var thunderboltDevices: [ThunderboltDeviceInfo] = []
    @Published var thunderboltStatus: String = "讀取中…"

    var lastInBytes: UInt64 = 0
    var lastOutBytes: UInt64 = 0
    var lastAppNetworkBytes: [String: (incoming: UInt64, outgoing: UInt64)] = [:]
    var lastAppNetworkSampleTime: Date?
    let appUsageHistoryDefaultsKey = "appUsageHistoryV2"
    private var wakeRefreshTask: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [
            "showNetModule": true, "showBatModule": true, "showNetChart": true,
            "showNetSpeed": true, "showBatIcon": true, "showBatText": true, "selectedColorIndex": 4
        ])
        showNetModule = UserDefaults.standard.bool(forKey: "showNetModule"); showBatModule = UserDefaults.standard.bool(forKey: "showBatModule")
        showNetChart = UserDefaults.standard.bool(forKey: "showNetChart"); showNetSpeed = UserDefaults.standard.bool(forKey: "showNetSpeed")
        showBatIcon = UserDefaults.standard.bool(forKey: "showBatIcon"); showBatText = UserDefaults.standard.bool(forKey: "showBatText")
        selectedColorIndex = UserDefaults.standard.integer(forKey: "selectedColorIndex")

        if let data = UserDefaults.standard.data(forKey: "batteryHistory"),
           let decoded = try? JSONDecoder().decode([BatteryData].self, from: data) {
            batteryHistory = decoded
        }
        if let data = UserDefaults.standard.data(forKey: appUsageHistoryDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: UInt64]].self, from: data) {
            appUsageHistory = decoded
        }

        Publishers.MergeMany($showNetModule.map { _ in }, $showBatModule.map { _ in }, $showNetChart.map { _ in }, $showNetSpeed.map { _ in }, $showBatIcon.map { _ in }, $showBatText.map { _ in })
        .sink { [weak self] in self?.layoutChanged.send() }.store(in: &cancellables)

        updateBatteryColor()
        startNetworkSpeedMonitor()
        startPerAppNetworkMonitor()
        startNetworkDetailsMonitor()
        startDetailedBatteryMonitor()
        startLowPowerModeMonitor()
        startBatteryHealthMonitor()
        startSystemInfoMonitor()
        startThunderboltMonitor()
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
                self.refreshLowPowerModeState()
            }
            self.fetchBatteryHealthInfo()
            self.fetchThunderboltDevices()
        }
    }

}
