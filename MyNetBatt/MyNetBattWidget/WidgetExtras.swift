import Foundation

/// 主程式寫給網路、App 用量、儲存空間、Wi‑Fi、周邊電量小工具的資料（電池小工具用 WidgetSnapshot）。
/// 小工具的 `MyNetBattWidget/WidgetExtras.swift` 有同一份定義，修改時兩邊要一起改。
nonisolated struct WidgetExtras: Codable {
    static let fileName = "widget-extras.json"

    enum Kind {
        static let dataUsage = "com.stone5202.MyNetBatt.DataUsageWidget"
        static let appUsage = "com.stone5202.MyNetBatt.AppUsageWidget"
        static let storage = "com.stone5202.MyNetBatt.StorageWidget"
        static let wifi = "com.stone5202.MyNetBatt.WiFiWidget"
        static let peripherals = "com.stone5202.MyNetBatt.PeripheralsWidget"
    }

    struct Traffic: Codable {
        /// 今天 0～23 時每小時的上傳／下載量（位元組）。
        var hourlyUp: [UInt64]
        var hourlyDown: [UInt64]
        /// 最近 7 天（含今天，由舊到新）每天的上傳／下載量。
        var dailyUp: [UInt64]
        var dailyDown: [UInt64]
        var dailyDates: [Date]
    }

    struct AppItem: Codable, Identifiable {
        var id: String { name }
        var name: String
        var bytes: UInt64
        var upload: UInt64
        var download: UInt64
        /// 64×64 的 PNG；不是 App 的程序沒有圖示。
        var icon: Data?
    }

    struct Volume: Codable, Identifiable {
        var id: String { name }
        var name: String
        var used: Int64
        var total: Int64
        var isInternal: Bool
    }

    struct Folder: Codable, Identifiable {
        var id: String { name }
        var name: String
        var bytes: Int64
    }

    struct WiFi: Codable {
        /// 沒有定位權限時為 nil，小工具顯示「Wi‑Fi」。
        var ssid: String?
        var interface: String
        var connected: Bool
        var localIP: String
        var publicIP: String
        /// 訊號格數 0～4；有線網路為 nil。
        var bars: Int?
        var rssi: String
        var channel: String
        var rate: String
    }

    struct Peripheral: Codable, Identifiable {
        var id: String { name }
        var name: String
        var symbol: String
        var level: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?
    }

    var updated: Date
    var traffic: Traffic
    var apps: [AppItem]
    var appsTotal: UInt64
    var volumes: [Volume]
    var folders: [Folder]
    var wifi: WiFi
    var peripherals: [Peripheral]

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> WidgetExtras? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(WidgetExtras.self, from: data)
    }
}
