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
                MiniGraphView(history: Array(monitor.trafficHistory.suffix(5)), globalMaxDl: monitor.trafficHistory.map(\.downloadSpeed).max() ?? 1, globalMaxUl: monitor.trafficHistory.map(\.uploadSpeed).max() ?? 1)
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

    static let styleNames = ["上傳＋下載（兩行）", "僅上傳", "僅下載", "上傳＋下載合計", "上傳＋下載（單行）", "速度＋今日用量"]

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
            default:
                VStack(alignment: .leading, spacing: -2) {
                    Text(monitor.barSpeedText(upload: true)).foregroundColor(.green)
                    Text(monitor.barSpeedText(upload: false)).foregroundColor(.cyan)
                }
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                // 三位數的速度在窄版放不下時縮小字級，不要截成「…」。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(width: monitor.netSpeedTextWidth(style: style), alignment: .leading)
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

struct MiniGraphView: View {
    var history: [TrafficData]; var globalMaxDl: Double; var globalMaxUl: Double
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.red.opacity(0.15)))
            guard history.count > 1 else { return }
            let maxDl = max(globalMaxDl, 102400), maxUl = max(globalMaxUl, 102400)
            var dlPath = Path(), ulPath = Path(); let maxPoints = 5; let stepX = size.width / CGFloat(maxPoints - 1)
            for (i, data) in history.enumerated() {
                let x = CGFloat(i) * stepX, dlY = size.height - (CGFloat(data.downloadSpeed / maxDl) * size.height), ulY = size.height - (CGFloat(data.uploadSpeed / maxUl) * size.height)
                if i == 0 { dlPath.move(to: CGPoint(x: x, y: dlY)); ulPath.move(to: CGPoint(x: x, y: ulY)) } else { dlPath.addLine(to: CGPoint(x: x, y: dlY)); ulPath.addLine(to: CGPoint(x: x, y: ulY)) }
            }
            var dlArea = dlPath; dlArea.addLine(to: CGPoint(x: CGFloat(history.count - 1) * stepX, y: size.height)); dlArea.addLine(to: CGPoint(x: 0, y: size.height)); dlArea.closeSubpath()
            context.fill(dlArea, with: .color(.cyan.opacity(0.3)))
            var ulArea = ulPath; ulArea.addLine(to: CGPoint(x: CGFloat(history.count - 1) * stepX, y: size.height)); ulArea.addLine(to: CGPoint(x: 0, y: size.height)); ulArea.closeSubpath()
            context.fill(ulArea, with: .color(.green.opacity(0.3)))
            context.stroke(dlPath, with: .color(.cyan), lineWidth: 1.0)
            context.stroke(ulPath, with: .color(.green), lineWidth: 1.0)
        }
        .frame(width: 30, height: 16).cornerRadius(3)
    }
}
