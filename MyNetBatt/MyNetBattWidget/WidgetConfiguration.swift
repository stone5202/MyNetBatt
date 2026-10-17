import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 小工具的設定選項（在小工具上按右鍵 › 編輯）

enum WidgetTheme: String, AppEnum {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, graphite

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "主題色")
    static let caseDisplayRepresentations: [WidgetTheme: DisplayRepresentation] = [
        .blue: "藍色", .indigo: "靛藍", .purple: "紫色", .pink: "粉紅色", .red: "紅色",
        .orange: "橘色", .yellow: "黃色", .green: "綠色", .teal: "藍綠色", .graphite: "石墨色"
    ]

    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .graphite: return Color(white: 0.55)
        }
    }
}

enum UsageDirection: String, AppEnum {
    case both, upload, download

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "顯示")
    static let caseDisplayRepresentations: [UsageDirection: DisplayRepresentation] = [
        .both: "上傳＋下載", .upload: "僅上傳", .download: "僅下載"
    ]
}

struct ThemeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "小工具外觀"
    static let description = IntentDescription("選擇小工具的主題色。")

    @Parameter(title: "主題色", default: .blue)
    var theme: WidgetTheme

    init() {}
    init(theme: WidgetTheme) { self.theme = theme }
}

struct DataUsageIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "數據用量"
    static let description = IntentDescription("選擇要顯示的方向與主題色。")

    @Parameter(title: "顯示", default: .both)
    var direction: UsageDirection

    @Parameter(title: "主題色", default: .blue)
    var theme: WidgetTheme

    init() {}
}

/// 有主題色的設定選項。
protocol ThemedIntent: WidgetConfigurationIntent {
    var theme: WidgetTheme { get }
}
extension ThemeIntent: ThemedIntent {}
extension DataUsageIntent: ThemedIntent {}

struct ExtrasEntry<Intent: ThemedIntent>: TimelineEntry {
    let date: Date
    let extras: WidgetExtras?
    let configuration: Intent
}

/// 所有新小工具共用：讀主程式寫好的 widget-extras.json；主程式每分鐘更新，
/// 這裡的 15 分鐘只是主程式沒在執行時的備援。
struct ExtrasProvider<Intent: ThemedIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ExtrasEntry<Intent> {
        ExtrasEntry(date: Date(), extras: .sample, configuration: Intent())
    }

    func snapshot(for configuration: Intent, in context: Context) async -> ExtrasEntry<Intent> {
        let extras = WidgetExtras.load()
        return ExtrasEntry(date: Date(), extras: context.isPreview && extras == nil ? .sample : extras, configuration: configuration)
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<ExtrasEntry<Intent>> {
        let now = Date()
        let entry = ExtrasEntry(date: now, extras: WidgetExtras.load(), configuration: configuration)
        // 主程式沒在執行時也要在午夜重新整理一次，「今日」才會換成資料所屬的日期。
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) ?? now.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(min(now.addingTimeInterval(900), midnight)))
    }
}

extension WidgetExtras {
    /// 小工具庫的預覽與第一次載入前的佔位資料。
    static var sample: WidgetExtras {
        let hours = (0..<24).map { UInt64(max(0, sin(Double($0) / 3.5) + 1) * 80_000_000) }
        let days = (0..<7).map { Calendar.current.date(byAdding: .day, value: $0 - 6, to: Calendar.current.startOfDay(for: Date()))! }
        return WidgetExtras(
            updated: Date(),
            traffic: Traffic(
                hourlyUp: hours.map { $0 / 6 }, hourlyDown: hours,
                dailyUp: [210, 180, 260, 150, 300, 240, 120].map { UInt64($0) * 1_000_000 },
                dailyDown: [2.1, 1.6, 3.2, 1.2, 4.0, 2.8, 1.4].map { UInt64($0 * 1_000_000_000) },
                dailyDates: days
            ),
            apps: [
                AppItem(name: "Safari", bytes: 1_400_000_000, upload: 90_000_000, download: 1_310_000_000),
                AppItem(name: "Music", bytes: 620_000_000, upload: 8_000_000, download: 612_000_000),
                AppItem(name: "Mail", bytes: 180_000_000, upload: 40_000_000, download: 140_000_000),
                AppItem(name: "Messages", bytes: 90_000_000, upload: 30_000_000, download: 60_000_000)
            ],
            appsTotal: 2_400_000_000,
            volumes: [Volume(name: "Macintosh HD", used: 612_000_000_000, total: 994_000_000_000, isInternal: true)],
            folders: [Folder(name: "Downloads", bytes: 48_000_000_000), Folder(name: "Movies", bytes: 31_000_000_000), Folder(name: "Documents", bytes: 12_000_000_000)],
            wifi: WiFi(ssid: "Wi‑Fi", interface: "en0", connected: true, localIP: "192.168.1.20", publicIP: "203.0.113.8", bars: 4, rssi: "-48 dBm", channel: "149 · 5 GHz · 80 MHz", rate: "1201 Mbps"),
            peripherals: [
                Peripheral(name: "AirPods Pro", symbol: "airpodspro", left: 82, right: 80, caseLevel: 64),
                Peripheral(name: "Magic Keyboard", symbol: "keyboard", level: 71),
                Peripheral(name: "Magic Mouse", symbol: "computermouse", level: 18)
            ]
        )
    }
}

// MARK: - 共用格式與元件

enum WidgetFormat {
    /// 和主程式一樣以 1024 為單位。
    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v >= 1_099_511_627_776 { return String(format: "%.2f TB", v / 1_099_511_627_776) }
        if v >= 1_073_741_824 { return String(format: "%.2f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.1f MB", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.0f KB", v / 1024) }
        return "\(value) B"
    }

    /// 磁碟容量和 Finder 一樣以 1000 為單位。
    static func storage(_ value: Int64) -> String {
        let v = Double(max(0, value))
        if v >= 1_000_000_000_000 { return String(format: "%.2f TB", v / 1_000_000_000_000) }
        if v >= 1_000_000_000 { return String(format: "%.0f GB", v / 1_000_000_000) }
        return String(format: "%.0f MB", v / 1_000_000)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// 小工具的標題列：圖示＋標題，右邊可放補充文字。
struct WidgetHeader: View {
    let symbol: String
    let title: Text
    var trailing: String? = nil
    let tint: Color

    init(symbol: String, title: LocalizedStringKey, trailing: String? = nil, tint: Color) {
        self.init(symbol: symbol, titleText: Text(title), trailing: trailing, tint: tint)
    }

    init(symbol: String, titleText: Text, trailing: String? = nil, tint: Color) {
        self.symbol = symbol
        self.title = titleText
        self.trailing = trailing
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .widgetAccentable()
            title
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

/// 主程式沒在執行或還沒寫過資料時的提示。
struct WidgetEmptyState: View {
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 圓環電量／用量。
struct WidgetRing: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
    }
}

/// 膠囊形的比例條。
struct WidgetMeter: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(tint.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint)
                        .frame(width: max(fraction > 0 ? height : 0, geo.size.width * max(0, min(1, fraction))))
                        .widgetAccentable()
                }
        }
        .frame(height: height)
    }
}

// MARK: - 語言
/// MyNetBatt 設定裡選的介面語言（「跟隨系統」時沒有值）；小工具用它來決定顯示的語言。
enum WidgetLanguage {
    static var locale: Locale? {
        UserDefaults(suiteName: WidgetSnapshot.appGroup)?.string(forKey: "appLanguage").map(Locale.init(identifier:))
    }
}

extension View {
    @ViewBuilder
    func widgetLanguage() -> some View {
        if let locale = WidgetLanguage.locale {
            environment(\.locale, locale)
        } else {
            self
        }
    }
}

// MARK: - 資料新舊
extension WidgetExtras {
    /// 主程式超過 30 分鐘沒有更新（多半是沒在執行），連線、周邊裝置等即時狀態可能已經改變。
    func isStale(at date: Date) -> Bool { date.timeIntervalSince(updated) > 1800 }

    /// 今日用量是否真的是今天的；不是時改標資料所屬的日期。
    func isFromToday(at date: Date) -> Bool { Calendar.current.isDate(updated, inSameDayAs: date) }

    /// 「今日」或資料所屬的日期（例如「10/16」）。
    func dayTitle(at date: Date, today: LocalizedStringKey) -> Text {
        isFromToday(at: date) ? Text(today) : Text(updated, format: .dateTime.month(.defaultDigits).day())
    }
}

/// 資料過期時的提示：「更新於 10/16 21:30」。
struct StaleNote: View {
    let updated: Date

    var body: some View {
        let sameDay = Calendar.current.isDateInToday(updated)
        let time = sameDay ? updated.formatted(date: .omitted, time: .shortened) : updated.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        Label {
            Text("更新於 \(time)")
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
