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

}
