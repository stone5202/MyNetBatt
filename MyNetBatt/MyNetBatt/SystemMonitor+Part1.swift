import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func toggleTemperatureUnit() {
        tempDisplayInFahrenheit.toggle()
    }
    
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

        Publishers.MergeMany($showNetModule.map { _ in }, $showBatModule.map { _ in }, $showNetChart.map { _ in }, $showNetSpeed.map { _ in }, $showBatIcon.map { _ in }, $showBatText.map { _ in })
        .sink { [weak self] in self?.layoutChanged.send() }.store(in: &cancellables)

        updateBatteryColor()
        startNetworkSpeedMonitor()
        startNetworkDetailsMonitor()
        startDetailedBatteryMonitor()
        startLowPowerModeMonitor()
        startBatteryHealthMonitor()
        startSystemInfoMonitor()
        startThunderboltMonitor()
    }
    
    func updateBatteryColor() {
        let colors: [Color] = [.primary, .red, .orange, .yellow, .green]
        if selectedColorIndex >= 0 && selectedColorIndex < colors.count { batteryColor = colors[selectedColorIndex] }
    }
    
    nonisolated func runCommand(_ path: String, _ args: [String]) -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        task.environment = env
        let pipe = Pipe(); task.standardOutput = pipe; try? task.run()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    nonisolated func runCommandData(_ path: String, _ args: [String]) -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return Data()
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    nonisolated func extract(pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1 else { return nil }
        return String(text[Range(match.range(at: 1), in: text)!])
    }

    // 直接向 Mach kernel 取得整台 Mac 的 CPU tick，避免 top/ps 文字格式或語系變動。
    nonisolated func hostCPULoadInfo() -> host_cpu_load_info? {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let info = host_cpu_load_info_t.allocate(capacity: 1)
        defer { info.deallocate() }

        let result = info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, ptr, &count)
        }

        guard result == KERN_SUCCESS else { return nil }
        return info.pointee
    }

    nonisolated func sampleSystemCPUUsage() -> Double? {
        guard let first = hostCPULoadInfo() else { return nil }
        usleep(150_000)
        guard let second = hostCPULoadInfo() else { return nil }

        let user = Double(second.cpu_ticks.0 &- first.cpu_ticks.0)
        let system = Double(second.cpu_ticks.1 &- first.cpu_ticks.1)
        let idle = Double(second.cpu_ticks.2 &- first.cpu_ticks.2)
        let nice = Double(second.cpu_ticks.3 &- first.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return max(0, min(100, (user + system + nice) / total * 100.0))
    }

    func startNetworkSpeedMonitor() {
        Task {
            while !Task.isCancelled {
                fetchNetworkTraffic()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // Per-App 網路用量目前停用：避免 nettop 在受限環境中持續重試。
}
