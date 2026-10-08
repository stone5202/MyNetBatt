import SwiftUI
import WidgetKit
import IOKit.ps

@main
struct MyNetBattWidgetBundle: WidgetBundle {
    var body: some Widget {
        BatteryWidget()
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("電池")
        .description("電量、充電狀態、健康度與過去 24 小時的電量變化。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BatteryEntry: TimelineEntry {
    let date: Date
    let level: Int?
    let plugged: Bool
    let charging: Bool
    /// MyNetBatt 沒在執行時沒有這份資料，或資料已經過期。
    let snapshot: WidgetSnapshot?

    static let placeholder = BatteryEntry(date: Date(), level: 80, plugged: false, charging: false, snapshot: nil)
}

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(context.isPreview ? .placeholder : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        // 電量或電源狀態改變時主程式會要求重新載入；這裡的 15 分鐘是主程式沒在執行時的備援。
        completion(Timeline(entries: [currentEntry()], policy: .after(Date().addingTimeInterval(900))))
    }

    private func currentEntry() -> BatteryEntry {
        let snapshot = WidgetSnapshot.load()
        // 電量與電源狀態直接向系統讀取，主程式沒在執行時也是最新的。
        if let live = Self.readPowerSource() {
            return BatteryEntry(date: Date(), level: live.level, plugged: live.plugged, charging: live.charging, snapshot: snapshot)
        }
        return BatteryEntry(
            date: Date(), level: snapshot?.level, plugged: snapshot?.plugged ?? false,
            charging: snapshot?.charging ?? false, snapshot: snapshot
        )
    }

    private static func readPowerSource() -> (level: Int, plugged: Bool, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (
                Int((Double(current) / Double(max) * 100).rounded()),
                description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                description[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// 桌面上的小工具在有視窗蓋住時會變成單色，這時顏色分不出電源與電池，改用深淺區分。
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: BatteryEntry

    private static let batteryColor = Color(red: 0.93, green: 0.66, blue: 0.0)
    private static let pluggedColor = Color.green

    /// 主程式超過 30 分鐘沒更新時，剩餘時間、功率這些即時數值已經不準，改顯示「--」。
    private var fresh: WidgetSnapshot? {
        guard let snapshot = entry.snapshot, entry.date.timeIntervalSince(snapshot.updated) < 1800 else { return nil }
        return snapshot
    }

    private var statusText: String {
        entry.charging ? "充電中" : (entry.plugged ? "已接上電源" : "使用電池")
    }

    private var levelColor: Color {
        guard let level = entry.level else { return .secondary }
        if entry.plugged { return Self.pluggedColor }
        return level <= 20 ? .red : .primary
    }

    private var symbolName: String {
        guard let level = entry.level else { return "battery.0" }
        if entry.plugged { return "battery.100.bolt" }
        switch level {
        case 81...: return "battery.100"
        case 61...80: return "battery.75"
        case 36...60: return "battery.50"
        case 16...35: return "battery.25"
        default: return "battery.0"
        }
    }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                summary.frame(width: 118, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("過去 24 小時").font(.caption2).foregroundStyle(.secondary)
                    historyBars
                    HStack(spacing: 10) {
                        detail("heart.fill", entry.snapshot?.health ?? "--")
                        detail("arrow.3.trianglepath", entry.snapshot?.cycles ?? "--")
                        detail("thermometer.medium", fresh?.temperature ?? "--")
                        detail("bolt.fill", fresh?.watts ?? "--")
                    }
                }
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbolName).font(.title3).foregroundStyle(levelColor)
                Spacer(minLength: 0)
                if family == .systemSmall, let health = entry.snapshot?.health, health != "--" {
                    Label(health, systemImage: "heart.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(entry.level.map { "\($0)%" } ?? "--")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(levelColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(statusText).font(.caption).bold()
            if let snapshot = fresh {
                Text("\(snapshot.timeTitle) \(snapshot.timeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var historyBars: some View {
        let levels = entry.snapshot?.levels ?? []
        let flags = entry.snapshot?.pluggedFlags ?? []
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let plugged = index < flags.count ? flags[index] : nil
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level == nil ? AnyShapeStyle(Color.secondary.opacity(0.15))
                              : AnyShapeStyle(plugged == true ? Self.pluggedColor : Self.batteryColor))
                        .opacity(renderingMode == .fullColor || level == nil || plugged == true ? 1 : 0.45)
                        .frame(height: max(2, proxy.size.height * CGFloat(level ?? 100) / 100))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .overlay {
            if levels.isEmpty {
                Text("打開 MyNetBatt 後開始記錄").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.caption2)
    }
}
