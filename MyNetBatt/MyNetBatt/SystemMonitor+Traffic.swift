import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    /// 把累計上傳／下載量歸零重新計算（到下次重開機為止）。
    func resetTrafficTotals() {
        guard lastInBytes > 0 || lastOutBytes > 0 else { return }
        trafficBaselineIn = lastInBytes
        trafficBaselineOut = lastOutBytes
        UserDefaults.standard.set(Double(trafficBaselineIn), forKey: "trafficBaselineIn")
        UserDefaults.standard.set(Double(trafficBaselineOut), forKey: "trafficBaselineOut")
        UserDefaults.standard.set(SystemReaders.bootTime, forKey: "trafficBaselineBoot")
        trafficBaselineTime = Date().timeIntervalSince1970
        UserDefaults.standard.set(trafficBaselineTime, forKey: "trafficBaselineTime")
        totalDownStr = formatBytes(0)
        totalUpStr = formatBytes(0)
        avgDownStr = formatSpeed(0)
        avgUpStr = formatSpeed(0)
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
        self.assignIfChanged(\.totalSpeedStr, formatSpeed(inDiff + outDiff))
        // 計數比基準還小代表網卡計數已重置，基準不再適用。
        if currentIn < trafficBaselineIn || currentOut < trafficBaselineOut {
            trafficBaselineIn = 0
            trafficBaselineOut = 0
            trafficBaselineTime = SystemReaders.bootTime
        }
        self.assignIfChanged(\.totalDownStr, formatBytes(currentIn - trafficBaselineIn))
        self.assignIfChanged(\.totalUpStr, formatBytes(currentOut - trafficBaselineOut))
        let now = Date()
        let elapsed = max(1, now.timeIntervalSince1970 - trafficBaselineTime)
        self.assignIfChanged(\.avgDownStr, formatSpeed(UInt64(Double(currentIn - trafficBaselineIn) / elapsed)))
        self.assignIfChanged(\.avgUpStr, formatSpeed(UInt64(Double(currentOut - trafficBaselineOut) / elapsed)))
        recordHourlyTraffic(upload: outDiff, download: inDiff, at: now)
        self.assignIfChanged(\.todayUpStr, formatBytes(hourlyTraffic.upload.reduce(0, +)))
        self.assignIfChanged(\.todayDownStr, formatBytes(hourlyTraffic.download.reduce(0, +)))
        self.trafficHistory.append(TrafficData(time: Date(), downloadSpeed: Double(inDiff), uploadSpeed: Double(outDiff)))
        if trafficHistory.count > 30 { trafficHistory.removeFirst() }
    }
    
    /// 把這一秒的流量加進今天對應的小時；換日時整份歸零。
    func recordHourlyTraffic(upload: UInt64, download: UInt64, at now: Date) {
        let day = Self.dayKeyFormatter.string(from: now)
        if hourlyTraffic.day != day {
            hourlyTraffic = HourlyTraffic(day: day)
            saveHourlyTraffic(force: true)
        }
        guard upload > 0 || download > 0 else { return }
        let hour = max(0, min(23, Calendar.current.component(.hour, from: now)))
        hourlyTraffic.upload[hour] += upload
        hourlyTraffic.download[hour] += download
        saveHourlyTraffic()
    }

    /// 最多每 5 分鐘寫入一次；App 結束時由 AppDelegate 強制寫入。
    func saveHourlyTraffic(force: Bool = false) {
        let now = Date()
        if !force, let last = lastHourlyTrafficSave, now.timeIntervalSince(last) < 300 { return }
        lastHourlyTrafficSave = now
        if let encoded = try? JSONEncoder().encode(hourlyTraffic) {
            UserDefaults.standard.set(encoded, forKey: "hourlyTrafficV1")
        }
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
