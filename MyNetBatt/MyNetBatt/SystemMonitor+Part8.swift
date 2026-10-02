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
            }
        }
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
        self.assignIfChanged(\.totalDownStr, formatBytes(currentIn))
        self.assignIfChanged(\.totalUpStr, formatBytes(currentOut))
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
