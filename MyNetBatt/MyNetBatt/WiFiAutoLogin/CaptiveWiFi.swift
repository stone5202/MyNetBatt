// 共用核心（見 CaptiveModels.swift 開頭說明）
import Combine
import Foundation
import CoreWLAN
import CoreLocation

/// 讀 Wi‑Fi 狀態、管定位權限（macOS 14 起要有定位權限才讀得到 Wi‑Fi 名稱）、重開 Wi‑Fi。
@MainActor
final class CaptiveWiFi: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CaptiveWiFi()

    struct Snapshot {
        var powerOn: Bool
        var associated: Bool
        var ssid: String?
        var interfaceName: String?
    }

    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        locationStatus = manager.authorizationStatus
    }

    var locationAuthorized: Bool {
        // macOS 上授權後是 authorizedAlways（3）；4 是 whenInUse
        locationStatus.rawValue >= 3
    }

    var locationStatusText: String {
        switch locationStatus {
        case .notDetermined: return String(localized: "尚未詢問")
        case .denied: return String(localized: "已拒絕")
        case .restricted: return String(localized: "受限制")
        default: return locationAuthorized ? String(localized: "已允許") : String(localized: "未知")
        }
    }

    func requestLocationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let changed = self.locationStatus != status
            self.locationStatus = status
            // 剛允許定位：馬上重新讀 Wi‑Fi 名稱
            if changed { CaptiveEngine.shared.scheduleCheck(after: 0.5) }
        }
    }

    private var iface: CWInterface? { CWWiFiClient.shared().interface() }

    func snapshot() -> Snapshot {
        guard let i = iface else { return Snapshot(powerOn: false, associated: false, ssid: nil, interfaceName: nil) }
        let power = i.powerOn()
        // 傳輸速率／訊號強度不需要定位權限，用來判斷有沒有連上基地台
        let associated = power && (i.transmitRate() > 0 || i.rssiValue() != 0)
        var ssid = i.ssid()
        if let s = ssid, s.isEmpty { ssid = nil }
        if let forced = UserDefaults.standard.string(forKey: "testSSID") { ssid = forced }
        return Snapshot(powerOn: power, associated: associated, ssid: ssid, interfaceName: i.interfaceName)
    }

    /// App 關掉了 Wi‑Fi、還沒打開回來（這時結束 App 要先打開）
    private(set) var poweredOffByApp = false

    /// 關掉 Wi‑Fi 再打開，讓系統重新加入偏好的網路（醫院登入頁通常會跟著重新出現）。
    func powerCycle() async -> Bool {
        guard let i = iface else { return false }
        let name = i.interfaceName
        var usedFallback = false
        do {
            try i.setPower(false)
        } catch {
            guard let name, await Self.networksetup(name, on: false) else { return false }
            usedFallback = true
        }
        poweredOffByApp = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return await powerOn(i, name: name, preferFallback: usedFallback)
    }

    private func powerOn(_ i: CWInterface, name: String?, preferFallback: Bool) async -> Bool {
        if !preferFallback { try? i.setPower(true) }
        if !i.powerOn(), let name { _ = await Self.networksetup(name, on: true) }
        let ok = i.powerOn()
        if ok { poweredOffByApp = false }
        return ok
    }

    /// 結束 App 時呼叫：如果是 App 關掉的 Wi‑Fi，先打開。
    func restoreIfNeeded() {
        guard poweredOffByApp, let i = iface else { return }
        try? i.setPower(true)
        if !i.powerOn(), let name = i.interfaceName {
            _ = Self.runSync("/usr/sbin/networksetup", ["-setairportpower", name, "on"], timeout: 5)
        }
        poweredOffByApp = false
    }

    /// networksetup 放到背景執行，最多等 10 秒，不卡住畫面。
    private static func networksetup(_ name: String, on: Bool) async -> Bool {
        await Task.detached {
            runSync("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"], timeout: 10)
        }.value
    }

    nonisolated private static func runSync(_ path: String, _ args: [String], timeout: TimeInterval) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { return false }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { usleep(100_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }
}
