import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 網路子視窗 (Popover)
struct NetworkPopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("網路").font(.caption).foregroundStyle(.blue).bold()
                        Text(monitor.networkInterfaceName == "en0" ? "Wi‑Fi" : monitor.networkInterfaceName)
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

                NetworkLiveRow(title: "上傳", arrow: "arrow.up", speed: monitor.upSpeedStr, total: monitor.totalUpStr, history: monitor.trafficHistory, upload: true, color: .pink)
                Divider()
                NetworkLiveRow(title: "下載", arrow: "arrow.down", speed: monitor.downSpeedStr, total: monitor.totalDownStr, history: monitor.trafficHistory, upload: false, color: .green)

                Divider()
                Text("數據用量").font(.headline).foregroundStyle(.blue)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("上載").font(.caption).foregroundStyle(.pink)
                        Text(monitor.totalUpStr).font(.title2.bold()).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("下載").font(.caption).foregroundStyle(.green)
                        Text(monitor.totalDownStr).font(.title2.bold()).monospacedDigit()
                    }
                    Spacer()
                }

                WidgetCard {
                    Text("Macintosh HD").font(.caption).foregroundStyle(.blue).bold()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", monitor.diskUsagePct)).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("%").font(.title3.bold()).foregroundStyle(.secondary)
                    }
                    Text("\(monitor.diskFreeStr) 可用（共 \(monitor.diskTotalStr)）").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: monitor.diskUsagePct, total: 100).tint(.cyan)
                }

                Divider()
                HStack {
                    Button("結束程式") { NSApplication.shared.terminate(nil) }.controlSize(.small)
                    Spacer()
                    Text("啟用").font(.caption).foregroundStyle(.secondary)
                    Toggle("", isOn: $monitor.showNetModule).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Button { NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil) } label: { Image(systemName: "gearshape.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }.padding(16)
        }.background(Color(NSColor.windowBackgroundColor))
    }
}

struct NetworkLiveRow: View {
    let title: String; let arrow: String; let speed: String; let total: String; let history: [TrafficData]; let upload: Bool; let color: Color
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(speed.replacingOccurrences(of: "/s", with: "")).font(.system(size: 29, weight: .bold, design: .rounded)).monospacedDigit()
                Label("\(total)", systemImage: arrow).font(.caption).bold()
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
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { monitor.refreshNetworkDetails() } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(.plain)
            Divider()
            NetworkDetailLine(title: "介面", value: monitor.networkInterfaceName)
            NetworkDetailLine(title: "本機 IP", value: monitor.networkLocalIP)
            NetworkDetailLine(title: "公網 IP", value: monitor.networkPublicIP)
            NetworkDetailLine(title: "預設閘道", value: monitor.networkGateway)
            NetworkDetailLine(title: "DNS", value: monitor.networkDNS)
        }.padding(16).frame(width: 290)
    }
}

struct NetworkDetailLine: View {
    let title: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.body).textSelection(.enabled) }
    }
}
