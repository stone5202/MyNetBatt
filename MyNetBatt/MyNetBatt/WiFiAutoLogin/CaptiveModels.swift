// 共用核心：獨立 App「Wi‑Fi 自動登入」與 MyNetBatt 共用，改這裡要跑 tools/sync-mynetbatt.sh 同步。
import Foundation
import Combine

/// 這套核心的設定。測試旗標只放在記憶體，不寫進偏好設定（之前寫進去會讓正式版也不發通知）。
enum CaptiveConfig {
    /// 測試、截圖模式（只看啟動參數，不寫進偏好設定）
    nonisolated static let testMode: Bool = ["-autoLoginOnce", "-testMode", "-snapshot"].contains { CommandLine.arguments.contains($0) }

    // ---- 給「放進這套核心的 App」設定（獨立 App 與 MyNetBatt 共用同一份核心）----
    /// 偏好設定 key 的前綴：獨立 App 是空字串；整合進別的 App 時加前綴避免撞名
    @MainActor static var keyPrefix = ""
    /// 紀錄檔放在 ~/Library/Application Support/<logFolder>/events.log
    @MainActor static var logFolder = "WiFiAutoLogin"
    /// 啟動時要不要主動跳定位權限詢問（MyNetBatt 有自己的流程，就不跳）
    @MainActor static var requestLocationOnLaunch = true
    /// 發通知；openPortal＝點通知要打開登入頁
    @MainActor static var notify: (_ title: String, _ body: String, _ openPortal: Bool) -> Void = { _, _, _ in }
    /// 打開登入頁視窗；learn＝直接進教學模式，ruleID＝教學要存到的網路
    @MainActor static var openPortal: (_ learn: Bool, _ ruleID: UUID?) -> Void = { _, _ in }
}

/// 教學模式記下的一個動作：按一顆按鈕，或勾一個方塊。
struct LearnedStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: String        // "click" 或 "check"
    var selector: String    // CSS 選擇器
    var text: String        // 按鈕上的字（找不到選擇器時用來比對）
}

/// 一個要自動登入的網路。用 Wi‑Fi 名稱或登入頁網域比對，任一個對上就算。
struct NetworkRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var ssid: String?
    var portalHost: String?
    var enabled = true
    var autoReconnect = true
    var steps: [LearnedStep] = []

    var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        if let portalHost, !portalHost.isEmpty { return String(localized: "登入頁 \(portalHost)") }
        return String(localized: "未命名網路")
    }

    func matches(ssid current: String?, host: String?) -> Bool {
        if let ssid, !ssid.isEmpty, ssid == current { return true }
        if let portalHost, !portalHost.isEmpty, let host, portalHost.caseInsensitiveCompare(host) == .orderedSame { return true }
        return false
    }

    // ---- 給「放進這套核心的 App」設定（獨立 App 與 MyNetBatt 共用同一份核心）----
    /// 偏好設定 key 的前綴：獨立 App 是空字串；整合進別的 App 時加前綴避免撞名
    @MainActor static var keyPrefix = ""
    /// 紀錄檔放在 ~/Library/Application Support/<logFolder>/events.log
    @MainActor static var logFolder = "WiFiAutoLogin"
    /// 發通知；openPortal＝點通知要打開登入頁
    @MainActor static var notify: (_ title: String, _ body: String, _ openPortal: Bool) -> Void = { _, _, _ in }
    /// 打開登入頁視窗；learn＝直接進教學模式，ruleID＝教學要存到的網路
    @MainActor static var openPortal: (_ learn: Bool, _ ruleID: UUID?) -> Void = { _, _ in }
}

