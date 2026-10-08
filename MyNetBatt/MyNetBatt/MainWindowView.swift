import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 主視窗：側邊欄控制中心
struct MainWindowView: View {
    @Bindable var monitor: SystemMonitor
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("控制中心").font(.headline).padding(.horizontal)
                    Spacer()
                }
                .padding(.vertical, 16)
                
                Divider()
                
                // 系統的側邊欄 List 選取色固定跟隨 macOS 的強調色，因此自行繪製選取狀態以套用 App 的強調色。
                VStack(spacing: 4) {
                    sidebarRow("電池狀態", icon: "battery.100", tab: "battery")
                    sidebarRow("網路監控", icon: "network", tab: "network")
                    sidebarRow("系統效能", icon: "cpu", tab: "system")
                    sidebarRow("設定", icon: "gearshape", tab: "settings")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Toggle("開機自啟", isOn: $monitor.isAutoStartEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .padding()
                }
            }
        } detail: {
            Group {
                if monitor.mainWindowTab == "battery" {
                    BatteryDetailView(monitor: monitor)
                } else if monitor.mainWindowTab == "network" {
                    NetworkDetailView(monitor: monitor)
                } else if monitor.mainWindowTab == "settings" {
                    SettingsDetailView(monitor: monitor)
                } else {
                    SystemDetailView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(monitor.mainWindowTab == "settings" ? 0 : 30)
            // 玻璃質感時拿掉設定表單與內容區的不透明底色，露出視窗的玻璃材質。
            .scrollContentBackground(monitor.glassStyle ? .hidden : .automatic)
            .background { if monitor.glassStyle { GlassWindowBackground(frost: monitor.glassFrost).ignoresSafeArea() } }
            // 玻璃質感時標題列是透明的：在標題列的位置再鋪一層材質，捲上去的內容才不會和視窗標題疊在一起。
            .overlay(alignment: .top) {
                if monitor.glassStyle {
                    GeometryReader { geo in
                        GlassWindowBackground(frost: monitor.glassFrost)
                            .frame(height: geo.safeAreaInsets.top)
                            .offset(y: -geo.safeAreaInsets.top)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 850, minHeight: 650)
        .tint(monitor.accentColor)
    }

    private func sidebarRow(_ title: String, icon: String, tab: String) -> some View {
        SidebarRow(monitor: monitor, title: title, icon: icon, tab: tab)
    }
}

/// 側邊欄的一列：選取時填滿 App 的強調色，滑鼠移過時先給一層淡底。
private struct SidebarRow: View {
    @Bindable var monitor: SystemMonitor
    let title: String
    let icon: String
    let tab: String
    @State private var hovering = false

    var body: some View {
        let isSelected = monitor.mainWindowTab == tab
        Button { monitor.mainWindowTab = tab } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? monitor.accentContrastColor : monitor.accentColor)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(isSelected ? monitor.accentContrastColor : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected ? monitor.accentColor : (hovering ? Color.secondary.opacity(0.12) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 監控中心在玻璃質感時的底：透出後方內容的系統材質，再壓一層底色讓文字好讀。
/// 深色材質疊在亮色內容上會變成中灰，卡片外的文字（尤其設定頁沒有卡片襯底）不夠清楚；
/// 四個分頁用同一個程度，切換時背景才一致。
private struct GlassWindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 設定的霧化程度（0～1）；預設 0.6 時深色疊黑 62%、淺色疊白 50%。深色的範圍是 45%～90%。
    let frost: Double

    var body: some View {
        ZStack {
            BehindWindowMaterial()
            if colorScheme == .dark {
                // 深色材質疊在亮色內容上會變成中灰，白字看不清楚，所以最通透時也保留 45% 的黑；
                // 0.6 以下變化較緩，預設值的外觀不變。
                Color.black.opacity(frost < 0.6 ? 0.45 + 0.17 * frost / 0.6 : 0.62 + 0.28 * (frost - 0.6) / 0.4)
            } else {
                Color.white.opacity(0.14 + 0.6 * frost)
            }
        }
    }
}
