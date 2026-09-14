import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func startPerAppNetworkMonitor() {
        Task {
            while !Task.isCancelled {
                fetchPerAppNetworkTraffic()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func startNetworkDetailsMonitor() {
        Task {
            while !Task.isCancelled {
                fetchNetworkDetails()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func refreshNetworkDetails() {
        fetchNetworkDetails()
    }

    func appDataUsageItems(days: Int) -> [AppDataUsageItem] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var totals: [String: UInt64] = [:]
        for offset in 0..<max(1, days) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = formatter.string(from: date)
            for (name, bytes) in appUsageHistory[key] ?? [:] { totals[name, default: 0] += bytes }
        }

        if totals.isEmpty {
            for usage in appNetworkUsages {
                totals[usage.name, default: 0] += usage.totalDownload + usage.totalUpload
            }
        }

        return totals.map { name, bytes in
            let pid = appNetworkUsages.first(where: { $0.name == name })?.pid
            return AppDataUsageItem(id: name, name: name, bytes: bytes, pid: pid)
        }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    func appDataUsageTotal(days: Int) -> UInt64 {
        appDataUsageItems(days: days).reduce(0) { $0 + $1.bytes }
    }

    func startLowPowerModeMonitor() {
        Task {
            while !Task.isCancelled {
                refreshLowPowerModeState()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func refreshLowPowerModeState() {
        Task.detached {
            let batt = self.runCommand("/usr/bin/pmset", ["-g", "batt"])
            let custom = self.runCommand("/usr/bin/pmset", ["-g", "custom"])
            let onAC = batt.localizedCaseInsensitiveContains("AC Power")
            let sectionName = onAC ? "AC Power" : "Battery Power"
            var enabled: Bool? = nil
            if let range = custom.range(of: sectionName + ":") {
                let tail = String(custom[range.upperBound...])
                let section = tail.components(separatedBy: "\n\n").first ?? tail
                if let value = self.extract(pattern: #"(?m)^\s*lowpowermode\s+(\d+)"#, from: section) { enabled = (value == "1") }
            }
            let actual = enabled ?? ProcessInfo.processInfo.isLowPowerModeEnabled
            await MainActor.run { self.isLowPowerModeEnabled = actual }
        }
    }

    func toggleLowPowerMode() {
        setLowPowerMode(!isLowPowerModeEnabled)
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard !isChangingLowPowerMode else { return }
        isChangingLowPowerMode = true

        let value = enabled ? "1" : "0"
        let command = "/usr/bin/pmset -a lowpowermode \(value)"
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escapedCommand)\" with administrator privileges"

        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errorInfo)
        }

        if errorInfo != nil {
            isChangingLowPowerMode = false
            refreshLowPowerModeState()
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let custom = self.runCommand("/usr/bin/pmset", ["-g", "custom"])
            var verified: Bool? = nil

            for sectionName in ["Battery Power", "AC Power"] {
                if let range = custom.range(of: sectionName + ":") {
                    let tail = String(custom[range.upperBound...])
                    let section = tail.components(separatedBy: "\n\n").first ?? tail
                    if let v = self.extract(pattern: #"(?m)^\s*lowpowermode\s+(\d+)"#, from: section) {
                        verified = (v == "1")
                        if verified == enabled { break }
                    }
                }
            }

            self.isLowPowerModeEnabled = verified ?? ProcessInfo.processInfo.isLowPowerModeEnabled
            self.isChangingLowPowerMode = false
        }
    }

    func startDetailedBatteryMonitor() {
        Task {
            while !Task.isCancelled {
                fetchDynamicBatteryInfo()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func startBatteryHealthMonitor() {
        Task {
            while !Task.isCancelled {
                fetchBatteryHealthInfo()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func startSystemInfoMonitor() {
        Task {
            while !Task.isCancelled {
                fetchSystemInfo()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func startThunderboltMonitor() {
        Task {
            while !Task.isCancelled {
                fetchThunderboltDevices()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

}
