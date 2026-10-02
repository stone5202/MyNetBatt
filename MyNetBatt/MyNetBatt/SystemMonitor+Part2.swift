import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    /// nettop 每次都要 spawn 子程序：網路頁面打開時每 2 秒取樣，關著時每 60 秒取樣一次。
    /// nettop 回報的是各程序的累計流量，間隔拉長仍能算出差額，今日／近 7 日統計不會漏掉長時間執行的 App。
    static let perAppVisibleInterval: TimeInterval = 2
    static let perAppBackgroundInterval: TimeInterval = 60

    func startPerAppNetworkMonitor() {
        Task {
            while !Task.isCancelled {
                let interval = perAppUsageViewers.isEmpty ? Self.perAppBackgroundInterval : Self.perAppVisibleInterval
                let elapsed = lastAppNetworkSampleTime.map { Date().timeIntervalSince($0) } ?? .infinity
                if elapsed >= interval - 0.5 {
                    fetchPerAppNetworkTraffic()
                }
                // 只是檢查是否該取樣，不會 spawn 子程序；畫面打開後最多 2 秒內就會切換成快速取樣。
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func setPerAppUsageVisible(_ visible: Bool, source: String) {
        if visible {
            let wasHidden = perAppUsageViewers.isEmpty
            perAppUsageViewers.insert(source)
            // 打開時立刻更新一次，不必等下一輪。
            if wasHidden { fetchPerAppNetworkTraffic() }
        } else {
            perAppUsageViewers.remove(source)
        }
    }

    /// 網路資訊（介面、IP、閘道、DNS）需要執行 route、ifconfig、scutil 等指令：
    /// 改由 NWPathMonitor 在網路環境變動時觸發，另每 5 分鐘保底更新一次。
    func startNetworkDetailsMonitor() {
        let monitor = NWPathMonitor()
        // SystemMonitor 與 App 同生命週期，以 unowned 參照即可。
        monitor.pathUpdateHandler = { [unowned self] _ in
            Task { @MainActor in self.scheduleNetworkDetailsRefresh() }
        }
        monitor.start(queue: DispatchQueue(label: "com.stone5202.MyNetBatt.path-monitor"))
        networkPathMonitor = monitor

        Task {
            while !Task.isCancelled {
                fetchNetworkDetails()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    /// 切換 Wi-Fi 等情況會連續觸發多次路徑變更，等網路穩定後再查詢一次。
    func scheduleNetworkDetailsRefresh() {
        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.fetchNetworkDetails()
        }
    }

    func startStorageMonitor() {
        Task {
            while !Task.isCancelled {
                fetchStorageInfo()
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
