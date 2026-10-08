import Foundation
import WidgetKit

/// 主程式寫給桌面小工具的電池資料。小工具在沙盒裡讀不到主程式的設定與紀錄，
/// 所以由主程式把要顯示的內容寫進共用的 App Group 資料夾。
/// 小工具的 `MyNetBattWidget/WidgetSnapshot.swift` 有同一份定義，修改時兩邊要一起改。
nonisolated struct WidgetSnapshot: Codable {
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
}

extension SystemMonitor {
    /// 每次電池取樣後呼叫。電量或電源狀態改變時立即寫入並要求小工具重新載入；
    /// 其餘數值（剩餘時間、功率、溫度）最多每 5 分鐘更新一次。
    func publishWidgetSnapshot() {
        guard batPct > 0 else { return }
        // 健康度在啟動後幾秒才讀到，也算進去，否則小工具會停在「--」直到下一次更新。
        let key = "\(batPct)-\(isPluggedIn)-\(isCharging)-\(batHealth)-\(batCycle)"
        let changed = key != lastWidgetSnapshotKey
        let now = Date()
        if !changed, let last = lastWidgetSnapshotTime, now.timeIntervalSince(last) < 300 { return }
        lastWidgetSnapshotKey = key
        lastWidgetSnapshotTime = now

        let buckets = BatteryTimeline(history: batteryHistory, now: now).buckets.suffix(48)
        let snapshot = WidgetSnapshot(
            updated: now, level: batPct, plugged: isPluggedIn, charging: isCharging,
            timeTitle: batteryTimeTitle, timeText: batTimeRemain,
            health: batHealth, cycles: batCycle, temperature: batTempDisplay, watts: batWatts,
            levels: buckets.map(\.level), pluggedFlags: buckets.map(\.plugged)
        )
        Task.detached(priority: .utility) {
            guard let url = WidgetSnapshot.fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        }
    }
}
