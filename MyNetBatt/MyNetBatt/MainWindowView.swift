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
    @State private var selectedTab: String? = "battery"
    
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
                if selectedTab == "battery" {
                    BatteryDetailView(monitor: monitor)
                } else if selectedTab == "network" {
                    NetworkDetailView(monitor: monitor)
                } else if selectedTab == "settings" {
                    SettingsDetailView(monitor: monitor)
                } else {
                    SystemDetailView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(selectedTab == "settings" ? 0 : 30)
        }
        .frame(minWidth: 850, minHeight: 650)
        .tint(monitor.accentColor)
    }

    private func sidebarRow(_ title: String, icon: String, tab: String) -> some View {
        let isSelected = selectedTab == tab
        return Button { selectedTab = tab } label: {
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
            .background(isSelected ? monitor.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
