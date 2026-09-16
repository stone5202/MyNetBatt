import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 網路詳細視窗
struct NetworkDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var usageDays = 1
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("網路流量監控").font(.largeTitle.bold())

                NetworkConnectionInfoCard(monitor: monitor)

                HStack(spacing: 16) {
                    NetworkSpeedCard(title: "上傳", symbol: "arrow.up", value: monitor.upSpeedStr, total: monitor.totalUpStr, history: monitor.trafficHistory, upload: true, color: .pink)
                    NetworkSpeedCard(title: "下載", symbol: "arrow.down", value: monitor.downSpeedStr, total: monitor.totalDownStr, history: monitor.trafficHistory, upload: false, color: .green)
                }

                AppDataUsagePanel(monitor: monitor, usageDays: $usageDays, maxRows: 50)

                Divider()
                HStack(spacing: 20) {
                    Toggle("啟用網路模組", isOn: $monitor.showNetModule)
                    Toggle("狀態列圖表", isOn: $monitor.showNetChart)
                    Toggle("狀態列數字", isOn: $monitor.showNetSpeed)
                    Spacer()
                }
                .toggleStyle(.switch).tint(.cyan)
            }
            .padding(24)
        }
    }
}

struct NetworkConnectionInfoCard: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("目前網路", systemImage: "wifi").font(.headline)
                Spacer()
                Text(monitor.networkDetailStatus).font(.caption).foregroundStyle(.secondary)
                Button { monitor.refreshNetworkDetails() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                NetworkInfoPair(title: "介面", value: monitor.networkInterfaceName)
                NetworkInfoPair(title: "本機 IP", value: monitor.networkLocalIP)
                NetworkInfoPair(title: "預設閘道", value: monitor.networkGateway)
                NetworkInfoPair(title: "公網 IP", value: monitor.networkPublicIP)
                NetworkInfoPair(title: "DNS", value: monitor.networkDNS)
            }
        }
        .padding(16).background(Color.secondary.opacity(0.08)).cornerRadius(14)
    }
}

struct NetworkInfoPair: View {
    let title: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).textSelection(.enabled).lineLimit(2)
        }
    }
}

struct NetworkSpeedCard: View {
    let title: String; let symbol: String; let value: String; let total: String; let history: [TrafficData]; let upload: Bool; let color: Color
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(color)
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Label("累計 \(total)", systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Chart {
                ForEach(history) { item in
                    LineMark(
                        x: .value("時間", item.time),
                        y: .value(title, upload ? item.uploadSpeed : item.downloadSpeed)
                    )
                    .foregroundStyle(color)
                    AreaMark(
                        x: .value("時間", item.time),
                        y: .value(title, upload ? item.uploadSpeed : item.downloadSpeed)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 150, height: 58)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 122, maxHeight: 122)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }
}

struct AppDataUsagePanel: View {
    @ObservedObject var monitor: SystemMonitor
    @Binding var usageDays: Int
    let maxRows: Int
    @State private var showsAllApps = false
    private let collapsedCount = 5
    var allItems: [AppDataUsageItem] { Array(monitor.appDataUsageItems(days: usageDays).prefix(maxRows)) }
    var items: [AppDataUsageItem] { showsAllApps ? allItems : Array(allItems.prefix(collapsedCount)) }
    var total: UInt64 { monitor.appDataUsageTotal(days: usageDays) }
    var maxBytes: UInt64 { max(allItems.first?.bytes ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("數據用量").font(.title2.bold())
                Spacer()
                Picker("期間", selection: $usageDays) { Text("日").tag(1); Text("週").tag(7) }
                    .pickerStyle(.segmented).frame(width: 180)
            }
            Text(monitor.appNetworkStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(usageDays == 1 ? "今日總共" : "近 7 日總共").font(.caption).foregroundStyle(.blue).bold()
                Text(monitor.formatBytesForUI(total)).font(.system(size: 34, weight: .bold, design: .rounded))
            }
            if items.isEmpty {
                Text("尚未累積到 App 網路用量；程式執行後會自動記錄。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                Text("\(allItems.count) 個 App / 程序").font(.headline)
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            AppIconView(pid: item.pid, name: item.name)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    Text(monitor.formatBytesForUI(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Color.secondary.opacity(0.15)).overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor).frame(width: geo.size.width * CGFloat(Double(item.bytes) / Double(maxBytes)))
                                    }
                                }.frame(height: 6)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 9)
                        Divider()
                    }

                    if allItems.count > collapsedCount {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsAllApps.toggle()
                            }
                        } label: {
                            Label(
                                showsAllApps ? "收合" : "顯示更多（\(allItems.count - collapsedCount)）",
                                systemImage: showsAllApps ? "chevron.up" : "chevron.down"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
        .onChange(of: usageDays) { _, _ in showsAllApps = false }
    }
}

struct AppIconView: View {
    let pid: Int?
    let name: String
    var size: CGFloat = 38

    var icon: NSImage? {
        let workspace = NSWorkspace.shared

        if let pid,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let icon = app.icon { return icon }
            if let url = app.bundleURL ?? app.executableURL {
                return workspace.icon(forFile: url.path)
            }
        }

        let normalizedName = name
            .replacingOccurrences(of: #"\s+Helper$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let app = workspace.runningApplications.first(where: { candidate in
            let localizedName = candidate.localizedName?.lowercased()
            let executableName = candidate.executableURL?.deletingPathExtension().lastPathComponent.lowercased()
            let bundleID = candidate.bundleIdentifier?.lowercased()
            return localizedName == normalizedName
                || executableName == normalizedName
                || bundleID == normalizedName
                || bundleID?.hasSuffix(".\(normalizedName)") == true
        }) {
            if let icon = app.icon { return icon }
            if let url = app.bundleURL ?? app.executableURL {
                return workspace.icon(forFile: url.path)
            }
        }

        if name.contains("."),
           let appURL = workspace.urlForApplication(withBundleIdentifier: name) {
            return workspace.icon(forFile: appURL.path)
        }

        return nil
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.06)
            } else {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(size * 0.24)
    }
}
