import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 數據用量

struct DataUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetExtras.Kind.dataUsage, intent: DataUsageIntent.self, provider: ExtrasProvider<DataUsageIntent>()) { entry in
            DataUsageWidgetView(entry: entry).widgetLanguage().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("數據用量")
        .description("今天每小時的上傳／下載量，以及最近 7 天的用量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DataUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExtrasEntry<DataUsageIntent>

    private var tint: Color { entry.configuration.theme.color }
    private var direction: UsageDirection { entry.configuration.direction }

    var body: some View {
        if let traffic = entry.extras?.traffic {
            content(traffic)
        } else {
            WidgetEmptyState(symbol: "arrow.up.arrow.down", message: "打開 MyNetBatt 後開始記錄")
        }
    }

    private func todayTotal(_ traffic: WidgetExtras.Traffic) -> (up: UInt64, down: UInt64) {
        (traffic.hourlyUp.reduce(0, +), traffic.hourlyDown.reduce(0, +))
    }

    @ViewBuilder
    private func content(_ traffic: WidgetExtras.Traffic) -> some View {
        let total = todayTotal(traffic)
        switch family {
        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeader(symbol: "arrow.up.arrow.down", titleText: entry.extras?.dayTitle(at: entry.date, today: "今日數據用量") ?? Text("今日數據用量"), tint: tint)
                    Spacer(minLength: 0)
                    totals(total)
                    if let extras = entry.extras, extras.isStale(at: entry.date) { StaleNote(updated: extras.updated) }
                }
                .frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("最近 7 天").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        legend
                    }
                    dailyBars(traffic)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(
                    symbol: "arrow.up.arrow.down", titleText: entry.extras?.dayTitle(at: entry.date, today: "今日") ?? Text("今日"),
                    trailing: entry.extras.flatMap { $0.isStale(at: entry.date) && $0.isFromToday(at: entry.date) ? WidgetFormat.time($0.updated) : nil },
                    tint: tint
                )
                hourlyBars(traffic).frame(maxHeight: .infinity)
                totals(total)
            }
        }
    }

    @ViewBuilder
    private func totals(_ total: (up: UInt64, down: UInt64)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if direction != .upload {
                row("arrow.down", WidgetFormat.bytes(total.down), tint, large: direction == .download || family == .systemMedium)
            }
            if direction != .download {
                row("arrow.up", WidgetFormat.bytes(total.up), tint.opacity(direction == .upload ? 1 : 0.55), large: direction == .upload)
            }
        }
    }

    private func row(_ symbol: String, _ value: String, _ color: Color, large: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).font(.system(size: large ? 13 : 11, weight: .bold)).foregroundStyle(color).widgetAccentable()
            Text(value)
                .font(.system(size: large ? 22 : 15, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            if direction != .upload { dot(tint, "下載") }
            if direction != .download { dot(tint.opacity(0.55), "上傳") }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func dot(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 6, height: 6); Text(label) }
    }

    /// 今天 24 小時的長條，上傳疊在下載上面。
    private func hourlyBars(_ traffic: WidgetExtras.Traffic) -> some View {
        let values = (0..<24).map { hour -> (up: Double, down: Double) in
            let up = direction == .download ? 0 : Double(traffic.hourlyUp[safe: hour] ?? 0)
            let down = direction == .upload ? 0 : Double(traffic.hourlyDown[safe: hour] ?? 0)
            return (up, down)
        }
        return StackedBars(values: values, tint: tint)
    }

    private func dailyBars(_ traffic: WidgetExtras.Traffic) -> some View {
        let values = traffic.dailyDown.indices.map { index -> (up: Double, down: Double) in
            (direction == .download ? 0 : Double(traffic.dailyUp[safe: index] ?? 0),
             direction == .upload ? 0 : Double(traffic.dailyDown[index]))
        }
        let labels = traffic.dailyDates.map { $0.formatted(.dateTime.weekday(.narrow)) }
        return VStack(spacing: 3) {
            StackedBars(values: values, tint: tint, spacing: 6)
            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 9, weight: index == labels.count - 1 ? .bold : .regular))
                        .foregroundStyle(index == labels.count - 1 ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// 堆疊長條：下半是下載（主題色），上半是上傳（主題色半透明）；沒有用量的位置留一點灰色短條。
struct StackedBars: View {
    let values: [(up: Double, down: Double)]
    let tint: Color
    var spacing: CGFloat = 2

    var body: some View {
        let peak = max(values.map { $0.up + $0.down }.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let total = value.up + value.down
                    VStack(spacing: 0) {
                        if total <= 0 {
                            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.18)).frame(height: 2)
                        } else {
                            let height = max(3, geo.size.height * total / peak)
                            RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(0.55))
                                .frame(height: height * value.up / total)
                            RoundedRectangle(cornerRadius: 1.5).fill(tint)
                                .frame(height: height * value.down / total)
                                .widgetAccentable()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - App 數據用量

struct AppUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetExtras.Kind.appUsage, intent: ThemeIntent.self, provider: ExtrasProvider<ThemeIntent>()) { entry in
            AppUsageWidgetView(entry: entry).widgetLanguage().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("App 數據用量")
        .description("今天用掉最多流量的 App。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AppUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExtrasEntry<ThemeIntent>

    private var tint: Color { entry.configuration.theme.color }

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemLarge: return 8
        default: return 4
        }
    }

    var body: some View {
        if let extras = entry.extras, !extras.apps.isEmpty {
            let apps = Array(extras.apps.prefix(limit))
            let peak = Double(max(apps.first?.bytes ?? 1, 1))
            VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 8) {
                WidgetHeader(
                    symbol: "app.badge",
                    titleText: extras.isFromToday(at: entry.date)
                        ? Text(family == .systemSmall ? "今日 App" : "今日 App 數據用量")
                        : Text("\(extras.updated, format: .dateTime.month(.defaultDigits).day()) App"),
                    trailing: family == .systemSmall ? nil : WidgetFormat.bytes(extras.appsTotal), tint: tint
                )
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        icon(app).frame(width: family == .systemSmall ? 20 : 24, height: family == .systemSmall ? 20 : 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(WidgetFormat.bytes(app.bytes))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            if family != .systemSmall {
                                WidgetMeter(fraction: Double(app.bytes) / peak, tint: tint, height: 4)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            WidgetEmptyState(symbol: "app.badge", message: "今天還沒有 App 用量紀錄")
        }
    }

    @ViewBuilder
    private func icon(_ app: WidgetExtras.AppItem) -> some View {
        if let data = app.icon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.2))
                .overlay(Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint))
        }
    }
}

// MARK: - 儲存空間

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetExtras.Kind.storage, intent: ThemeIntent.self, provider: ExtrasProvider<ThemeIntent>()) { entry in
            StorageWidgetView(entry: entry).widgetLanguage().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("儲存空間")
        .description("磁碟的可用空間，以及佔用最多的資料夾。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StorageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExtrasEntry<ThemeIntent>

    private var tint: Color { entry.configuration.theme.color }

    var body: some View {
        if let extras = entry.extras, let main = extras.volumes.first(where: \.isInternal) ?? extras.volumes.first {
            switch family {
            case .systemMedium:
                HStack(spacing: 16) {
                    mainVolume(main).frame(width: 118)
                    VStack(alignment: .leading, spacing: 7) {
                        if extras.volumes.count > 1 {
                            Text("磁碟").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(extras.volumes.filter { $0.name != main.name }.prefix(2)) { volume in
                                volumeRow(volume)
                            }
                        }
                        if !extras.folders.isEmpty {
                            Text("資料夾").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            let peak = Double(max(extras.folders.first?.bytes ?? 1, 1))
                            ForEach(extras.folders.prefix(extras.volumes.count > 1 ? 2 : 4)) { folder in
                                folderRow(folder, peak: peak)
                            }
                        } else if extras.volumes.count <= 1 {
                            Text("到 MyNetBatt 的「儲存空間」頁掃描後，這裡會列出佔用最多的資料夾。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if extras.isStale(at: entry.date) { StaleNote(updated: extras.updated) }
                    }
                }
            default:
                mainVolume(main)
            }
        } else {
            WidgetEmptyState(symbol: "internaldrive", message: "打開 MyNetBatt 後開始記錄")
        }
    }

    private func mainVolume(_ volume: WidgetExtras.Volume) -> some View {
        let fraction = volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(symbol: "internaldrive.fill", title: LocalizedStringKey(volume.name), tint: tint)
            Spacer(minLength: 0)
            ZStack {
                WidgetRing(fraction: fraction, tint: fraction > 0.9 ? .red : tint, lineWidth: 7)
                VStack(spacing: 0) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("已使用").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text("可用 \(WidgetFormat.storage(volume.total - volume.used))")
                .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
    }

    private func volumeRow(_ volume: WidgetExtras.Volume) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "externaldrive.fill").font(.system(size: 9)).foregroundStyle(tint)
                Text(volume.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(WidgetFormat.storage(volume.total - volume.used)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            WidgetMeter(fraction: volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0, tint: tint, height: 4)
        }
    }

    private func folderRow(_ folder: WidgetExtras.Folder, peak: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(tint)
                Text(folder.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(WidgetFormat.storage(folder.bytes)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            WidgetMeter(fraction: Double(folder.bytes) / peak, tint: tint.opacity(0.8), height: 4)
        }
    }
}

// MARK: - Wi‑Fi

struct WiFiWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetExtras.Kind.wifi, intent: ThemeIntent.self, provider: ExtrasProvider<ThemeIntent>()) { entry in
            WiFiWidgetView(entry: entry).widgetLanguage().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Wi‑Fi")
        .description("目前連線的網路、訊號強度與 IP 位址。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WiFiWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExtrasEntry<ThemeIntent>

    private var tint: Color { entry.configuration.theme.color }

    var body: some View {
        if let wifi = entry.extras?.wifi {
            let name = wifi.bars == nil ? (wifi.connected ? Text("有線網路") : Text("未連線")) : Text(verbatim: wifi.ssid ?? "Wi‑Fi")
            switch family {
            case .systemMedium:
                HStack(spacing: 16) {
                    summary(wifi, name: name).frame(width: 128, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 6) {
                        detail("本機 IP", wifi.localIP)
                        detail("公網 IP", wifi.publicIP)
                        if wifi.bars != nil {
                            detail("頻道", wifi.channel)
                            detail("傳輸率", wifi.rate)
                        } else {
                            detail("介面", wifi.interface)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                summary(wifi, name: name)
            }
        } else {
            WidgetEmptyState(symbol: "wifi", message: "打開 MyNetBatt 後開始記錄")
        }
    }

    private func summary(_ wifi: WidgetExtras.WiFi, name: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(symbol: wifi.bars == nil ? "network" : "wifi", title: "網路", tint: tint)
            Spacer(minLength: 0)
            if let bars = wifi.bars { SignalBars(bars: bars, tint: tint).frame(height: 22) }
            name
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(wifi.bars == nil ? wifi.interface : wifi.rssi)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            if let extras = entry.extras, extras.isStale(at: entry.date) {
                StaleNote(updated: extras.updated)
            } else if family == .systemSmall {
                Text(wifi.localIP).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// 四格的訊號強度。
struct SignalBars: View {
    let bars: Int
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < bars ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.22)))
                    .frame(width: 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .scaleEffect(y: CGFloat(index + 1) / 4, anchor: .bottom)
            }
        }
        .widgetAccentable()
    }
}

// MARK: - 周邊電量

struct PeripheralsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetExtras.Kind.peripherals, intent: ThemeIntent.self, provider: ExtrasProvider<ThemeIntent>()) { entry in
            PeripheralsWidgetView(entry: entry).widgetLanguage().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("周邊電量")
        .description("妙控鍵盤、滑鼠、觸控板與 AirPods 等藍牙裝置的電量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PeripheralsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExtrasEntry<ThemeIntent>

    private var tint: Color { entry.configuration.theme.color }

    var body: some View {
        if let devices = entry.extras?.peripherals, !devices.isEmpty {
            switch family {
            case .systemMedium:
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(symbol: "dot.radiowaves.left.and.right", title: "周邊電量", tint: tint)
                    HStack(spacing: 10) {
                        ForEach(rings(devices).prefix(4), id: \.id) { ring in
                            ringView(ring).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if let extras = entry.extras, extras.isStale(at: entry.date) { StaleNote(updated: extras.updated) }
                }
            default:
                VStack(alignment: .leading, spacing: 7) {
                    WidgetHeader(symbol: "dot.radiowaves.left.and.right", title: "周邊電量", tint: tint)
                    ForEach(devices.prefix(3)) { device in
                        HStack(spacing: 7) {
                            Image(systemName: device.symbol).font(.system(size: 13)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(device.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(levelText(device)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                                }
                                WidgetMeter(fraction: Double(primary(device) ?? 0) / 100, tint: color(primary(device)), height: 4)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let extras = entry.extras, extras.isStale(at: entry.date) { StaleNote(updated: extras.updated) }
                }
            }
        } else {
            WidgetEmptyState(symbol: "dot.radiowaves.left.and.right", message: "沒有連線中的藍牙周邊")
        }
    }

    private struct Ring: Identifiable {
        let id: String
        let symbol: String
        let label: Text
        let level: Int
    }

    /// AirPods 拆成左右耳（取較低者）與充電盒兩個圓環，其他裝置一個圓環。
    private func rings(_ devices: [WidgetExtras.Peripheral]) -> [Ring] {
        devices.flatMap { device -> [Ring] in
            if let level = device.level { return [Ring(id: device.name, symbol: device.symbol, label: Text(verbatim: device.name), level: level)] }
            var result: [Ring] = []
            if let buds = [device.left, device.right].compactMap({ $0 }).min() {
                result.append(Ring(id: device.name + "-buds", symbol: device.symbol, label: Text(verbatim: device.name), level: buds))
            }
            if let caseLevel = device.caseLevel {
                result.append(Ring(id: device.name + "-case", symbol: "airpods.chargingcase", label: Text("充電盒"), level: caseLevel))
            }
            return result
        }
    }

    private func ringView(_ ring: Ring) -> some View {
        VStack(spacing: 5) {
            ZStack {
                WidgetRing(fraction: Double(ring.level) / 100, tint: color(ring.level), lineWidth: 5)
                Image(systemName: ring.symbol).font(.system(size: 16))
            }
            .frame(width: 52, height: 52)
            Text("\(ring.level)%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            ring.label.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func primary(_ device: WidgetExtras.Peripheral) -> Int? {
        device.level ?? [device.left, device.right].compactMap { $0 }.min() ?? device.caseLevel
    }

    private func levelText(_ device: WidgetExtras.Peripheral) -> String {
        if let level = device.level { return "\(level)%" }
        let buds = [device.left, device.right].compactMap { $0 }
        if let low = buds.min() { return "\(low)%" }
        return device.caseLevel.map { "\($0)%" } ?? "--"
    }

    private func color(_ level: Int?) -> Color {
        guard let level else { return .secondary }
        return level <= 20 ? .red : tint
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
