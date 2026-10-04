import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 網路詳細視窗
struct NetworkDetailView: View {
    @Bindable var monitor: SystemMonitor
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

                // 這份清單的列數每 2 秒都可能改變，放在用量面板之後，才不會把面板上下推動。
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在使用網路的 App").font(.title2.bold())
                    ActiveNetworkAppsList(monitor: monitor)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(14)

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
        .onAppear { monitor.setPerAppUsageVisible(true, source: "mainWindow") }
        .onDisappear { monitor.setPerAppUsageVisible(false, source: "mainWindow") }
    }
}

struct NetworkConnectionInfoCard: View {
    @Bindable var monitor: SystemMonitor
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
                NetworkInfoPair(title: "本機 IP", value: monitor.networkLocalIP, copyable: true)
                NetworkInfoPair(title: "預設閘道", value: monitor.networkGateway)
                NetworkInfoPair(title: "公網 IP", value: monitor.networkPublicIP, copyable: true)
                NetworkInfoPair(title: "DNS", value: monitor.networkDNS)
            }
            if let wifi = monitor.wifiInfo {
                Divider()
                HStack {
                    Text("Wi‑Fi 詳情").font(.subheadline.bold())
                    Spacer()
                    if wifi.ssid == nil { WiFiNameAccessButton(monitor: monitor) }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                    NetworkInfoPair(title: "無線網路", value: wifi.ssid ?? "--")
                    NetworkInfoPair(title: "頻道", value: wifi.channel)
                    NetworkInfoPair(title: "訊號強度", value: wifi.rssiText)
                    NetworkInfoPair(title: "傳輸率", value: wifi.transmitRateText)
                    NetworkInfoPair(title: "安全性", value: wifi.security)
                    NetworkInfoPair(title: "MAC 位址", value: wifi.macAddress, copyable: true)
                }
            }
        }
        .padding(16).background(Color.secondary.opacity(0.08)).cornerRadius(14)
    }
}

struct NetworkInfoPair: View {
    let title: String; let value: String; var copyable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value).font(.system(.body, design: .rounded).weight(.semibold)).textSelection(.enabled).lineLimit(2)
                if copyable { CopyButton(value: value) }
            }
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
    @Bindable var monitor: SystemMonitor
    @Binding var usageDays: Int
    let maxRows: Int
    @State private var showsAllApps = false
    private let collapsedCount = 5
    var periodTitle: String {
        switch usageDays {
        case 1: return "今日總共"
        case 7: return "近 7 日總共"
        case 30: return "近 30 日總共"
        default: return "近 12 個月總共"
        }
    }

    var body: some View {
        // 每次重算只彙整一次，再由同一份結果導出總計與清單。
        let everything = monitor.appDataUsageItems(days: usageDays)
        let allItems = Array(everything.prefix(maxRows))
        let items = showsAllApps ? allItems : Array(allItems.prefix(collapsedCount))
        let total = everything.reduce(UInt64(0)) { $0 + $1.bytes }
        let upload = everything.reduce(UInt64(0)) { $0 + $1.upload }
        let download = everything.reduce(UInt64(0)) { $0 + $1.download }
        let unknown = total > upload + download ? total - upload - download : 0
        let maxBytes = max(allItems.first?.bytes ?? 1, 1)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("數據用量").font(.title2.bold())
                Spacer()
                Picker("期間", selection: $usageDays) { Text("日").tag(1); Text("週").tag(7); Text("月").tag(30); Text("年").tag(365) }
                    .pickerStyle(.segmented).frame(width: 240)
            }
            Text(monitor.appNetworkStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(periodTitle).font(.caption).foregroundStyle(monitor.accentColor).bold()
                Text(monitor.formatBytesForUI(total)).font(.system(size: 34, weight: .bold, design: .rounded))
                if upload + download > 0 {
                    HStack(spacing: 14) {
                        Label(monitor.formatBytesForUI(upload), systemImage: "arrow.up").foregroundStyle(.pink)
                        Label(monitor.formatBytesForUI(download), systemImage: "arrow.down").foregroundStyle(.green)
                        if unknown > 0 {
                            Text("未分類 \(monitor.formatBytesForUI(unknown))")
                                .foregroundStyle(.secondary)
                                .help("加入上傳／下載分開統計之前的紀錄，只有合計")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                }
            }
            if usageDays > 1 {
                UsageHistoryChart(monitor: monitor, days: usageDays)
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
                                    if item.upload + item.download > 0 {
                                        Text("↑ \(monitor.formatBytesForUI(item.upload))  ↓ \(monitor.formatBytesForUI(item.download))")
                                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                    Text(monitor.formatBytesForUI(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Color.secondary.opacity(0.15)).overlay(alignment: .leading) {
                                        Capsule().fill(monitor.accentColor).frame(width: geo.size.width * CGFloat(Double(item.bytes) / Double(maxBytes)))
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
                        .foregroundStyle(monitor.accentColor)
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

/// 週、月為每日一根長條，年為每月一根；依下載、上傳、未分類堆疊。
struct UsageHistoryChart: View {
    @Bindable var monitor: SystemMonitor
    let days: Int

    var body: some View {
        let points = monitor.usageBarPoints(days: days)
        let hasUnknown = points.contains { $0.kind == "未分類" }
        let unit: Calendar.Component = days > 31 ? .month : .day
        Chart(points) { point in
            BarMark(x: .value("日期", point.date, unit: unit), y: .value("用量", point.bytes))
                .foregroundStyle(by: .value("類型", point.kind))
        }
        .chartForegroundStyleScale(
            domain: hasUnknown ? ["下載", "上傳", "未分類"] : ["下載", "上傳"],
            range: hasUnknown ? [Color.green, Color.pink, Color.gray.opacity(0.5)] : [Color.green, Color.pink]
        )
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) { Text(monitor.formatBytesForUI(UInt64(max(0, bytes)))) }
                }
            }
        }
        .frame(height: 150)
    }
}

/// 目前有流量的 App 與各自的即時網速（由 nettop 取樣，畫面開著時每 2 秒更新）。
struct ActiveNetworkAppsList: View {
    @Bindable var monitor: SystemMonitor
    var maxRows = 8
    var iconSize: CGFloat = 30

    var body: some View {
        let apps = Array(monitor.appNetworkUsages.filter(\.isActive).prefix(maxRows))
        if apps.isEmpty {
            Text("目前沒有 App 正在使用網路")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        } else {
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    AppIconView(pid: app.pid, name: app.name, size: iconSize)
                    Text(app.name).font(iconSize < 30 ? .caption : .body).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("↑ \(monitor.formatSpeedForUI(app.uploadSpeed))")
                        .foregroundStyle(.pink)
                        .frame(width: 92, alignment: .trailing)
                    Text("↓ \(monitor.formatSpeedForUI(app.downloadSpeed))")
                        .foregroundStyle(.green)
                        .frame(width: 92, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
            }
        }
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
