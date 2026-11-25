// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation

/// 「這一次連線」的記憶：登入頁、沒網路次數、各網路的重試等待、斷線重連。
/// 換到別的 Wi‑Fi 就整個重來，不讓上一個網路的狀態影響下一個。純邏輯，可單獨測試。
struct NetworkTracker {
    private(set) var ssid: String?
    private(set) var portalURL: URL?
    private(set) var offlineStreak = 0
    private(set) var notAssociatedSince: Date?
    private(set) var lastTrustedSSID: String?
    private(set) var lastTrustedSeen: Date?
    private(set) var reconnectAttempts = 0
    private(set) var reconnectRetryAt = Date.distantPast
    private var retryAt: [UUID: Date] = [:]
    private var attention: [UUID: String] = [:]
    private var notified: Set<UUID> = []

    static let reconnectWindow: TimeInterval = 15 * 60
    static let disconnectGrace: TimeInterval = 40
    static let offlineThreshold = 3
    static let maxReconnects = 3

    /// 每次檢查先呼叫。回傳 true 表示換了網路（舊的登入頁、計數、等待都已清掉）。
    @discardableResult
    mutating func observe(associated: Bool, ssid newSSID: String?, trusted: Bool, now: Date) -> Bool {
        guard associated else {
            if notAssociatedSince == nil { notAssociatedSince = now }
            offlineStreak = 0
            return false
        }
        notAssociatedSince = nil
        var changed = false
        if newSSID != ssid {
            changed = true
            ssid = newSSID
            portalURL = nil
            offlineStreak = 0
            reconnectAttempts = 0
            reconnectRetryAt = .distantPast
            retryAt = [:]
            attention = [:]
            notified = []
        }
        if let s = newSSID {
            if trusted {
                lastTrustedSSID = s
                lastTrustedSeen = now
            } else {
                // 已經連到別的（不信任的）網路，就不再替之前的網路重開 Wi‑Fi
                lastTrustedSSID = nil
                lastTrustedSeen = nil
            }
        }
        return changed
    }

    mutating func setPortal(_ url: URL?) { if let url { portalURL = url } }

    mutating func recordOnline() {
        offlineStreak = 0
        reconnectAttempts = 0
        reconnectRetryAt = .distantPast
        attention = [:]
        notified = []
        retryAt = [:]
    }

    mutating func recordOffline() { offlineStreak += 1 }

    // MARK: 自動登入失敗後的等待（每個網路分開）

    func waiting(rule: UUID, now: Date) -> String? {
        guard let t = retryAt[rule], now < t else { return nil }
        return attention[rule] ?? String(localized: "稍後再自動重試")
    }

    /// 記下失敗；回傳 true 表示這次要發通知（同一網路、同一次連線只通知一次）。
    mutating func recordFailure(rule: UUID, message: String, retryIn: TimeInterval, now: Date) -> Bool {
        retryAt[rule] = now.addingTimeInterval(retryIn)
        attention[rule] = message
        return notified.insert(rule).inserted
    }

    mutating func clearWaiting() { retryAt = [:] }

    // MARK: 斷線重連

    /// 要不要關開 Wi‑Fi；要的話回傳是為了哪個網路。
    func reconnectTarget(associated: Bool, currentSSID: String?, allows: (String) -> Bool, now: Date) -> String? {
        guard let t = lastTrustedSSID, allows(t),
              let seen = lastTrustedSeen, now.timeIntervalSince(seen) < Self.reconnectWindow else { return nil }
        if associated {
            guard currentSSID == t, offlineStreak >= Self.offlineThreshold else { return nil }
        } else {
            guard let since = notAssociatedSince, now.timeIntervalSince(since) >= Self.disconnectGrace else { return nil }
        }
        guard reconnectAttempts < Self.maxReconnects, now >= reconnectRetryAt else { return nil }
        return t
    }

    mutating func didReconnect(now: Date) {
        reconnectAttempts += 1
        reconnectRetryAt = now.addingTimeInterval(Double(reconnectAttempts) * 120)
        offlineStreak = 0
        notAssociatedSince = nil
    }

    mutating func resetReconnect() {
        reconnectAttempts = 0
        reconnectRetryAt = .distantPast
    }
}
