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
    }
}
