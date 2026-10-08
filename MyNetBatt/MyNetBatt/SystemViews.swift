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
        case 4: return "嚴重"
        case 2: return "警告"
        default: return "正常"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("硬體與系統效能").font(.largeTitle.bold())

                VStack(spacing: 12) {
                    SystemInfoRow(icon: "macbook", color: .gray, title: "Mac 型號", value: monitor.macModelStr)
                    SystemInfoRow(icon: "cpu", color: .purple, title: "處理器 (CPU)", value: monitor.cpuModelStr)
                    SystemInfoRow(icon: "memorychip", color: .orange, title: "顯示卡 (GPU)", value: monitor.gpuModelStr)
                }
                .padding(16)
                .cardSurface(cornerRadius: 12, fill: 0.1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Thunderbolt / USB4 設備", systemImage: "bolt.horizontal.circle")
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
                .padding(16)
                .cardSurface(cornerRadius: 12, fill: 0.08)

                PortsCard(monitor: monitor)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    SystemCard(
                        icon: "speedometer",
                        title: "CPU 負載",
                        value: String(format: "%.1f %%", monitor.currentCpuUsage),
                        progress: monitor.currentCpuUsage,
                        color: .purple
                    )
                    SystemCard(
                        icon: "gauge.with.dots.needle.67percent",
                        title: "GPU 負載",
                        value: String(format: "%.1f %%", monitor.currentGpuUsage),
                        progress: monitor.currentGpuUsage,
                        color: .green
                    )
                    SystemCard(
                        icon: "memorychip.fill",
                        title: "實體記憶體",
                        value: monitor.ramUsageStr,
                        detail: String(format: "記憶體壓力 %.0f%% · %@", monitor.memoryPressurePct, memoryPressureLabel),
                        progress: monitor.ramUsagePct,
                        color: memoryPressureColor
                    )
                    SystemCard(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: "Swap 虛擬記憶體",
                        value: monitor.swapUsageStr,
                        detail: String(format: "已使用 %.0f%%", monitor.swapUsagePct),
                        progress: monitor.swapUsagePct,
                        color: .orange
                    )
                }

                StorageVolumesCard(monitor: monitor)

                Text("CPU 即時負載趨勢")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

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

                Text("GPU 即時負載趨勢")
                    .font(.headline)
                    .foregroundStyle(.secondary)

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 每個內建連接埠接了什麼裝置，以及線材 e‑marker 回報的速度與額定功率。
struct PortsCard: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        let connected = monitor.portInfos.filter(\.isConnected).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("連接埠與線材", systemImage: "cable.connector").font(.headline)
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
        .padding(16)
        .cardSurface(cornerRadius: 12, fill: 0.08)
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

    private func eject(_ volume: StorageVolumeInfo) {
        ejectingID = volume.id
        Task {
            ejectError = await monitor.ejectVolume(volume)
            ejectingID = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("儲存空間", systemImage: "internaldrive.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(monitor.storageVolumes.count > 1 ? "\(monitor.storageVolumes.count) 個磁碟區" : "Macintosh HD")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        subtitle: volume.isInternal ? "內建磁碟" : volume.mountPath,
                        isEjecting: ejectingID == volume.id,
                        onEject: volume.isEjectable ? { eject(volume) } : nil
                    )
                    if volume.id != monitor.storageVolumes.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 12, fill: 0.08)
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
                Text(String(format: "%.1f%% 已使用", pct))
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
