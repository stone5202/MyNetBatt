import AppKit
import WidgetKit

// MARK: - 寫給小工具的資料
extension SystemMonitor {
    /// 每分鐘把資料寫進 App Group；系統對小工具的重新載入次數有限額，
    /// 所以只在內容明顯改變（裝置連線、換網路、掛載磁碟）或距上次超過 15 分鐘時才要求重新載入。
    func startWidgetExtrasPublisher() {
        Task {
            // 啟動後等各項取樣完成再寫第一次。
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                publishWidgetExtras()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func publishWidgetExtras() {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let dailyDates = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let series = TrafficSeries.daily(
            dayKeys: dailyDates.map { Self.dayKeyFormatter.string(from: $0) },
            todayKey: Self.dayKeyFormatter.string(from: today),
            hourlyDay: hourlyTraffic.day, hourlyUp: hourlyTraffic.upload, hourlyDown: hourlyTraffic.download,
            archived: dailyTraffic, appSplit: appUsageSplit
        )
        let dailyUp = series.up, dailyDown = series.down
        // 主程式剛啟動、還沒取樣到今天的流量時，hourlyTraffic 可能還是前一天的；那時今天的小時統計為 0。
        let todayKey = Self.dayKeyFormatter.string(from: today)
        let isToday = hourlyTraffic.day == todayKey
        let traffic = WidgetExtras.Traffic(
            hourlyUp: isToday ? hourlyTraffic.upload : Array(repeating: 0, count: 24),
            hourlyDown: isToday ? hourlyTraffic.download : Array(repeating: 0, count: 24),
            dailyUp: dailyUp, dailyDown: dailyDown, dailyDates: dailyDates
        )

        let appItems = appDataUsageItems(days: 1)
        let apps = appItems.prefix(8).map { item in
            WidgetExtras.AppItem(
                name: item.name, bytes: item.bytes, upload: item.upload, download: item.download,
                icon: item.bundlePath.flatMap { widgetIconPNG(for: $0) }
            )
        }

        let volumes = storageVolumes.map {
            WidgetExtras.Volume(name: $0.name, used: $0.usedBytes, total: $0.totalBytes, isInternal: $0.isInternal)
        }
        let folders = StorageScanner.shared.folderResults.filter { $0.status != .denied }.prefix(6).map { WidgetExtras.Folder(name: $0.name, bytes: $0.bytes) }

        let wifi = WidgetExtras.WiFi(
            ssid: wifiInfo?.ssid, interface: networkInterfaceName,
            connected: networkLocalIP != "--" && !networkLocalIP.isEmpty,
            localIP: networkLocalIP, publicIP: networkPublicIP,
            bars: wifiInfo.map { Self.signalBars(rssi: $0.rssi) },
            rssi: wifiInfo.map { "\($0.rssi) dBm" } ?? "--",
            channel: wifiInfo?.channel ?? "--",
            rate: wifiInfo?.transmitRateText ?? "--"
        )

        let peripheralsOut = peripherals.map {
            WidgetExtras.Peripheral(name: $0.name, symbol: $0.symbol, level: $0.level, left: $0.left, right: $0.right, caseLevel: $0.caseLevel)
        }

        let extras = WidgetExtras(
            updated: now, traffic: traffic, apps: Array(apps), appsTotal: appItems.reduce(0) { $0 + $1.bytes },
            volumes: volumes, folders: Array(folders), wifi: wifi, peripherals: peripheralsOut
        )

        // 各小工具「明顯改變」的判斷依據。
        let keys: [String: String] = [
            WidgetExtras.Kind.dataUsage: "\(traffic.hourlyUp.reduce(0, +) / 50_000_000)-\(traffic.hourlyDown.reduce(0, +) / 50_000_000)",
            WidgetExtras.Kind.appUsage: apps.prefix(5).map(\.name).joined(separator: "|"),
            WidgetExtras.Kind.storage: volumes.map { "\($0.name):\($0.used / 5_000_000_000)" }.joined(separator: "|") + "\(folders.count)",
            WidgetExtras.Kind.wifi: "\(wifi.ssid ?? "")-\(wifi.interface)-\(wifi.connected)-\(wifi.localIP)-\(wifi.publicIP)-\(wifi.bars ?? -1)",
            WidgetExtras.Kind.peripherals: peripherals.map { "\($0.name):\(($0.primaryLevel ?? -1) / 5)" }.joined(separator: "|")
        ]
        var reload: [String] = []
        for (kind, key) in keys {
            let changed = widgetExtrasKeys[kind] != key
            let stale = widgetExtrasReloads[kind].map { now.timeIntervalSince($0) >= 900 } ?? true
            if changed || stale {
                reload.append(kind)
                widgetExtrasKeys[kind] = key
                widgetExtrasReloads[kind] = now
            }
        }

        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            guard let url = WidgetExtras.fileURL, let data = try? encoder.encode(extras) else { return }
            try? data.write(to: url, options: .atomic)
            for kind in reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
    }

    /// 訊號格數：和系統選單列的 Wi‑Fi 圖示大致相同的分界。
    static func signalBars(rssi: Int) -> Int {
        switch rssi {
        case (-55)...: return 4
        case (-65)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }

    /// App 圖示縮成 64×64 的 PNG；同一個 App 只產生一次。
    func widgetIconPNG(for bundlePath: String) -> Data? {
        if let cached = widgetIconCache[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        let size = NSSize(width: 64, height: 64)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])
        widgetIconCache[bundlePath] = data
        return data
    }
}
