import SwiftUI

// MARK: - 周邊裝置頁
struct DevicesDetailView: View {
    @Bindable var monitor: SystemMonitor
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        PageScroll {
            PageHeader(
                title: "周邊裝置",
                subtitle: monitor.peripherals.isEmpty ? String(localized: "藍牙鍵盤、滑鼠、觸控板與耳機的電量") : String(localized: "\(monitor.peripherals.count) 個裝置已連線"),
                symbol: MainTab.devices.symbol, color: MainTab.devices.color
            ) {
                Button {
                    monitor.fetchPeripheralBatteries(forceProfiler: true)
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }
            }

            if monitor.peripherals.isEmpty {
                Panel(title: "裝置") {
                    EmptyStateView(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "沒有連線中的藍牙周邊",
                        message: "連上妙控鍵盤、滑鼠、觸控板或 AirPods 等會回報電量的藍牙裝置後，電量會顯示在這裡。"
                    )
                }
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(monitor.peripherals) { PeripheralCard(device: $0) }
                }
            }

            Panel(title: "提醒", symbol: "bell.badge.fill", color: .red) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("周邊裝置電量低於 10% 時通知")
                        Text("每個裝置充電回 20% 以上後才會再次提醒。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("周邊裝置電量低於 10% 時通知", isOn: $monitor.notifyPeripheralLow)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Text("妙控系列的電量每 30 秒更新；AirPods 與其他藍牙裝置從系統資訊讀取，打開這一頁時每 30 秒、平常每 5 分鐘更新一次。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { monitor.setBatteryDetailVisible(true, source: "devices"); monitor.fetchPeripheralBatteries(forceProfiler: true) }
        .onDisappear { monitor.setBatteryDetailVisible(false, source: "devices") }
    }
}

/// 一個裝置的卡片；AirPods 這類耳機分成左耳、右耳、充電盒三個圓環。
struct PeripheralCard: View {
    let device: PeripheralDevice

    static func color(_ level: Int?) -> Color {
        guard let level else { return .secondary }
        if level <= 10 { return .red }
        if level <= 20 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 20))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.headline).lineLimit(1)
                    Text(kindName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let level = device.level {
                HStack(spacing: 14) {
                    ring(level, label: nil, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(level)%").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(level <= 20 ? "電量偏低，請記得充電" : "電量充足").font(.caption).foregroundStyle(level <= 20 ? Color.orange : Color.secondary)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    if let left = device.left { ring(left, label: String(localized: "左耳"), size: 56) }
                    if let right = device.right { ring(right, label: String(localized: "右耳"), size: 56) }
                    if let caseLevel = device.caseLevel { ring(caseLevel, label: String(localized: "充電盒"), size: 56) }
                }
            }
        }
        .padding(Metrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Metrics.panelRadius)
    }

    private var kindName: LocalizedStringKey {
        switch device.kind {
        case .keyboard: return "鍵盤"
        case .mouse: return "滑鼠"
        case .trackpad: return "觸控板"
        case .headphones: return "耳機"
        case .speaker: return "揚聲器"
        case .gamepad: return "遊戲控制器"
        case .other: return "藍牙裝置"
        }
    }

    private func ring(_ level: Int, label: String?, size: CGFloat) -> some View {
        VStack(spacing: 5) {
            RingGauge(fraction: Double(level) / 100, color: Self.color(level), lineWidth: size * 0.11) {
                if label != nil {
                    Text("\(level)%").font(.system(size: size * 0.24, weight: .bold, design: .rounded)).monospacedDigit()
                } else {
                    Image(systemName: device.symbol).font(.system(size: size * 0.3))
                }
            }
            .frame(width: size, height: size)
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// 電池小視窗裡的一列周邊電量。
struct PeripheralStrip: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        if !monitor.peripherals.isEmpty {
            WidgetCard {
                HStack {
                    Text("周邊裝置").font(.caption).foregroundStyle(monitor.accentColor).bold()
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(monitor.peripherals.prefix(4)) { device in
                        HStack(spacing: 8) {
                            RingGauge(fraction: Double(device.primaryLevel ?? 0) / 100, color: PeripheralCard.color(device.primaryLevel), lineWidth: 3.5) {
                                Image(systemName: device.symbol).font(.system(size: 12))
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.caption).lineLimit(1)
                                Text(device.primaryLevel.map { "\($0)%" } ?? "--").font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                        }
                        .help(device.name)
                    }
                }
            }
        }
    }
}
