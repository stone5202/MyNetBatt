import Foundation

// MARK: - 每日網卡用量（不碰系統介面，方便測試）
nonisolated enum TrafficSeries {
    /// 把某一天的每小時用量結算成當天總量，並只保留 cutoffDay（含）之後的日子。
    static func archive(day: String, upload: [UInt64], download: [UInt64], into log: [String: [UInt64]], cutoffDay: String) -> [String: [UInt64]] {
        var result = log
        let up = upload.reduce(0, +), down = download.reduce(0, +)
        if !day.isEmpty, up > 0 || down > 0 { result[day] = [up, down] }
        return result.filter { $0.key >= cutoffDay }
    }

    /// 小工具「最近 N 天」的每日用量（由舊到新，最後一天是今天）。
    /// 今天用網卡的每小時統計；過去用換日時結算的網卡總量；更早、還沒有網卡總量的日子才用 App 統計。
    static func daily(dayKeys: [String], todayKey: String, hourlyDay: String, hourlyUp: [UInt64], hourlyDown: [UInt64],
                      archived: [String: [UInt64]], appSplit: [String: [String: [UInt64]]]) -> (up: [UInt64], down: [UInt64]) {
        var ups: [UInt64] = [], downs: [UInt64] = []
        for key in dayKeys {
            if key == todayKey {
                let current = hourlyDay == key
                ups.append(current ? hourlyUp.reduce(0, +) : 0)
                downs.append(current ? hourlyDown.reduce(0, +) : 0)
            } else if key == hourlyDay {
                // 剛過午夜還沒取樣時，昨天的每小時統計還沒結算，直接用它。
                ups.append(hourlyUp.reduce(0, +))
                downs.append(hourlyDown.reduce(0, +))
            } else if let stored = archived[key], stored.count == 2 {
                ups.append(stored[0])
                downs.append(stored[1])
            } else {
                let split = appSplit[key] ?? [:]
                ups.append(split.values.reduce(0) { $0 + ($1.first ?? 0) })
                downs.append(split.values.reduce(0) { $0 + ($1.count == 2 ? $1[1] : 0) })
            }
        }
        return (ups, downs)
    }
}
