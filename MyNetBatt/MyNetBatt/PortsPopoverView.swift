import SwiftUI

// MARK: - 連接埠小視窗（選單列）
/// 使用中的連接埠：在傳什麼、誰在限速、線材與顯示器；接著電源時加上充電狀態。
struct PortsPopoverView: View {
    @Bindable var monitor: SystemMonitor
    let openDashboard: () -> Void
    /// 回報卡片區的實際高度，讓小視窗跟著內容伸縮。
    var onContentHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        let active = monitor.portInfos.filter(\.isConnected)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconChip(symbol: MainTab.ports.symbol, color: MainTab.ports.color, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("連接埠").font(.headline)
                    Text(active.isEmpty ? "沒有連接埠在使用" : "\(active.count) 個連接埠使用中")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    monitor.fetchPortInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新整理")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let state = monitor.chargeState {
                        WidgetCard {
                            ChargeStateBanner(state: state, chargerWatts: monitor.chargerMaxWatts)
                            if let verdict = monitor.chargingVerdict {
                                Label(verdict.text, systemImage: verdict.limited ? "exclamationmark.triangle.fill" : "powerplug.fill")
                                    .font(.caption)
                                    .foregroundStyle(verdict.limited ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if active.isEmpty {
                        WidgetCard {
                            Text("接上充電器、線材或裝置後，這裡會顯示連線速度與線材規格。")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(active) { port in
                            WidgetCard { PortRow(port: port) }
                        }
                    }
                }
                // 卡片的陰影會畫到外框外面：在捲動區裡留出邊距，陰影才不會被切掉。
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight($0) }
            }
            .padding(.horizontal, -16)
            .padding(.vertical, -14)
            // 不要系統在捲動區上下緣加的變暗漸層（會在最後一張卡片下面出現一塊灰色）。
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                Text("不在使用中的連接埠不列出").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在監控中心查看", action: openDashboard).controlSize(.small)
            }
        }
        .padding(16)
        .popoverBackground(glass: monitor.glassStyle, frost: monitor.glassFrost)
        .environment(\.glassStyle, monitor.glassStyle)
    }
}
