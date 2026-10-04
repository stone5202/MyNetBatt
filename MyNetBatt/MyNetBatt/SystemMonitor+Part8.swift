import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchBatteryHealthInfo() {
        runExclusive("batteryHealth") {
            // Keep macOS Maximum Capacity as the single source of truth.
            // AppleRawMaxCapacity is a fluctuating gauge value and can differ
            // by several percentage points from the health shown by macOS.
            let output = self.runCommand("/usr/sbin/system_profiler", ["SPPowerDataType"])
            var cycle: String?
            var health: String?

            for line in output.components(separatedBy: .newlines) {
                if line.contains("Cycle Count:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value, !value.isEmpty { cycle = value }
                }

                if line.contains("Maximum Capacity:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value, !value.isEmpty { health = value }
                }
            }

            let finalCycle = cycle
            let finalHealth = health

            await MainActor.run {
                if let finalCycle { self.batCycle = finalCycle }
                if let finalHealth { self.batHealth = finalHealth }
                self.recordBatteryHealth()
            }
        }
    }

    /// 把今天的健康度與循環次數記進長期紀錄；同一天只保留最新的一筆。
    func recordBatteryHealth() {
        guard let health = Int(batHealth.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
              (1...150).contains(health), let cycles = Int(batCycle) else { return }
        let entry = BatteryHealthEntry(day: Self.dayKeyFormatter.string(from: Date()), health: health, cycles: cycles)
        if batteryHealthLog.last?.day == entry.day {
            guard batteryHealthLog.last != entry else { return }
            batteryHealthLog[batteryHealthLog.count - 1] = entry
        } else {
            batteryHealthLog.append(entry)
        }
        if batteryHealthLog.count > 730 { batteryHealthLog.removeFirst(batteryHealthLog.count - 730) }
        saveBatteryHealthLog()
    }

    func saveBatteryHealthLog() {
        if let encoded = try? JSONEncoder().encode(batteryHealthLog) {
            UserDefaults.standard.set(encoded, forKey: "batteryHealthLogV1")
        }
    }

    func resetBatteryHealthLog() {
        batteryHealthLog.removeAll()
        saveBatteryHealthLog()
        recordBatteryHealth()
    }

    /// 把累計上傳／下載量歸零重新計算（到下次重開機為止）。
    func resetTrafficTotals() {
        guard lastInBytes > 0 || lastOutBytes > 0 else { return }
        trafficBaselineIn = lastInBytes
        trafficBaselineOut = lastOutBytes
        UserDefaults.standard.set(Double(trafficBaselineIn), forKey: "trafficBaselineIn")
        UserDefaults.standard.set(Double(trafficBaselineOut), forKey: "trafficBaselineOut")
        UserDefaults.standard.set(SystemReaders.bootTime, forKey: "trafficBaselineBoot")
        totalDownStr = formatBytes(0)
        totalUpStr = formatBytes(0)
    }

    func fetchNetworkTraffic() {
        runExclusive("networkTraffic") {
            // 以 IFMIB 直接讀 en* 介面的累計流量，取代每秒 spawn 一次 netstat -ib。
            guard let counts = SystemReaders.interfaceByteCounts(namePrefix: "en") else { return }
            await MainActor.run {
                self.calculateSpeed(currentIn: counts.input, currentOut: counts.output)
            }
        }
    }

    func calculateSpeed(currentIn: UInt64, currentOut: UInt64) {
        if lastInBytes == 0 { lastInBytes = currentIn; lastOutBytes = currentOut; return }
        let inDiff = currentIn >= lastInBytes ? currentIn - lastInBytes : 0
        let outDiff = currentOut >= lastOutBytes ? currentOut - lastOutBytes : 0
        lastInBytes = currentIn; lastOutBytes = currentOut
        self.assignIfChanged(\.upSpeedStr, formatSpeed(outDiff))
        self.assignIfChanged(\.downSpeedStr, formatSpeed(inDiff))
        // 計數比基準還小代表網卡計數已重置，基準不再適用。
        if currentIn < trafficBaselineIn || currentOut < trafficBaselineOut {
            trafficBaselineIn = 0
            trafficBaselineOut = 0
        }
        self.assignIfChanged(\.totalDownStr, formatBytes(currentIn - trafficBaselineIn))
        self.assignIfChanged(\.totalUpStr, formatBytes(currentOut - trafficBaselineOut))
        self.trafficHistory.append(TrafficData(time: Date(), downloadSpeed: Double(inDiff), uploadSpeed: Double(outDiff)))
        if trafficHistory.count > 30 { trafficHistory.removeFirst() }
    }
    
    func formatStorageBytesForUI(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000_000 { return String(format: "%.2f TB", value / 1_000_000_000_000) }
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return String(format: "%.0f B", value)
    }

    func formatBytesForUI(_ bytes: UInt64) -> String {
        formatBytes(bytes)
    }

    func formatSpeedForUI(_ bytesPerSecond: Double) -> String {
        let value = UInt64(max(0, bytesPerSecond))
        return "\(formatBytes(value))/s"
    }

    func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }

    func formatSpeed(_ bytesPerSecond: UInt64) -> String {
        "\(formatBytes(bytesPerSecond))/s"
    }

}
