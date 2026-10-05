import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 網路子視窗 (Popover)
struct NetworkPopoverView: View {
    @Bindable var monitor: SystemMonitor
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("網路").font(.caption).foregroundStyle(monitor.accentColor).bold()
                        Text(monitor.wifiInfo?.ssid ?? (monitor.networkInterfaceName == "en0" ? "Wi‑Fi" : monitor.networkInterfaceName))
                            .lineLimit(1)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(monitor.networkDetailStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showDetails.toggle() } label: {
                        Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 34, height: 28).background(Color.secondary.opacity(0.08)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    .popover(isPresented: $showDetails, arrowEdge: .top) {
                        NetworkDetailsPopover(monitor: monitor)
                    }
                }

                NetworkLiveRow(title: "上傳", arrow: "arrow.up", speed: monitor.upSpeedStr, total: monitor.totalUpStr, average: monitor.avgUpStr, history: monitor.trafficHistory, upload: true, color: .pink)
                Divider()
                NetworkLiveRow(title: "下載", arrow: "arrow.down", speed: monitor.downSpeedStr, total: monitor.totalDownStr, average: monitor.avgDownStr, history: monitor.trafficHistory, upload: false, color: .green)

                if monitor.popNetShowTotals {
                    Divider()
                    Text("今日數據用量").font(.headline).foregroundStyle(monitor.accentColor)
                    HStack(alignment: .top, spacing: 16) {
                        HourlyUsageColumn(title: "上載", bytes: monitor.hourlyTraffic.upload, color: .pink, monitor: monitor)
                        HourlyUsageColumn(title: "下載", bytes: monitor.hourlyTraffic.download, color: .green, monitor: monitor)
                    }
                }

                if monitor.popNetShowActive {
                    WidgetCard {
                        Label("正在使用網路", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline.bold())
                        // 固定保留 3 列的高度，清單增減時下方內容不會跳動。
                        VStack(alignment: .leading, spacing: 8) {
                            ActiveNetworkAppsList(monitor: monitor, maxRows: 3, iconSize: 22, speedWidth: 68)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    }
                }

                if monitor.popNetShowAppUsage { CompactAppUsageList(monitor: monitor) }

                if monitor.popNetShowDisk {
                    WidgetCard {
                        Text("Macintosh HD").font(.caption).foregroundStyle(monitor.accentColor).bold()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.0f", monitor.diskUsagePct)).font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("%").font(.title3.bold()).foregroundStyle(.secondary)
                        }
                        Text("\(monitor.diskFreeStr) 可用（共 \(monitor.diskTotalStr)）").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: monitor.diskUsagePct, total: 100).tint(.cyan)
                    }
                }

                if monitor.popNetShowBarToggles {
                    WidgetCard {
                        Text("狀態列顯示")
                            .font(.caption)
                            .foregroundStyle(monitor.accentColor)
                            .bold()
                        HStack(spacing: 18) {
                            Toggle("流量圖表", isOn: $monitor.showNetChart)
                            Toggle("即時速度", isOn: $monitor.showNetSpeed)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.cyan)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                HStack {
                    Button("結束程式") { NSApplication.shared.terminate(nil) }.controlSize(.small)
                    Spacer()
                    Text("啟用").font(.caption).foregroundStyle(.secondary)
                    Toggle("", isOn: $monitor.showNetModule).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Button {
                        monitor.mainWindowTab = "settings"
                        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
                    } label: { Image(systemName: "gearshape.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }.padding(16)
        }.popoverBackground(glass: monitor.glassStyle)
        .environment(\.glassStyle, monitor.glassStyle)
        .tint(monitor.accentColor)
    }
}

private struct CompactAppUsageList: View {
    @Bindable var monitor: SystemMonitor

    private var items: [AppDataUsageItem] {
        Array(monitor.appDataUsageItems(days: 1).prefix(5))
    }

    var body: some View {
        WidgetCard {
            HStack {
                Label("今日 App 用量", systemImage: "app.badge")
                    .font(.subheadline.bold())
                Spacer()
                Text(monitor.formatBytesForUI(monitor.appDataUsageTotal(days: 1)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(monitor.appNetworkStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 9) {
                        AppIconView(pid: item.pid, name: item.name, bundlePath: item.bundlePath, size: 26)
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(monitor.formatBytesForUI(item.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// 今天 0～24 時每小時用量的長條圖，下方是今日總量；還沒有用量的小時以淺灰短條佔位。
private struct HourlyUsageColumn: View {
    let title: String
    let bytes: [UInt64]
    let color: Color
    let monitor: SystemMonitor

    var body: some View {
        let peak = Double(max(bytes.max() ?? 0, 1))
        VStack(alignment: .leading, spacing: 3) {
            Chart {
                ForEach(Array(bytes.enumerated()), id: \.offset) { hour, value in
                    // 用量再小也保留一點高度，才看得出該小時有流量。
                    let height = value > 0 ? max(Double(value) / peak, 0.08) : 0.12
                    RectangleMark(xStart: .value("起", Double(hour) + 0.14), xEnd: .value("迄", Double(hour) + 0.86), yStart: .value(title, 0), yEnd: .value(title, height))
                        .foregroundStyle(value > 0 ? AnyShapeStyle(color) : AnyShapeStyle(Color.secondary.opacity(0.18)))
                        .cornerRadius(1.5)
                }
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: 0...1)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [0, 12, 24]) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : (value.index == 2 ? .topTrailing : .top)) {
                        if let hour = value.as(Int.self) { Text("\(hour)H").font(.caption2) }
                    }
                }
            }
            .frame(height: 58)
            Text(title).font(.caption).foregroundStyle(color)
            Text(monitor.formatBytesForUI(bytes.reduce(0, +))).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NetworkLiveRow: View {
    let title: String; let arrow: String; let speed: String; let total: String; let average: String; let history: [TrafficData]; let upload: Bool; let color: Color
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(speed.replacingOccurrences(of: "/s", with: "")).font(.system(size: 29, weight: .bold, design: .rounded)).monospacedDigit()
                Label("\(total) • 平均 \(average)", systemImage: arrow).font(.caption).bold().monospacedDigit().lineLimit(1)
            }
            Spacer()
            Chart {
                ForEach(history) { d in
                    LineMark(x: .value("t", d.time), y: .value(title, upload ? d.uploadSpeed : d.downloadSpeed)).foregroundStyle(color)
                    AreaMark(x: .value("t", d.time), y: .value(title, upload ? d.uploadSpeed : d.downloadSpeed)).foregroundStyle(LinearGradient(colors: [color.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                }
            }.chartXAxis(.hidden).chartYAxis(.hidden).frame(width: 130, height: 50)
        }
    }
}

struct NetworkDetailsPopover: View {
    @Bindable var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { monitor.refreshNetworkDetails() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.plain)
            Divider()
            NetworkDetailLine(title: "介面", value: monitor.networkInterfaceName)
            NetworkDetailLine(title: "本機 IP", value: monitor.networkLocalIP, copyable: true)
            NetworkDetailLine(title: "公網 IP", value: monitor.networkPublicIP, copyable: true)
            NetworkDetailLine(title: "預設閘道", value: monitor.networkGateway)
            NetworkDetailLine(title: "DNS", value: monitor.networkDNS)
            if let wifi = monitor.wifiInfo {
                Divider()
                HStack {
                    Text("Wi‑Fi 詳情").font(.caption).foregroundStyle(monitor.accentColor).bold()
                    Spacer()
                    if wifi.ssid == nil { WiFiNameAccessButton(monitor: monitor) }
                }
                if let ssid = wifi.ssid { NetworkDetailLine(title: "無線網路", value: ssid) }
                NetworkDetailLine(title: "頻道", value: wifi.channel)
                NetworkDetailLine(title: "訊號強度", value: wifi.rssiText)
                NetworkDetailLine(title: "傳輸率", value: wifi.transmitRateText)
                NetworkDetailLine(title: "安全性", value: wifi.security)
                NetworkDetailLine(title: "MAC 位址", value: wifi.macAddress, copyable: true)
            }
        }.padding(16).frame(width: 290)
    }
}

struct NetworkDetailLine: View {
    let title: String; let value: String; var copyable = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.body).textSelection(.enabled) }
            Spacer(minLength: 8)
            if copyable { CopyButton(value: value) }
        }
    }
}
