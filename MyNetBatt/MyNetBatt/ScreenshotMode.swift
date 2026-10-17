import Foundation

#if DEBUG
/// 只有 Debug 版：以 `-ScreenshotMode YES` 啟動時，把 Wi‑Fi 名稱、IP、MAC 位址換成示範值，
/// 給 README 截圖用，避免公開真實的網路資訊。正式版不包含這段程式。
nonisolated enum ScreenshotMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "ScreenshotMode") }

    static func mask(_ info: WiFiInfo) -> WiFiInfo {
        WiFiInfo(
            ssid: "Wi‑Fi", channel: info.channel, rssi: info.rssi, noise: info.noise,
            transmitRate: info.transmitRate, macAddress: "a4:83:e7:00:00:00", security: info.security
        )
    }
}
#endif
