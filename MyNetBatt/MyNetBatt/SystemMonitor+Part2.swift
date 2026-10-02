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
        fetchNetworkDetails(forcePublicIP: true)
    }

    func appDataUsageItems(days: Int) -> [AppDataUsageItem] {
        let calendar = Calendar.current
        let formatter = Self.dayKeyFormatter
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
                // 健康度與循環次數變化很慢，system_profiler 又很耗資源，10 分鐘更新一次即可。
                try? await Task.sleep(nanoseconds: 600_000_000_000)
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
                // 插拔由 DeviceChangeObserver 即時觸發，這裡只是低頻率的保底更新。
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    /// 裝置插拔常會連續觸發多次通知（例如 Hub 上的多個裝置），合併成一次掃描。
    func scheduleDeviceRefresh() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.fetchThunderboltDevices()
        }
    }

}
