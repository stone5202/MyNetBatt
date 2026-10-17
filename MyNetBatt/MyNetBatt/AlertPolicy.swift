import Foundation

// MARK: - 提醒規則（不碰系統介面，方便測試）
nonisolated enum AlertPolicy {
    /// 低電量的多段提醒。回傳新的「已提醒門檻」與是否要送出通知。
    /// 通知關閉時不記錄已提醒，之後打開通知仍會在下一次取樣提醒。
    static func lowBattery(level: Int, plugged: Bool, alertLevels: Set<Int>, notified: Set<Int>, enabled: Bool) -> (notified: Set<Int>, notify: Bool) {
        guard !plugged, level > 0 else { return ([], false) }
        // 電量回升到門檻以上（例如充過電又拔掉）時，那個門檻重新計算。
        let still = notified.filter { level <= $0 }
        let crossed = alertLevels.filter { level <= $0 && !still.contains($0) }
        guard !crossed.isEmpty, enabled else { return (still, false) }
        // 一次經過好幾個門檻（例如啟動時就已經很低）只通知一次。
        return (still.union(crossed), true)
    }

    /// 周邊裝置：低於等於 10% 通知一次，回到 20% 以上才重新計算。回傳新的「已提醒裝置」與要通知的裝置名稱。
    static func peripherals(_ devices: [(name: String, level: Int?)], notified: Set<String>, enabled: Bool) -> (notified: Set<String>, notify: [String]) {
        var result = notified
        var notify: [String] = []
        for device in devices {
            guard let level = device.level else { continue }
            if level >= 20 { result.remove(device.name); continue }
            guard level <= 10, !result.contains(device.name), enabled else { continue }
            result.insert(device.name)
            notify.append(device.name)
        }
        return (result, notify)
    }
}
