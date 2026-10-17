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

                PortsCard(monitor: monitor)
        }
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

            if monitor.portInfos.isEmpty {
                Text("這台 Mac 沒有回報連接埠資訊").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(monitor.portInfos) { port in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: port.isMagSafe ? "magsafe.batterypack" : "cable.connector")
                            .foregroundStyle(port.isConnected ? Color.blue : Color.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(port.name).bold()
                            if port.isConnected {
                                Text(port.partner.isEmpty ? "已連接" : "已連接：\(port.partner)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let cable = port.cable {
                                    Text("\(cable.kindText)線材 · \(cable.speed) · 額定 \(cable.ratingText)")
                                        .font(.caption).monospacedDigit()
                                    if !cable.vendor.isEmpty {
                                        Text("線材製造商：\(cable.vendor)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                } else if !port.isMagSafe {
                                    Text("線材沒有 e‑marker 晶片或目前讀不到（基本線材最高 3 A／60 W）")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("未連接").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    if port.id != monitor.portInfos.last?.id { Divider() }
                }
            }
        }
        .padding(Metrics.panelPadding)
        .cardSurface(cornerRadius: Metrics.panelRadius)
        .onAppear { monitor.fetchPortInfo() }
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
