import SwiftUI

// MARK: - 連接埠頁
/// 每個連接埠在傳什麼、誰在限速，以及透過 Thunderbolt／USB‑C 連接的設備。
struct PortsDetailView: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        let connected = monitor.portInfos.filter(\.isConnected).count
        PageScroll {
            PageHeader(
                title: "連接埠",
                subtitle: connected == 0 ? String(localized: "連接埠、線材與 Thunderbolt 設備") : String(localized: "\(connected) 個連接埠使用中"),
                symbol: MainTab.ports.symbol, color: MainTab.ports.color
            ) {
                Toggle("技術細節", isOn: $monitor.portsShowTechDetails)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button {
                    monitor.fetchPortInfo()
                    monitor.fetchThunderboltDevices()
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }
            }

            PortsCard(monitor: monitor)
            ThunderboltDevicesCard(monitor: monitor)

            Text("線材資訊來自線材內的 e‑marker 晶片；沒有晶片的基本線材、MagSafe 線讀不到規格。插拔後幾秒內會自動更新。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { monitor.fetchPortInfo() }
    }
}
