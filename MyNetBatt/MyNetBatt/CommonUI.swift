import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 共用 UI 元件
struct BatteryTemperaturePopoverContent: View {
    @Bindable var monitor: SystemMonitor

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
    @Bindable var monitor: SystemMonitor
    var compact: Bool = false

    private var celsius: Double? { monitor.batTempDouble > 0 ? monitor.batTempDouble : nil }
    private var fahrenheit: Double? { celsius.map { $0 * 9.0 / 5.0 + 32.0 } }

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
                Text(monitor.tempScaleLabels.low).font(.caption2).bold().frame(width: 16, alignment: .trailing)
                TemperatureScaleBar(celsius: celsius)
                Text(monitor.tempScaleLabels.high).font(.caption2).bold().frame(width: 36, alignment: .leading)
            }
            Text("電池溫度").font(.caption).foregroundStyle(.secondary)
        }
        .padding(compact ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(compact ? 8 : 0)
    }
}

/// 25～45°C 的漸層刻度條，圓點標出目前的電池溫度；讀不到溫度時不顯示圓點。
struct TemperatureScaleBar: View {
    let celsius: Double?
    var height: CGFloat = 8

    var body: some View {
        let knob = height + 2
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(height: height)
                if let celsius {
                    let normalized = CGFloat(max(0, min(1, (celsius - 25.0) / 20.0)))
                    Circle().fill(Color.white).overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                        .frame(width: knob, height: knob)
                        .offset(x: normalized * max(0, geo.size.width - knob))
                }
            }
        }
        .frame(height: knob)
    }
}

/// 把值複製到剪貼簿，並短暫顯示打勾作為回饋。
struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(value == "--" || value == "無法取得")
        .help("複製")
    }
}

private struct GlassStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 小視窗內的卡片是否改用玻璃材質；由小視窗的根畫面依設定帶入。
    var glassStyle: Bool {
        get { self[GlassStyleKey.self] }
        set { self[GlassStyleKey.self] = newValue }
    }
}

extension View {
    /// 小視窗的底色：玻璃質感時讓系統的小視窗材質透出來，霧化程度調高（超過預設的 0.6）才逐漸壓上底色。
    @ViewBuilder
    func popoverBackground(glass: Bool, frost: Double) -> some View {
        if glass {
            background(Color(NSColor.windowBackgroundColor).opacity(max(0, frost - 0.6) / 0.4 * 0.85))
        } else {
            background(Color(NSColor.windowBackgroundColor))
        }
    }
}

extension View {
    /// 監控中心裡的卡片底色：半透明的灰底，和設定頁的表單區塊同一種質感。
    /// 這裡不用 glassEffect：頁面上只要有玻璃卡片，系統就會把整頁的背景提亮，
    /// 有卡片的分頁會比設定頁淡一截；玻璃卡片只用在小視窗（WidgetCard）。
    func cardSurface(cornerRadius: CGFloat, fill: Double = 0.08) -> some View {
        background(Color.secondary.opacity(fill)).cornerRadius(cornerRadius)
    }
}

/// 透出視窗後方內容的系統材質；固定為 active，視窗不在最前面時也不會變成不透明的灰底。
struct BehindWindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material }
}

struct WidgetCard<Content: View>: View {
    @Environment(\.glassStyle) private var glassStyle
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        if glassStyle {
            card.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            card
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        }
    }
}


struct InfoBox: View {
    let title: String; let value: String; var icon: String? = nil; var color: Color = .secondary
    var body: some View {
        HStack {
            if let icon = icon { Image(systemName: icon).foregroundColor(color).font(.system(size: 16)) }
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundColor(.secondary); Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8).cardSurface(cornerRadius: 8, fill: 0.1)
    }
}
