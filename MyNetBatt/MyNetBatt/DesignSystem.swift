import SwiftUI

// MARK: - 監控中心的共用設計元件
// 所有頁面用同一套頁首、面板、數據磚與圓環，字級、間距、圓角才會一致。
// 卡片底色一律用 cardSurface（不用 glassEffect：頁面上有玻璃卡片時系統會把整頁背景提亮）。

enum Palette {
    /// 上傳／下載在監控中心與小視窗的固定配色。
    static let upload = Color.pink
    static let download = Color.green
}

enum Metrics {
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 18
    static let panelRadius: CGFloat = 16
    static let panelPadding: CGFloat = 18
}

/// 系統設定風格的圖示底塊：彩色圓角方塊上放白色圖示。
struct IconChip: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.mix(with: .white, by: 0.12), color], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .shadow(color: color.opacity(0.25), radius: 2, y: 1)
    }
}

/// 頁首：大標題、副標題，右側可放這一頁的操作。
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let symbol: String
    let color: Color
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconChip(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 26, weight: .bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: String? = nil, symbol: String, color: Color) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, color: color) { EmptyView() }
    }
}

/// 有標題列的面板。
struct Panel<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    var symbol: String? = nil
    var color: Color = .accentColor
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                if let symbol { IconChip(symbol: symbol, color: color, size: 24) }
                Text(title).font(.headline)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(Metrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: Metrics.panelRadius)
    }
}

extension Panel where Accessory == EmptyView {
    init(title: LocalizedStringKey, symbol: String? = nil, color: Color = .accentColor, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, color: color, accessory: { EmptyView() }, content: content)
    }
}

/// 數值磚：小標題、大數值、補充說明。
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var symbol: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .contentTransition(.numericText())
            if let caption, !caption.isEmpty {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(cornerRadius: 12, fill: 0.1)
    }
}

/// 圓環儀表；中央可放任意內容。
struct RingGauge<Center: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(
                    AngularGradient(colors: [color.opacity(0.75), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, min(1, fraction)))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
            center()
        }
    }
}

/// 總覽頁可點擊的磚：滑過時微微浮起，點一下切換到對應的分頁。
struct OverviewTile<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IconChip(symbol: symbol, color: color, size: 22)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .cardSurface(cornerRadius: Metrics.panelRadius, fill: hovering ? 0.13 : 0.08)
            .scaleEffect(hovering ? 1.008 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// 空狀態：圖示＋說明，可加一個按鈕。
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// 頁面內容的標準外框：可捲動、統一的邊距與區塊間距。
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                content()
            }
            .padding(Metrics.pagePadding)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
