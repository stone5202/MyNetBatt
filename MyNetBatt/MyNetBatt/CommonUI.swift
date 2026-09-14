import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 共用 UI 元件
struct BatteryTemperaturePopoverContent: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Button {
            monitor.toggleTemperatureUnit()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.orange)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.batTempDisplay)
                        .font(.title3.bold())
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("電池溫度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BatteryTemperatureGaugeView: View {
    @ObservedObject var monitor: SystemMonitor
    var compact: Bool = false

    private var celsius: Double? { monitor.batTempDouble > 0 ? monitor.batTempDouble : nil }
    private var fahrenheit: Double? { celsius.map { $0 * 9.0 / 5.0 + 32.0 } }
    private var normalized: CGFloat {
        guard let celsius else { return 0 }
        return CGFloat(max(0, min(1, (celsius - 25.0) / 20.0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "thermometer.medium").foregroundStyle(.orange)
                Text(celsius.map { String(format: "%.1f°C", $0) } ?? "--°C")
                    .font(compact ? .headline : .title3.bold()).monospacedDigit()
                Text(fahrenheit.map { String(format: "/ %.1f°F", $0) } ?? "/ --°F")
                    .font(compact ? .caption : .headline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            HStack(spacing: 8) {
                Text("25").font(.caption2).bold()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
                        if celsius != nil {
                            Circle().fill(Color.white).overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                                .frame(width: 10, height: 10)
                                .offset(x: max(0, min(geo.size.width - 10, normalized * (geo.size.width - 10))))
                        }
                    }
                }.frame(height: 8)
                Text("45°C").font(.caption2).bold()
            }
            Text("電池溫度").font(.caption).foregroundStyle(.secondary)
        }
        .padding(compact ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(compact ? 8 : 0)
    }
}

struct WidgetCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}


struct InfoBox: View {
    let title: String; let value: String; var icon: String? = nil; var color: Color = .secondary
    var body: some View {
        HStack {
            if let icon = icon { Image(systemName: icon).foregroundColor(color).font(.system(size: 16)) }
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundColor(.secondary); Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(8)
    }
}
