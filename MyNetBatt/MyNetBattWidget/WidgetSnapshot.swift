import Foundation

/// 主程式寫給桌面小工具的電池資料。小工具在沙盒裡讀不到主程式的設定與紀錄，
/// 所以由主程式把要顯示的內容寫進共用的 App Group 資料夾。
/// 主程式的 `MyNetBatt/WidgetSnapshot.swift` 有同一份定義，修改時兩邊要一起改。
struct WidgetSnapshot: Codable {
    static let appGroup = "MHCATJULGT.com.stone5202.MyNetBatt"
    static let fileName = "widget-snapshot.json"
    static let widgetKind = "com.stone5202.MyNetBatt.BatteryWidget"

    var updated: Date
    var level: Int
    var plugged: Bool
    var charging: Bool
    /// 「預估剩餘時間」「預估充滿時間」或「狀態」。
    var timeTitle: String
    var timeText: String
    var health: String
    var cycles: String
    var temperature: String
    var watts: String
    /// 過去 24 小時每 30 分鐘一格的電量；沒有紀錄的格子為 nil。
    var levels: [Int?]
    /// 對應每一格是否接著電源。
    var pluggedFlags: [Bool?]

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
