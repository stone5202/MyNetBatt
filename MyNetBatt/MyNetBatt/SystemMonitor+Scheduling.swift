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
                // 訊號強度與傳輸率變動頻繁，只在網路畫面開著時跟著更新。
                if !perAppUsageViewers.isEmpty { fetchWiFiInfo() }
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
            if wasHidden { fetchPerAppNetworkTraffic(); fetchWiFiInfo() }
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
        var uploads: [String: UInt64] = [:]
        var downloads: [String: UInt64] = [:]
        // 舊版把 Helper 記成獨立的程序（如「Microsoft Edge Helper」）；所屬 App 已知時併回去。
        func canonical(_ name: String) -> String {
            guard appUsageBundlePaths[name] == nil, let range = name.range(of: " Helper") else { return name }
            let base = String(name[..<range.lowerBound])
            return appUsageBundlePaths[base] != nil ? base : name
        }
        func add(_ usage: [String: UInt64], _ split: [String: [UInt64]]) {
            for (name, bytes) in usage { totals[canonical(name), default: 0] += bytes }
            for (name, pair) in split where pair.count == 2 {
                let name = canonical(name)
                uploads[name, default: 0] += pair[0]
                downloads[name, default: 0] += pair[1]
            }
        }
        if days > 31 {
            // 「年」：每日明細只保留 31 天，改用每月統計（最近 12 個月）。
            for (key, usage) in appUsageMonthly { add(usage, appUsageMonthlySplit[key] ?? [:]) }
        } else {
            for offset in 0..<max(1, days) {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
                let key = formatter.string(from: date)
                add(appUsageHistory[key] ?? [:], appUsageSplit[key] ?? [:])
            }
        }

        if totals.isEmpty {
            for usage in appNetworkUsages {
                totals[usage.name, default: 0] += usage.totalDownload + usage.totalUpload
                uploads[usage.name, default: 0] += usage.totalUpload
                downloads[usage.name, default: 0] += usage.totalDownload
            }
        }

        let items = totals.map { name, bytes in
            let pid = appNetworkUsages.first(where: { $0.name == name })?.pid
            return AppDataUsageItem(
                id: name, name: name, bytes: bytes, pid: pid,
                upload: uploads[name] ?? 0, download: downloads[name] ?? 0,
                bundlePath: appUsageBundlePaths[name]
            )
        }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard usageGrouping == 0 else { return items }

        // 只列 App：其餘程序合併成最後一列，總計才不會少算。
        var apps = items.filter { $0.bundlePath != nil }
        let others = items.filter { $0.bundlePath == nil }
        if !others.isEmpty {
            apps.append(AppDataUsageItem(
                id: Self.otherProcessesName, name: Self.otherProcessesName,
                bytes: others.reduce(0) { $0 + $1.bytes }, pid: nil,
                upload: others.reduce(0) { $0 + $1.upload }, download: others.reduce(0) { $0 + $1.download }
            ))
        }
        return apps
    }

    /// 「正在使用網路」清單用：依顯示方式把不屬於 App 的程序合併成一列。
    var displayedNetworkUsages: [AppNetworkUsage] {
        guard usageGrouping == 0 else { return appNetworkUsages }
        var apps = appNetworkUsages.filter { $0.bundlePath != nil }
        let others = appNetworkUsages.filter { $0.bundlePath == nil }
        if !others.isEmpty {
            apps.append(AppNetworkUsage(
                id: Self.otherProcessesName, name: Self.otherProcessesName, pid: nil,
                downloadSpeed: others.reduce(0) { $0 + $1.downloadSpeed },
                uploadSpeed: others.reduce(0) { $0 + $1.uploadSpeed },
                totalDownload: others.reduce(0) { $0 + $1.totalDownload },
                totalUpload: others.reduce(0) { $0 + $1.totalUpload }
            ))
        }
        return apps.sorted { ($0.downloadSpeed + $0.uploadSpeed) > ($1.downloadSpeed + $1.uploadSpeed) }
    }

    /// 用量長條圖的資料：週、月為每日一根，年為每月一根；每根依下載、上傳、未分類堆疊。
    func usageBarPoints(days: Int) -> [UsageBarPoint] {
        let calendar = Calendar.current
        var points: [UsageBarPoint] = []
        func append(key: String, date: Date, usage: [String: UInt64], split: [String: [UInt64]]) {
            let total = usage.values.reduce(0, +)
            let upload = split.values.reduce(UInt64(0)) { $0 + ($1.first ?? 0) }
            let download = split.values.reduce(UInt64(0)) { $0 + ($1.count == 2 ? $1[1] : 0) }
            let unknown = total > upload + download ? total - upload - download : 0
            points.append(UsageBarPoint(id: "\(key)-down", date: date, kind: "下載", bytes: Double(download)))
            points.append(UsageBarPoint(id: "\(key)-up", date: date, kind: "上傳", bytes: Double(upload)))
            if unknown > 0 {
                points.append(UsageBarPoint(id: "\(key)-unknown", date: date, kind: "未分類", bytes: Double(unknown)))
            }
        }
        if days > 31 {
            let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
            for offset in (0..<12).reversed() {
                guard let date = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
                let key = String(Self.dayKeyFormatter.string(from: date).prefix(7))
                append(key: key, date: date, usage: appUsageMonthly[key] ?? [:], split: appUsageMonthlySplit[key] ?? [:])
            }
        } else {
            let today = calendar.startOfDay(for: Date())
            for offset in (0..<max(1, days)).reversed() {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                let key = Self.dayKeyFormatter.string(from: date)
                append(key: key, date: date, usage: appUsageHistory[key] ?? [:], split: appUsageSplit[key] ?? [:])
            }
        }
        return points
    }

    func appDataUsageTotal(days: Int) -> UInt64 {
        appDataUsageItems(days: days).reduce(0) { $0 + $1.bytes }
    }

    static let batteryVisibleInterval: TimeInterval = 1.5
    /// 電池的電流、電量大約 30～60 秒才更新一次，沒有畫面在看時不需要每 1.5 秒讀一次。
    static let batteryBackgroundInterval: TimeInterval = 10

    func startDetailedBatteryMonitor() {
        // 插拔電源由系統通知立即更新，不必等下一輪取樣。
        powerSourceObserver = PowerSourceObserver { [weak self] in self?.fetchDynamicBatteryInfo() }
        Task {
            while !Task.isCancelled {
                let interval = batteryViewers.isEmpty ? Self.batteryBackgroundInterval : Self.batteryVisibleInterval
                let elapsed = lastBatterySampleTime.map { Date().timeIntervalSince($0) } ?? .infinity
                if elapsed >= interval - 0.2 { fetchDynamicBatteryInfo() }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// 電池小視窗或監控中心的電池頁開著時，恢復每 1.5 秒取樣。
    func setBatteryDetailVisible(_ visible: Bool, source: String) {
        if visible {
            let wasHidden = batteryViewers.isEmpty
            batteryViewers.insert(source)
            if wasHidden { fetchDynamicBatteryInfo(); fetchPortInfo() }
        } else {
            batteryViewers.remove(source)
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
                fetchPortInfo()
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
            self?.refreshPortInfoAfterPlugChange()
        }
    }

}
