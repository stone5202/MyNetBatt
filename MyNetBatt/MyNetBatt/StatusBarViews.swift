import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 狀態列視圖
struct NetworkBarView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 4) {
            if monitor.showNetChart { 
                MiniGraphView(history: Array(monitor.trafficHistory.suffix(5)), globalMaxDl: monitor.trafficHistory.map(\.downloadSpeed).max() ?? 1, globalMaxUl: monitor.trafficHistory.map(\.uploadSpeed).max() ?? 1)
            }
            if monitor.showNetSpeed {
                VStack(alignment: .leading, spacing: -2) {
                    Text("↑ \(monitor.upSpeedStr)").foregroundColor(.green)
                    Text("↓ \(monitor.downSpeedStr)").foregroundColor(.cyan)
                }
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .frame(width: 48, alignment: .leading)
            }
        }
        .padding(.horizontal, 2).frame(maxHeight: .infinity)
    }
}

struct BatteryBarView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 2) {
            if monitor.showBatText {
                Text("\(monitor.batPct)%").font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            if monitor.showBatIcon {
                if monitor.isCharging {
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
