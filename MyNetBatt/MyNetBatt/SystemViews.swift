import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 系統效能視窗
struct SystemDetailView: View {
    @ObservedObject var monitor: SystemMonitor

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
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)

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
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)

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
                        progress: monitor.ramUsagePct,
                        color: .blue
                    )
                    SystemCard(
                        icon: "arrow.up.arrow.down.circle.fill",
                        title: "Swap 虛擬記憶體",
                        value: monitor.swapUsageStr,
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
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("時間", data.time), y: .value("使用率", data.value))
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
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("時間", data.time), y: .value("使用率", data.value))
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
                Image(systemName: icon).foregroundStyle(color)
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

            ProgressView(value: max(0, min(100, progress)), total: 100.0)
                .tint(color)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}

struct StorageVolumesCard: View {
    @ObservedObject var monitor: SystemMonitor

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
                        subtitle: volume.isInternal ? "內建磁碟" : volume.mountPath
                    )
                    if volume.id != monitor.storageVolumes.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }
}

struct StorageVolumeRow: View {
    let name: String
    let used: String
    let free: String
    let total: String
    let pct: Double
    let subtitle: String

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
            }
            Text("已用 \(used) / 共 \(total)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("可用 \(free)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: max(0, min(100, pct)), total: 100)
                .tint(.cyan)
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
