import SwiftUI
import Foundation
import CoreWLAN
import CoreLocation

// MARK: - Wi‑Fi 詳情
nonisolated struct WiFiInfo: Equatable, Sendable {
    /// macOS 需要定位權限才會回傳 Wi‑Fi 名稱；未授權時為 nil。
    let ssid: String?
    let channel: String
    let rssi: Int
    let noise: Int
    let transmitRate: Double
    let macAddress: String
    let security: String

    var signalQuality: String {
        if rssi >= -50 { return "極佳" }
        if rssi >= -60 { return "良好" }
        if rssi >= -70 { return "普通" }
        return "微弱"
    }

    var rssiText: String { "\(rssi) dBm（\(signalQuality)）" }
    var transmitRateText: String { String(format: "%.0f Mbps", transmitRate) }
}

nonisolated enum WiFiReader {
    static func snapshot() -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let channel = interface.wlanChannel() else { return nil }
        let rssi = interface.rssiValue()
        // 未連上任何網路時 RSSI 為 0。
        guard rssi != 0 else { return nil }

        let band: String
        switch channel.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = ""
        }
        let width: String
        switch channel.channelWidth {
        case .width20MHz: width = "20 MHz"
        case .width40MHz: width = "40 MHz"
        case .width80MHz: width = "80 MHz"
        case .width160MHz: width = "160 MHz"
        default: width = ""
        }
        let channelText = (["\(channel.channelNumber)", band, width].filter { !$0.isEmpty }).joined(separator: " · ")

        let security: String
        switch interface.security() {
        case .none: security = "無"
        case .WEP: security = "WEP"
        case .wpaPersonal, .wpaPersonalMixed: security = "WPA 個人級"
        case .wpa2Personal: security = "WPA2 個人級"
        case .personal: security = "WPA/WPA2 個人級"
        case .wpa3Personal: security = "WPA3 個人級"
        case .wpa3Transition: security = "WPA2/WPA3 個人級"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: security = "企業級"
        case .OWE, .oweTransition: security = "OWE"
        default: security = "--"
        }

        return WiFiInfo(
            ssid: interface.ssid(),
            channel: channelText,
            rssi: rssi,
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            macAddress: interface.hardwareAddress() ?? "--",
            security: security
        )
    }
}

/// 只在使用者主動要求顯示 Wi‑Fi 名稱時才建立，不會在啟動時跳出定位權限提示。
final class WiFiLocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func request() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange() }
    }
}

extension SystemMonitor {
    func fetchWiFiInfo() {
        runExclusive("wifiInfo") {
            let info = WiFiReader.snapshot()
            await MainActor.run { self.assignIfChanged(\.wifiInfo, info) }
        }
    }

    /// 第一次會跳出系統的定位權限提示；先前已拒絕時改為打開系統設定。
    func requestWiFiNameAccess() {
        let authorizer = wifiLocationAuthorizer ?? WiFiLocationAuthorizer { [weak self] in self?.fetchWiFiInfo() }
        wifiLocationAuthorizer = authorizer
        switch authorizer.status {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            authorizer.request()
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        default:
            fetchWiFiInfo()
        }
    }
}

struct WiFiNameAccessButton: View {
    @Bindable var monitor: SystemMonitor
    var body: some View {
        Button("顯示 Wi‑Fi 名稱…") { monitor.requestWiFiNameAccess() }
            .controlSize(.small)
            .help("macOS 需要定位權限才能讀取 Wi‑Fi 名稱；MyNetBatt 不會記錄或傳送位置")
    }
}
