import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    /// 用量紀錄每 2 秒都會變動，最多每分鐘寫入一次；App 結束時由 AppDelegate 強制寫入。
    func saveAppUsageHistory(force: Bool = false) {
        let now = Date()
        if !force, let last = lastAppUsageSave, now.timeIntervalSince(last) < 60 { return }
        lastAppUsageSave = now
        if let encoded = try? JSONEncoder().encode(appUsageHistory) {
            UserDefaults.standard.set(encoded, forKey: appUsageHistoryDefaultsKey)
        }
        if let encoded = try? JSONEncoder().encode(appUsageMonthly) {
            UserDefaults.standard.set(encoded, forKey: appUsageMonthlyDefaultsKey)
        }
        if let encoded = try? JSONEncoder().encode(appUsageSplit) {
            UserDefaults.standard.set(encoded, forKey: appUsageSplitDefaultsKey)
        }
        if let encoded = try? JSONEncoder().encode(appUsageMonthlySplit) {
            UserDefaults.standard.set(encoded, forKey: appUsageMonthlySplitDefaultsKey)
        }
    }

    func resetAppUsageHistory() {
        appUsageHistory.removeAll()
        appUsageMonthly.removeAll()
        appUsageSplit.removeAll()
        appUsageMonthlySplit.removeAll()
        saveAppUsageHistory(force: true)
    }

    func fetchPerAppNetworkTraffic() {
        runExclusive("perAppNetwork") {
            let output = self.runCommand("/usr/bin/nettop", [
                "-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"
            ])

            var current: [String: (name: String, pid: Int?, incoming: UInt64, outgoing: UInt64)] = [:]

            for rawLine in output.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.lowercased().contains("bytes_in") else { continue }
                let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard cols.count >= 3 else { continue }

                var numeric: [(Int, UInt64)] = []
                for (idx, value) in cols.enumerated() {
                    if let n = UInt64(value) { numeric.append((idx, n)) }
                }
                guard numeric.count >= 2 else { continue }
                let incomingPair = numeric[numeric.count - 2]
                let outgoingPair = numeric[numeric.count - 1]
                let firstValueIndex = min(incomingPair.0, outgoingPair.0)
                guard firstValueIndex > 0 else { continue }

                var nameField = ""
                for idx in stride(from: firstValueIndex - 1, through: 0, by: -1) {
                    let candidate = cols[idx]
                    if !candidate.isEmpty, UInt64(candidate) == nil {
                        nameField = candidate
                        break
                    }
                }
                guard !nameField.isEmpty else { continue }

                var processName = nameField
                var pid: Int? = nil
                if let regex = try? NSRegularExpression(pattern: #"^(.*)\.(\d+)$"#),
                   let match = regex.firstMatch(in: nameField, range: NSRange(nameField.startIndex..., in: nameField)),
                   let nRange = Range(match.range(at: 1), in: nameField),
                   let pRange = Range(match.range(at: 2), in: nameField) {
                    processName = String(nameField[nRange])
                    pid = Int(String(nameField[pRange]))
                }
                processName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !processName.isEmpty else { continue }

                current[nameField] = (processName, pid, incomingPair.1, outgoingPair.1)
            }

            let currentSnapshot = current
            let outputIsEmpty = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            await MainActor.run {
                let now = Date()
                let hadPreviousSample = self.lastAppNetworkSampleTime != nil
                let interval = max(0.25, now.timeIntervalSince(self.lastAppNetworkSampleTime ?? now))
                var result: [AppNetworkUsage] = []

                for (key, sample) in currentSnapshot {
                    let previous = self.lastAppNetworkBytes[key]
                    let inDiff = previous.map { sample.incoming >= $0.incoming ? sample.incoming - $0.incoming : 0 } ?? 0
                    let outDiff = previous.map { sample.outgoing >= $0.outgoing ? sample.outgoing - $0.outgoing : 0 } ?? 0

                    if hadPreviousSample {
                        let delta = inDiff + outDiff
                        if delta > 0 {
                            let dayKey = Self.dayKeyFormatter.string(from: now)
                            var dayUsage = self.appUsageHistory[dayKey] ?? [:]
                            dayUsage[sample.name, default: 0] += delta
                            self.appUsageHistory[dayKey] = dayUsage
                            let monthKey = String(dayKey.prefix(7))
                            self.appUsageMonthly[monthKey, default: [:]][sample.name, default: 0] += delta
                            self.appUsageSplit[dayKey, default: [:]][sample.name, default: [0, 0]][0] += outDiff
                            self.appUsageSplit[dayKey, default: [:]][sample.name, default: [0, 0]][1] += inDiff
                            self.appUsageMonthlySplit[monthKey, default: [:]][sample.name, default: [0, 0]][0] += outDiff
                            self.appUsageMonthlySplit[monthKey, default: [:]][sample.name, default: [0, 0]][1] += inDiff
                        }
                    }

                    result.append(AppNetworkUsage(
                        id: key,
                        name: sample.name,
                        pid: sample.pid,
                        downloadSpeed: Double(inDiff) / interval,
                        uploadSpeed: Double(outDiff) / interval,
                        totalDownload: sample.incoming,
                        totalUpload: sample.outgoing
                    ))
                }

                self.lastAppNetworkBytes = currentSnapshot.mapValues { (incoming: $0.incoming, outgoing: $0.outgoing) }
                self.lastAppNetworkSampleTime = now

                self.appNetworkUsages = result
                    .filter { $0.totalDownload > 0 || $0.totalUpload > 0 }
                    .sorted { ($0.downloadSpeed + $0.uploadSpeed) > ($1.downloadSpeed + $1.uploadSpeed) }

                let formatter = Self.dayKeyFormatter
                let cutoff = Calendar.current.date(byAdding: .day, value: -31, to: now) ?? now
                self.appUsageHistory = self.appUsageHistory.filter { key, _ in
                    guard let d = formatter.date(from: key) else { return false }
                    return d >= cutoff
                }
                if self.appUsageSplit.count > self.appUsageHistory.count {
                    self.appUsageSplit = self.appUsageSplit.filter { self.appUsageHistory[$0.key] != nil }
                }
                // 每月統計保留最近 12 個月；"yyyy-MM" 可直接以字串比較先後。
                if let oldest = Calendar.current.date(byAdding: .month, value: -11, to: now) {
                    let oldestKey = String(formatter.string(from: oldest).prefix(7))
                    if self.appUsageMonthly.keys.contains(where: { $0 < oldestKey }) {
                        self.appUsageMonthly = self.appUsageMonthly.filter { $0.key >= oldestKey }
                        self.appUsageMonthlySplit = self.appUsageMonthlySplit.filter { $0.key >= oldestKey }
                    }
                }
                self.saveAppUsageHistory()

                if outputIsEmpty {
                    self.assignIfChanged(\.appNetworkStatus, "無法取得 nettop 資料")
                } else if !hadPreviousSample {
                    self.assignIfChanged(\.appNetworkStatus, "建立程序流量基準中…")
                } else {
                    let active = self.appNetworkUsages.filter(\.isActive).count
                    self.assignIfChanged(\.appNetworkStatus, "偵測到 \(self.appNetworkUsages.count) 個有網路流量的程序 · \(active) 個目前活躍")
                }
            }
        }
    }

}
