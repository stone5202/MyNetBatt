import SwiftUI
import AppKit

// MARK: - 懸浮視窗
/// 永遠置頂、不搶焦點的小視窗；只在開啟時建立，關閉後釋放，避免隱藏的畫面在背景重算。
final class FloatWindowController {
    private let monitor: SystemMonitor
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private static let topLeftKey = "floatWindowTopLeft"
    /// 尚未有儲存位置時，等內容量出大小後放到主螢幕右上角。
    private var needsDefaultPlacement = false

    init(monitor: SystemMonitor) { self.monitor = monitor }

    /// 依目前設定顯示／隱藏視窗，並套用視窗層級的樣式。
    func update(appearance: NSAppearance?) {
        guard monitor.showFloatWindow else { close(); return }
        let panel = self.panel ?? makePanel()
        panel.alphaValue = monitor.floatOpacity
        panel.appearance = appearance
        if panel.hasShadow != monitor.floatShadow {
            panel.hasShadow = monitor.floatShadow
            panel.invalidateShadow()
        }
        panel.orderFrontRegardless()
    }

    private func close() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        // 視窗大小由內容回報後手動設定；讓 NSHostingController 自動調整視窗大小（preferredContentSize）
        // 在「大」尺寸時會於排版過程中堆疊溢位而當機。
        let rootView = FloatWindowView(monitor: monitor) { [weak self] size in
            DispatchQueue.main.async { self?.resize(to: size) }
        }
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = hosting
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = monitor.floatShadow

        if let saved = UserDefaults.standard.string(forKey: Self.topLeftKey) {
            panel.setFrameTopLeftPoint(NSPointFromString(saved))
            // 螢幕配置改變後，儲存的位置可能已在畫面外。
            needsDefaultPlacement = !NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        } else {
            needsDefaultPlacement = true
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.topLeftKey)
        }

        self.panel = panel
        return panel
    }

    /// 內容大小改變時以左上角為基準調整視窗。
    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let newSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        var topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if needsDefaultPlacement, let visible = NSScreen.main?.visibleFrame {
            needsDefaultPlacement = false
            topLeft = NSPoint(x: visible.maxX - newSize.width - 20, y: visible.maxY - 20)
        } else if newSize == panel.frame.size {
            return
        }
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - newSize.height, width: newSize.width, height: newSize.height), display: true)
        panel.invalidateShadow()
    }
}

struct FloatWindowView: View {
    @Bindable var monitor: SystemMonitor
    var onSizeChange: (CGSize) -> Void = { _ in }

    private var scale: CGFloat { [0.85, 1.0, 1.25][max(0, min(2, monitor.floatSize))] }
    /// 三個區塊都關掉時仍顯示網速，避免出現空白視窗。
    private var showsNet: Bool { monitor.floatShowNet || (!monitor.floatShowBattery && !monitor.floatShowSystem) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
        HStack(spacing: 10 * scale) {
            if showsNet {
                VStack(alignment: .leading, spacing: 1 * scale) {
                    speedRow(symbol: "arrow.up", text: monitor.upSpeedStr, color: .pink)
                    speedRow(symbol: "arrow.down", text: monitor.downSpeedStr, color: .green)
                }
            }
            if monitor.floatShowBattery {
                if showsNet { separator }
                HStack(spacing: 5 * scale) {
                    BatteryGlyph(
                        level: monitor.batPct, fill: monitor.displayedBatteryColor,
                        plugged: monitor.isPluggedIn, height: 11 * scale
                    )
                    Text("\(monitor.batPct)%")
                        .font(.system(size: 12 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(monitor.isLowBatteryWarning ? Color.red : Color.primary)
                }
            }
            if monitor.floatShowSystem {
                if showsNet || monitor.floatShowBattery { separator }
                VStack(alignment: .leading, spacing: 1 * scale) {
                    usageRow(title: "CPU", value: monitor.currentCpuUsage)
                    usageRow(title: "RAM", value: monitor.ramUsagePct)
                }
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background {
            if monitor.floatBlur {
                VisualEffectBackground()
            } else {
                Color(NSColor.windowBackgroundColor)
            }
        }
        .clipShape(shape)
        .overlay { if monitor.floatBorder { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) } }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(monitor.accentColor)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .contextMenu {
            Button("打開監控中心") { NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil) }
            Divider()
            Button("關閉懸浮視窗") { monitor.showFloatWindow = false }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 22 * scale)
    }

    private func speedRow(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 8.5 * scale, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 70 * scale, alignment: .leading)
        }
    }

    private func usageRow(title: String, value: Double) -> some View {
        HStack(spacing: 4 * scale) {
            Text(title)
                .font(.system(size: 8.5 * scale, weight: .bold))
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 11 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 34 * scale, alignment: .trailing)
        }
    }
}

/// 懸浮視窗不會成為作用中視窗；SwiftUI 的 material 在非作用中視窗會變灰，因此固定為 active。
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
