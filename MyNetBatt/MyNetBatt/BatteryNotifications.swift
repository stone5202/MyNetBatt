import AppKit
import Foundation
import UserNotifications

// MARK: - 電池通知
final class BatteryNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BatteryNotifier()

    /// 尚未詢問過時會跳出系統的通知權限提示。
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(id: String, title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        // 相同 id 的通知會互相取代，通知中心不會堆疊多則同類提醒。
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // 監控中心視窗在最前面時也要顯示橫幅。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension SystemMonitor {
    /// 打開通知開關時確認權限；被拒絕時把開關關回去並讓設定頁顯示提示。
    func ensureNotificationPermission() {
        Task {
            let granted = await BatteryNotifier.shared.requestAuthorization()
            notificationPermissionDenied = !granted
            if !granted {
                notifyLowBattery = false
                notifyFullyCharged = false
                notifyHighTemperature = false
                notifyHealthDrop = false
                notifyPowerSurge = false
                notifySleepDrain = false
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 每次電池取樣後呼叫；只在狀態轉變時通知一次。
    func evaluateBatteryNotifications() {
        defer { hasBatteryNotificationBaseline = true }

        if !isLowBatteryWarning {
            lowBatteryNotified = false
        } else if !lowBatteryNotified {
            lowBatteryNotified = true
            if notifyLowBattery {
                BatteryNotifier.shared.post(
                    id: "lowBattery", title: "電量不足",
                    body: "電量剩餘 \(batPct)%，請接上電源。", sound: notificationSound
                )
            }
        }

        // 充滿後電量可能在 99～100% 之間來回，降到 95% 以下或拔掉電源才重新計算。
        if !isPluggedIn || batPct < 95 { fullChargeNotified = false }
        if isPluggedIn, batPct >= 100, !fullChargeNotified {
            fullChargeNotified = true
            // 啟動時就已經充滿的情況不通知。
            if notifyFullyCharged, hasBatteryNotificationBaseline {
                BatteryNotifier.shared.post(
                    id: "fullyCharged", title: "電量已充滿",
                    body: "電池已充電至 100%。", sound: notificationSound
                )
            }
        }

        // 降到門檻以下 3°C 才重新計算，溫度在門檻附近來回時不會重複通知。
        if batTempDouble < Self.highTemperatureCelsius - 3 {
            highTemperatureNotified = false
        } else if batTempDouble >= Self.highTemperatureCelsius, !highTemperatureNotified {
            highTemperatureNotified = true
            if notifyHighTemperature {
                BatteryNotifier.shared.post(
                    id: "highTemperature", title: "電池溫度偏高",
                    body: "電池溫度已達 \(batTempDisplay)，建議降低負載或移到通風處。", sound: notificationSound
                )
            }
        }

        // 短暫的尖峰不算，放電功率要持續超過門檻一分鐘才通知。
        let dischargeWatts = isPluggedIn ? 0 : -batterySignedWatts
        let surgeWatts = Double(powerSurgeThreshold)
        if dischargeWatts < surgeWatts {
            powerSurgeStart = nil
            if dischargeWatts < surgeWatts * 0.7 { powerSurgeNotified = false }
        } else if let start = powerSurgeStart {
            if !powerSurgeNotified, Date().timeIntervalSince(start) >= 60 {
                powerSurgeNotified = true
                if notifyPowerSurge {
                    let body = String(format: "電池放電功率已持續超過 %d W（目前 %.1f W）。", powerSurgeThreshold, dischargeWatts)
                    let sound = notificationSound
                    // 找出當下最吃 CPU 的 App 要執行 ps，放到背景做。
                    Task.detached { [self] in
                        let culprit = self.topCPUConsumer().map { "CPU 用量最高的是「\($0.name)」（約 \($0.percent)%）。" }
                        await BatteryNotifier.shared.post(
                            id: "powerSurge", title: "耗電量偏高",
                            body: body + (culprit ?? "電量會消耗得比較快。"), sound: sound
                        )
                    }
                }
            }
        } else {
            powerSurgeStart = Date()
        }
    }

    /// 目前 CPU 用量最高的 App（Helper 等附屬程序算在所屬的 App 上）；用量都很低時回傳 nil。
    /// 百分比以單一核心為 100%，多核心滿載時會超過 100。
    nonisolated func topCPUConsumer() -> (name: String, percent: Int)? {
        let output = runCommand("/bin/ps", ["-Aceo", "pid=,pcpu=,comm=", "-r"])
        var totals: [String: Double] = [:]
        for line in output.split(separator: "\n").prefix(30) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), let cpu = Double(fields[1]), cpu > 0 else { continue }
            let process = String(fields[2]).trimmingCharacters(in: .whitespaces)
            let name = AppOwnerResolver.shared.owner(pid: pid, processName: process)?.name ?? process
            totals[name, default: 0] += cpu
        }
        guard let top = totals.max(by: { $0.value < $1.value }), top.value >= 30 else { return nil }
        return (top.key, Int(top.value.rounded()))
    }

    static let highTemperatureCelsius = 40.0

    var highTemperatureLabel: String {
        tempDisplayInFahrenheit
            ? String(format: "%.0f°F", Self.highTemperatureCelsius * 9.0 / 5.0 + 32.0)
            : String(format: "%.0f°C", Self.highTemperatureCelsius)
    }

    /// macOS 顯示的健康度偶爾會回升 1% 再下降，所以只在低於曾經見過的最低值時通知。
    func notifyHealthDropIfNeeded(_ health: Int) {
        let defaults = UserDefaults.standard
        guard let lowest = defaults.object(forKey: "lowestSeenBatteryHealth") as? Int else {
            defaults.set(batteryHealthLog.map(\.health).min().map { min($0, health) } ?? health, forKey: "lowestSeenBatteryHealth")
            return
        }
        guard health < lowest else { return }
        defaults.set(health, forKey: "lowestSeenBatteryHealth")
        if notifyHealthDrop {
            BatteryNotifier.shared.post(
                id: "healthDrop", title: "電池健康度下降",
                body: "電池最大容量由 \(lowest)% 降為 \(health)%。", sound: notificationSound
            )
        }
    }

    // MARK: 低耗電模式自動化
    /// 每次電池取樣後呼叫。每次降到門檻以下只開啟一次；接上電源時只關閉由這裡開啟的低耗電模式。
    func evaluateAutoLowPowerMode() {
        let helper = PrivilegedHelperManager.shared
        if isPluggedIn || batPct > autoLowPowerThreshold { autoLowPowerHandled = false }

        if isPluggedIn {
            guard autoLowPowerEngaged, !helper.isBusy else { return }
            autoLowPowerEngaged = false
            if autoLowPowerMode, helper.isLowPowerModeEnabled { helper.setLowPowerMode(false) }
            return
        }

        guard autoLowPowerMode, batPct > 0, batPct <= autoLowPowerThreshold, !autoLowPowerHandled,
              helper.registrationState == .enabled, !helper.isBusy else { return }
        autoLowPowerHandled = true
        guard !helper.isLowPowerModeEnabled else { return }
        autoLowPowerEngaged = true
        helper.setLowPowerMode(true)
    }

    // MARK: 睡眠耗電
    func handleSystemWillSleep() {
        guard batPct > 0 else { return }
        sleepStart = (Date(), batPct, isPluggedIn)
        pendingWakeTime = nil
    }

    /// 喚醒後電量計要過幾秒才會更新，所以等喚醒 10 秒後的取樣再結算。
    func finishSleepRecordIfNeeded() {
        guard let wake = pendingWakeTime, let start = sleepStart, Date().timeIntervalSince(wake) >= 10 else { return }
        pendingWakeTime = nil
        sleepStart = nil

        // 睡眠前後有接電源時，電量變化不代表睡眠耗電；太短的睡眠也看不出來。
        let duration = wake.timeIntervalSince(start.time)
        guard !start.plugged, !isPluggedIn, duration >= 600 else { return }

        let minutes = Int(duration / 60)
        let length = minutes >= 60 ? "\(minutes / 60) 小時 \(minutes % 60) 分" : "\(minutes) 分"
        let drop = max(0, start.level - batPct)
        let perHour = Double(drop) / (duration / 3600)
        let summary = String(
            format: "上次睡眠（%@ 喚醒）：%@，%d%% → %d%%，每小時 %.1f%%",
            Self.sleepWakeFormatter.string(from: wake), length, start.level, batPct, perHour
        )
        assignIfChanged(\.sleepSummaryText, summary)
        UserDefaults.standard.set(summary, forKey: "lastSleepSummary")

        if notifySleepDrain, drop >= 3, perHour >= 2 {
            BatteryNotifier.shared.post(
                id: "sleepDrain", title: "睡眠期間耗電偏高",
                body: "睡眠 \(length)，電量由 \(start.level)% 降到 \(batPct)%，可能有 App 或周邊裝置讓 Mac 無法進入深度睡眠。",
                sound: notificationSound
            )
        }
    }

    private static let sleepWakeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}
