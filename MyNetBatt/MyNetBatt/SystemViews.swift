import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 系統效能視窗
struct SystemDetailView: View {
    @Bindable var monitor: SystemMonitor

    private var memoryPressureLabel: String {
        switch monitor.memoryPressureLevel {
        case 4: return String(localized: "嚴重")
        case 2: return String(localized: "警告")
        default: return String(localized: "正常")
        }
    }

    private var memoryPressureColor: Color {
        switch monitor.memoryPressureLevel {
        case 4: return .red
        case 2: return .yellow
        default: return .blue
        }
    }

    var body: some View {
        PageScroll {
                PageHeader(title: "系統效能", subtitle: monitor.cpuModelStr, symbol: MainTab.system.symbol, color: MainTab.system.color)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    SystemCard(
                        icon: "speedometer",
                        title: String(localized: "CPU 負載"),
                        value: String(format: "%.1f %%", monitor.currentCpuUsage),
                        progress: monitor.currentCpuUsage,
                        color: .purple
                    )
                    SystemCard(
                        icon: "gauge.with.dots.needle.67percent",
                        title: String(localized: "GPU 負載"),
                        value: String(format: "%.1f %%", monitor.currentGpuUsage),
                        progress: monitor.currentGpuUsage,
                        color: .green
                    )
                    SystemCard(
                        icon: "memorychip.fill",
                        title: String(localized: "實體記憶體"),
                        value: monitor.ramUsageStr,
                        detail: String(localized: "記憶體壓力 \(Int(monitor.memoryPressurePct.rounded()))% · \(memoryPressureLabel)"),
                        progress: monitor.ramUsagePct,
                        color: memoryPressureColor
                    )
                    SystemCard(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: String(localized: "Swap 虛擬記憶體"),
                        value: monitor.swapUsageStr,
                        detail: String(localized: "已使用 \(Int(monitor.swapUsagePct.rounded()))%"),
                        progress: monitor.swapUsagePct,
                        color: .orange
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    Panel(title: "CPU 即時負載", symbol: "waveform.path.ecg", color: .purple) {
                        Chart {
                            ForEach(monitor.cpuHistory) { data in
                                LineMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                                    .foregroundStyle(.purple)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.monotone)
                                AreaMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(
                                        LinearGradient(
                                            gradient: Gradient(colors: [.purple.opacity(0.35), .clear]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                        }
                        .frame(minHeight: 120)
                        .chartYScale(domain: 0...100)
                        .chartXAxis(.hidden)

                    }
                    Panel(title: "GPU 即時負載", symbol: "waveform.path.ecg", color: .green) {
                        Chart {
                            ForEach(monitor.gpuHistory) { data in
                                LineMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                                    .foregroundStyle(.green)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.monotone)
                                AreaMark(x: .value("時間", data.time), y: .value("使用率", data.value))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(
                                        LinearGradient(
                                            gradient: Gradient(colors: [.green.opacity(0.30), .clear]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                        }
                        .frame(minHeight: 120)
                        .chartYScale(domain: 0...100)
                        .chartXAxis(.hidden)
                    }
                }

                VStack(spacing: 12) {
                    SystemInfoRow(icon: "macbook", color: .gray, title: String(localized: "Mac 型號"), value: monitor.macModelStr)
                    SystemInfoRow(icon: "cpu", color: .purple, title: String(localized: "處理器 (CPU)"), value: monitor.cpuModelStr)
                    SystemInfoRow(icon: "memorychip", color: .orange, title: String(localized: "顯示卡 (GPU)"), value: monitor.gpuModelStr)
                }
                .padding(Metrics.panelPadding)
                .cardSurface(cornerRadius: Metrics.panelRadius)

        }
    }
}

/// 透過 Thunderbolt／USB‑C 連接的設備（名稱、廠商、UID、韌體）。
struct ThunderboltDevicesCard: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                IconChip(symbol: "bolt.horizontal.fill", color: .blue, size: 24)
                Text("Thunderbolt / USB4 設備")
                    .font(.headline)
                Spacer()
                Text(monitor.thunderboltStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monitor.thunderboltDevices.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(.secondary)
                    Text("沒有設備接入")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(monitor.thunderboltDevices) { device in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).bold()
                            Text("\(device.connection) · \(device.vendor)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                if !device.uid.isEmpty { Text("UID: \(device.uid)") }
                                if !device.firmware.isEmpty { Text("韌體: \(device.firmware)") }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(Metrics.panelPadding)
        .cardSurface(cornerRadius: Metrics.panelRadius)
    }
}

/// 每個內建連接埠接了什麼裝置，以及線材 e‑marker 回報的速度與額定功率。
struct PortsCard: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        let connected = monitor.portInfos.filter(\.isConnected).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                IconChip(symbol: "cable.connector", color: .gray, size: 24)
                Text("連接埠與線材").font(.headline)
                Spacer()
                Text(connected == 0 ? "沒有連接埠在使用" : "\(connected) 個連接埠使用中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let ports = monitor.portsHideIdle ? monitor.portInfos.filter(\.isConnected) : monitor.portInfos
            if monitor.portInfos.isEmpty {
                Text("這台 Mac 沒有回報連接埠資訊").foregroundStyle(.secondary).padding(.vertical, 6)
            } else if ports.isEmpty {
                Text("目前沒有連接埠在使用（已隱藏未使用的連接埠）").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(ports) { port in
                    PortRow(port: port, showsTech: monitor.portsShowTechDetails)
                        .padding(.vertical, 4)
                    if port.id != ports.last?.id { Divider() }
                }
            }
        }
        .padding(Metrics.panelPadding)
        .cardSurface(cornerRadius: Metrics.panelRadius)
        .onAppear { monitor.fetchPortInfo() }
    }
}

/// 一個連接埠：接了什麼、正在傳什麼、誰在限速，以及線材與顯示器的細節。
struct PortRow: View {
    let port: PortInfo
    /// 顯示支援的傳輸方式、插拔次數等技術細節。
    var showsTech = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: port.isMagSafe ? "magsafe.batterypack" : (port.id.hasPrefix("HDMI@") ? "tv" : "cable.connector"))
                .foregroundStyle(port.isConnected ? Color.blue : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                // 窄的地方（選單列小視窗）標籤整顆換到下一行，不在字中間斷開。
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    Text(port.name).bold().lineLimit(1).fixedSize()
                    if port.isConnected {
                        ForEach(port.transportNames, id: \.self) { name in
                            Text(name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                }
                if port.isConnected {
                    Text(port.partner.isEmpty ? "已連接" : "已連接：\(port.partner)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let verdict = port.verdict { verdictView(verdict) }
                    if let link = port.link {
                        let total = LinkRate.gbps(link.total)
                        FlowLayout(spacing: 4, lineSpacing: 2) {
                            Text("實際連線 \(link.laneText)（\(total) Gbps）").fixedSize()
                            if let max = port.macMaxGbps {
                                Text("· 連接埠最高 \(LinkRate.gbps(max)) Gbps").fixedSize()
                            }
                        }
                        .font(.caption).monospacedDigit()
                    }
                    if let cable = port.cable {
                        FlowLayout(spacing: 4, lineSpacing: 2) {
                            Text("\(cable.kindText)線材 · \(cable.speed)").fixedSize()
                            Text("· 額定 \(cable.ratingText)").fixedSize()
                        }
                        .font(.caption).monospacedDigit()
                        if !cable.vendor.isEmpty {
                            Text("線材製造商：\(cable.vendor)").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if !port.isMagSafe && !port.id.hasPrefix("HDMI@") {
                        Text("線材沒有 e‑marker 晶片或目前讀不到（基本線材最高 3 A／60 W）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(port.displays) { display in
                        let rate = display.lanes > 0 ? "\(display.rate) × \(display.lanes)" : display.rate
                        Label {
                            Text(verbatim: "\(display.name) · \(rate)")
                        } icon: {
                            Image(systemName: "display")
                        }
                        .font(.caption).monospacedDigit()
                        if let diagnosis = display.diagnosis { displayDiagnosisView(diagnosis) }
                    }
                } else {
                    Text("未連接").font(.caption).foregroundStyle(.secondary)
                }
                if showsTech, let tech = port.tech { techView(tech) }
            }
            Spacer()
        }
    }

    private func techView(_ tech: PortTech) -> some View {
        let yes = String(localized: "是"), no = String(localized: "否")
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if !tech.supported.isEmpty {
                GridRow { Text("支援的傳輸方式").foregroundStyle(.secondary); Text(tech.supported.formatted(.list(type: .and))) }
            }
            if !port.transportNames.isEmpty {
                GridRow { Text("作用中").foregroundStyle(.secondary); Text(port.transportNames.formatted(.list(type: .and))) }
            }
            if let plug = tech.plugEvents {
                GridRow { Text("插拔次數").foregroundStyle(.secondary); Text("\(plug)") }
            }
            if let count = tech.connections {
                GridRow { Text("連線次數").foregroundStyle(.secondary); Text("\(count)") }
            }
            if let over = tech.overcurrent {
                GridRow { Text("過電流次數").foregroundStyle(.secondary); Text("\(over)").foregroundStyle(over > 0 ? Color.orange : Color.primary) }
            }
            if port.isConnected, let active = tech.activeCable {
                GridRow { Text("主動式線材電子元件").foregroundStyle(.secondary); Text(active ? yes : no) }
            }
            if port.isConnected, let optical = tech.opticalCable {
                GridRow { Text("光纖線材").foregroundStyle(.secondary); Text(optical ? yes : no) }
            }
            if port.isConnected, let id = tech.cableID {
                GridRow { Text("線材識別碼").foregroundStyle(.secondary); Text(verbatim: id).textSelection(.enabled) }
            }
            if port.isConnected, let power = port.power, let contract = power.contract {
                GridRow {
                    Text("供電檔位").foregroundStyle(.secondary).gridCellAnchor(.topLeading)
                    Text(verbatim: power.pdos.map { "\($0.voltageText)  \($0.limitText)" }.joined(separator: "\n"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow { Text("目前協商").foregroundStyle(.secondary); Text(contract.text) }
            }
            if let health = port.power?.health {
                GridRow {
                    Text("PD 硬體重設").foregroundStyle(.secondary)
                    Text("\(health.hardResets)").foregroundStyle(health.hardResets > 0 ? Color.orange : Color.primary)
                }
                GridRow {
                    Text("短路偵測").foregroundStyle(.secondary)
                    Text("\(health.shortDetects)").foregroundStyle(health.shortDetects > 0 ? Color.orange : Color.primary)
                }
                GridRow { Text("控制器通訊錯誤").foregroundStyle(.secondary); Text("\(health.commErrors)") }
                GridRow { Text("角色切換失敗").foregroundStyle(.secondary); Text("\(health.roleSwapFailures)") }
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 螢幕模式診斷：一行結論＋說明；打開技術細節時加上頻寬數字。
    private func displayDiagnosisView(_ diagnosis: DisplayDiagnosis) -> some View {
        let (symbol, color): (String, Color) = switch diagnosis.level {
        case .good: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .blue)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnosis.title).font(.caption.weight(.semibold))
                Text(diagnosis.detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsTech, let need = diagnosis.requiredGbps, let have = diagnosis.availableGbps {
                    let needText = String(format: "%.1f", need), haveText = String(format: "%.1f", have)
                    Text("最佳模式約需 \(needText) Gbps · 連線可用約 \(haveText) Gbps（8 bit 色彩、未壓縮）")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 22)
    }

    private func verdictView(_ verdict: PortVerdict) -> some View {
        let (symbol, color): (String, Color) = switch verdict.level {
        case .good: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .blue)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        }
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.title).font(.callout.weight(.semibold))
                Text(verdict.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SystemCard: View {
    let icon: String
    let title: String
    let value: String
    var detail: String? = nil
    let progress: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).frame(width: 22)
                Text(title).font(.headline)
                Spacer()
            }

            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .bold()
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            MeterBar(value: progress, color: color)
        }
        .padding(16)
        .cardSurface(cornerRadius: 12, fill: 0.1)
    }
}

struct StorageVolumesCard: View {
    @Bindable var monitor: SystemMonitor
    @State private var ejectingID: String?
    @State private var ejectError: String?
    @State private var ejectingAll = false

    private var ejectableCount: Int { monitor.storageVolumes.filter(\.isEjectable).count }

    private func ejectAll() {
        ejectingAll = true
        Task {
            let failures = await monitor.ejectAllVolumes()
            ejectingAll = false
            if !failures.isEmpty {
                ejectError = failures.map { String(localized: "\($0.name)：\($0.message)") }.joined(separator: "\n")
            }
        }
    }

    private func eject(_ volume: StorageVolumeInfo) {
        ejectingID = volume.id
        Task {
            ejectError = await monitor.ejectVolume(volume)
            ejectingID = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                IconChip(symbol: "internaldrive.fill", color: .indigo, size: 24)
                Text("磁碟")
                    .font(.headline)
                Spacer()
                Text(monitor.storageVolumes.count > 1 ? "\(monitor.storageVolumes.count) 個磁碟區" : "Macintosh HD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 內建磁碟不能退出；只有一顆外接磁碟時用該列的退出按鈕即可，避免看起來像會連內建磁碟一起退出。
                if ejectableCount > 1 {
                    if ejectingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            ejectAll()
                        } label: {
                            Label("全部退出", systemImage: "eject")
                        }
                        .controlSize(.small)
                        .help("退出所有外接磁碟")
                    }
                }
            }

            if monitor.storageVolumes.isEmpty {
                StorageVolumeRow(
                    name: "Macintosh HD",
                    used: monitor.diskUsedStr,
                    free: monitor.diskFreeStr,
                    total: monitor.diskTotalStr,
                    pct: monitor.diskUsagePct,
                    subtitle: "/"
                )
            } else {
                ForEach(monitor.storageVolumes) { volume in
                    StorageVolumeRow(
                        name: volume.name,
                        used: monitor.formatStorageBytesForUI(volume.usedBytes),
                        free: monitor.formatStorageBytesForUI(volume.availableBytes),
                        total: monitor.formatStorageBytesForUI(volume.totalBytes),
                        pct: volume.usagePct,
                        subtitle: volume.isInternal ? String(localized: "內建磁碟") : volume.mountPath,
                        isEjecting: ejectingID == volume.id,
                        onEject: volume.isEjectable ? { eject(volume) } : nil
                    )
                    if volume.id != monitor.storageVolumes.last?.id { Divider() }
                }
            }
        }
        .padding(Metrics.panelPadding)
        .cardSurface(cornerRadius: Metrics.panelRadius)
        .alert("無法退出磁碟", isPresented: Binding(get: { ejectError != nil }, set: { if !$0 { ejectError = nil } })) {
            Button("好") { ejectError = nil }
        } message: {
            Text(ejectError ?? "")
        }
    }
}

struct StorageVolumeRow: View {
    let name: String
    let used: String
    let free: String
    let total: String
    let pct: Double
    let subtitle: String
    var isEjecting = false
    var onEject: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(String(format: "%.1f", pct))% 已使用")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let onEject {
                    if isEjecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: onEject) { Image(systemName: "eject.fill") }
                            .buttonStyle(.borderless)
                            .help("退出「\(name)」")
                            .accessibilityLabel("退出 \(name)")
                    }
                }
            }
            Text("已用 \(used) / 共 \(total)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("可用 \(free)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            MeterBar(value: pct, color: .cyan)
        }
    }
}

struct SystemInfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Text(title).foregroundStyle(.secondary).font(.headline)
            Spacer()
            Text(value).bold().font(.headline)
        }
    }
}

/// 由左到右排列，排不下就換行；每個子元件保持完整、不會在中間斷開。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [index], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
