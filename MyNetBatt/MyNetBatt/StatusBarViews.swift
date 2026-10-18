import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 狀態列視圖
struct NetworkBarView: View {
    @Bindable var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 4) {
            if monitor.showNetChart {
                MiniGraphView(
                    history: Array(monitor.trafficHistory.suffix(monitor.netChartPoints)),
                    globalMaxDl: monitor.trafficHistory.map(\.downloadSpeed).max() ?? 1,
                    globalMaxUl: monitor.trafficHistory.map(\.uploadSpeed).max() ?? 1,
                    style: monitor.netChartStyle, points: monitor.netChartPoints
                )
                .frame(width: monitor.netChartWidth, height: 16)
            }
            if monitor.showNetSpeed {
                NetSpeedLabel(monitor: monitor, style: monitor.netSpeedStyle)
            }
        }
        .padding(.horizontal, 2).frame(maxHeight: .infinity)
    }
}

/// 選單列的網速文字；設定頁的樣式預覽也用同一個畫面，所見即所得。
struct NetSpeedLabel: View {
    let monitor: SystemMonitor
    let style: Int

    static let styleNames: [LocalizedStringKey] = ["上傳＋下載（兩行）", "僅上傳", "僅下載", "上傳＋下載合計", "上傳＋下載（單行）", "速度＋今日用量", "網速＋CPU", "網速＋記憶體"]

    var body: some View {
        Group {
            switch style {
            case 1, 2:
                singleLine(monitor.barSpeedText(upload: style == 1), color: style == 1 ? .green : .cyan)
            case 3:
                singleLine(monitor.barText(monitor.totalSpeedStr, arrow: "⇅"), color: .primary)
            case 4:
                HStack(spacing: 6) {
                    singleLine(monitor.barSpeedText(upload: true), color: .green)
                        .frame(width: monitor.netSpeedTextWidth(style: 1), alignment: .leading)
                    singleLine(monitor.barSpeedText(upload: false), color: .cyan)
                        .frame(width: monitor.netSpeedTextWidth(style: 1), alignment: .leading)
                }
            case 5:
                HStack(spacing: 6) {
                    speedOverUsage(upload: true, color: .green)
                    speedOverUsage(upload: false, color: .cyan)
                }
            case 6, 7:
                HStack(spacing: 6) {
                    twoLineSpeeds.frame(width: monitor.netSpeedTextWidth(style: 0), alignment: .leading)
                    metricColumn(style == 6 ? "CPU" : "MEM", value: style == 6 ? monitor.currentCpuUsage : monitor.ramUsagePct)
                }
            default:
                twoLineSpeeds
            }
        }
        .frame(width: monitor.netSpeedTextWidth(style: style), alignment: .leading)
    }

    private var twoLineSpeeds: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(monitor.barSpeedText(upload: true)).foregroundColor(.green)
            Text(monitor.barSpeedText(upload: false)).foregroundColor(.cyan)
        }
        .font(.system(size: 9, weight: .bold).monospacedDigit())
        // 三位數的速度在窄版放不下時縮小字級，不要截成「…」。
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// 上面是小字標題，下面是百分比；和系統「活動監視器」的選單列樣式相同。
    private func metricColumn(_ title: String, value: Double) -> some View {
        VStack(alignment: .center, spacing: -2) {
            Text(title).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))%").font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(value >= 85 ? Color.red : (value >= 60 ? Color.orange : Color.primary))
        }
        .lineLimit(1)
        .frame(width: SystemMonitor.metricColumnWidth)
    }

    private func singleLine(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundColor(color)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// 上面是即時速度，下面是今天累計的用量。
    private func speedOverUsage(upload: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(monitor.barSpeedText(upload: upload)).foregroundColor(color)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
            Text(upload ? monitor.todayUpStr : monitor.todayDownStr).foregroundStyle(.secondary)
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: monitor.netSpeedTextWidth(style: 0), alignment: .leading)
    }
}

struct BatteryBarView: View {
    @Bindable var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 2) {
            if monitor.showBatText {
                Text("\(monitor.batPct)%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(monitor.isLowBatteryWarning ? Color.red : Color.primary)
            }
            if monitor.showBatIcon {
                if monitor.batIconLarge {
                    BatteryGlyph(
                        level: monitor.batPct, fill: monitor.displayedBatteryColor, plugged: monitor.isPluggedIn,
                        outline: monitor.isLowBatteryWarning ? .red : .primary
                    )
                } else if monitor.isLowBatteryWarning {
                    // Monochrome colors every layer, including the outline of
                    // battery.0 when the symbol has no visible fill remaining.
                    Image(systemName: monitor.batteryIcon)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.red)
                } else if monitor.isPluggedIn {
                    Image(systemName: monitor.batteryIcon)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.primary, .primary, monitor.batteryColor)
                } else {
                    Image(systemName: monitor.batteryIcon)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(monitor.batteryColor, .primary)
                }
            }
        }
        .padding(.horizontal, 2).frame(maxHeight: .infinity)
    }
}

/// CPU、記憶體、儲存空間的選單列項目：左邊圖示、右邊百分比。
struct MetricBarView: View {
    enum Metric { case cpu, memory, disk }
    @Bindable var monitor: SystemMonitor
    let metric: Metric

    static let width: CGFloat = 54

    private var symbol: String {
        switch metric {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    private var value: Double {
        switch metric {
        case .cpu: return monitor.currentCpuUsage
        case .memory: return monitor.ramUsagePct
        case .disk: return monitor.diskUsagePct
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text("\(Int(value.rounded()))%").font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 選單列的連接埠圖示：有連接埠被線材限速時加一個橘色圓點。
struct PortsBarView: View {
    @Bindable var monitor: SystemMonitor
    static let width: CGFloat = 28
    /// 加上功率文字時的寬度（例如「65 W」）。
    static let widthWithWatts: CGFloat = 64
    /// 可選的圖示樣式：直立線材、橫向線材、閃電、插頭、電源線。
    static let symbols = ["cable.connector", "cable.connector.horizontal", "bolt.fill", "powerplug.fill", "powercord.fill"]

    /// 設定打開且接著電源時，在圖示旁顯示瓦數（寬度只隨插拔改變，數字跳動不會讓選單列位移）。
    static func showsWatts(_ monitor: SystemMonitor) -> Bool {
        monitor.showPortsWatts && monitor.isPluggedIn
    }

    var body: some View {
        let warning = monitor.portInfos.contains { $0.verdict?.level == .warning }
        let symbol = Self.symbols.indices.contains(monitor.portsIconStyle) ? Self.symbols[monitor.portsIconStyle] : Self.symbols[1]
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if warning { Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: 3, y: -2) }
                }
            if Self.showsWatts(monitor) {
                Text(verbatim: monitor.powerInWatts > 0 ? "\(Int(monitor.powerInWatts.rounded())) W" : "-- W")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 與系統電池圖示同尺寸的自繪圖示（含正極約 27×12.5 pt），電量依實際百分比連續填充。
/// 接上電源時閃電會超出外框上下緣，並在外框與填色上留出一圈間隙。
struct BatteryGlyph: View {
    let level: Int
    let fill: Color
    let plugged: Bool
    var outline: Color = .primary
    var height: CGFloat = 12.5

    var body: some View {
        let width = height * 2.0
        let line = max(1, height * 0.1)
        let inset = line + height * 0.09
        let fraction = CGFloat(max(0, min(100, level))) / 100
        let bolt = BatteryBoltShape()
        HStack(spacing: height * 0.07) {
            ZStack {
                ZStack {
                    RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                        .strokeBorder(outline.opacity(0.55), lineWidth: line)
                    RoundedRectangle(cornerRadius: height * 0.15, style: .continuous)
                        .fill(fill)
                        .frame(width: max(height * 0.15, (width - inset * 2) * fraction))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(inset)
                }
                .frame(width: width, height: height)

                if plugged {
                    bolt.stroke(style: StrokeStyle(lineWidth: height * 0.26, lineJoin: .round))
                        .frame(width: height * 0.6, height: height * 1.22)
                        .blendMode(.destinationOut)
                    bolt.fill(outline)
                        .frame(width: height * 0.6, height: height * 1.22)
                }
            }
            .frame(width: width, height: height * 1.3)
            .compositingGroup()

            // 正極：右側為圓角的半膠囊形。
            UnevenRoundedRectangle(bottomTrailingRadius: height * 0.12, topTrailingRadius: height * 0.12)
                .fill(outline.opacity(0.55))
                .frame(width: height * 0.11, height: height * 0.36)
        }
        .frame(height: height)
    }
}

private struct BatteryBoltShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [
            (0.64, 0.0), (0.06, 0.57), (0.45, 0.57), (0.34, 1.0), (0.94, 0.42), (0.55, 0.42)
        ]
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// 選單列的迷你流量圖。樣式：0 = 重疊面積、1 = 上下鏡像（上傳在上、下載在下）、2 = 長條。
struct MiniGraphView: View {
    var history: [TrafficData]; var globalMaxDl: Double; var globalMaxUl: Double
    var style: Int = 0
    var points: Int = 6

    var body: some View {
        Canvas { context, size in
            let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
            context.fill(frame, with: .color(Color.primary.opacity(0.08)))
            guard history.count > 1 else { return }
            // 縱軸至少 100 KB/s，閒置時不會把雜訊放大成滿格。
            let maxDl = max(globalMaxDl, 102400), maxUl = max(globalMaxUl, 102400)
            let stepX = size.width / CGFloat(max(points - 1, 1))
            // 資料不足一整排時靠右對齊，最新的點永遠在最右邊。
            let offsetX = CGFloat(points - history.count) * stepX

            switch style {
            case 1:
                let mid = size.height / 2
                var ul = Path(), dl = Path()
                for (i, data) in history.enumerated() {
                    let x = offsetX + CGFloat(i) * stepX
                    let up = mid - CGFloat(data.uploadSpeed / maxUl) * (mid - 1)
                    let down = mid + CGFloat(data.downloadSpeed / maxDl) * (mid - 1)
                    if i == 0 { ul.move(to: CGPoint(x: x, y: mid)); dl.move(to: CGPoint(x: x, y: mid)) }
                    ul.addLine(to: CGPoint(x: x, y: up)); dl.addLine(to: CGPoint(x: x, y: down))
                }
                let lastX = offsetX + CGFloat(history.count - 1) * stepX
                ul.addLine(to: CGPoint(x: lastX, y: mid)); ul.closeSubpath()
                dl.addLine(to: CGPoint(x: lastX, y: mid)); dl.closeSubpath()
                context.fill(ul, with: .color(.green.opacity(0.85)))
                context.fill(dl, with: .color(.cyan.opacity(0.85)))
                context.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(Color.primary.opacity(0.3)))
            case 2:
                let barWidth = max(1, stepX * 0.36)
                for (i, data) in history.enumerated() {
                    let x = offsetX + CGFloat(i) * stepX
                    let dlHeight = max(0.5, CGFloat(data.downloadSpeed / maxDl) * (size.height - 1))
                    let ulHeight = max(0.5, CGFloat(data.uploadSpeed / maxUl) * (size.height - 1))
                    context.fill(Path(roundedRect: CGRect(x: x - barWidth, y: size.height - ulHeight, width: barWidth, height: ulHeight), cornerRadius: 0.5), with: .color(.green))
                    context.fill(Path(roundedRect: CGRect(x: x, y: size.height - dlHeight, width: barWidth, height: dlHeight), cornerRadius: 0.5), with: .color(.cyan))
                }
            default:
                var dlPath = Path(), ulPath = Path()
                for (i, data) in history.enumerated() {
                    let x = offsetX + CGFloat(i) * stepX
                    let dlY = size.height - CGFloat(data.downloadSpeed / maxDl) * size.height
                    let ulY = size.height - CGFloat(data.uploadSpeed / maxUl) * size.height
                    if i == 0 { dlPath.move(to: CGPoint(x: x, y: dlY)); ulPath.move(to: CGPoint(x: x, y: ulY)) }
                    else { dlPath.addLine(to: CGPoint(x: x, y: dlY)); ulPath.addLine(to: CGPoint(x: x, y: ulY)) }
                }
                let lastX = offsetX + CGFloat(history.count - 1) * stepX
                for (path, color) in [(dlPath, Color.cyan), (ulPath, Color.green)] {
                    var area = path
                    area.addLine(to: CGPoint(x: lastX, y: size.height)); area.addLine(to: CGPoint(x: offsetX, y: size.height)); area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.3)))
                    context.stroke(path, with: .color(color), lineWidth: 1.0)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
