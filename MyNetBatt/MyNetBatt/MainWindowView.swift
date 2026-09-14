import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 主視窗：側邊欄控制中心
struct MainWindowView: View {
    @ObservedObject var monitor: SystemMonitor
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
                
                List(selection: $selectedTab) {
                    Label("電池狀態", systemImage: "battery.100").tag("battery")
                    Label("網路監控", systemImage: "network").tag("network")
                    Label("系統效能", systemImage: "cpu").tag("system")
                }
                .listStyle(SidebarListStyle())
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
                } else {
                    SystemDetailView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
        .frame(minWidth: 850, minHeight: 650)
    }
}
