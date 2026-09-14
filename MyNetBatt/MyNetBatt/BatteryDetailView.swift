import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 電池詳細視窗
struct BatteryDetailView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("電池與電源狀態").font(.largeTitle.bold())
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: monitor.isLowPowerModeEnabled ? "leaf.fill" : "leaf")
                        .foregroundStyle(monitor.isLowPowerModeEnabled ? Color.green : Color.secondary)
                    Text("低耗電模式")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(monitor.isLowPowerModeEnabled ? "已開啟" : "已關閉")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(monitor.isLowPowerModeEnabled ? Color.green : Color.secondary)
                        .lineLimit(1)
                }
            }
            
            HStack(spacing: 20) {
                if monitor.isCharging {
                    Image(systemName: monitor.batteryIcon)
                        .resizable().scaledToFit().frame(height: 50)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.primary, .primary, monitor.batteryColor)
                } else {
                    Image(systemName: monitor.batteryIcon)
                        .resizable().scaledToFit().frame(height: 50)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(monitor.batteryColor, .primary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(monitor.batPct)%").font(.system(size: 40, weight: .bold).monospacedDigit())
                    Text(monitor.batteryPowerSource).font(.title3).foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 10)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                InfoBox(title: "供電來源", value: monitor.batSourceType, icon: "powerplug.fill", color: .green)
                InfoBox(title: monitor.batteryTimeTitle, value: monitor.batTimeRemain, icon: "hourglass", color: .blue)
                InfoBox(title: "健康度", value: monitor.batHealth, icon: "heart.fill", color: .red)
                InfoBox(title: "循環次數", value: monitor.batCycle, icon: "arrow.3.trianglepath", color: .purple)
                InfoBox(title: "電池溫度", value: monitor.batTempDisplay, icon: "thermometer.medium", color: .orange)
                InfoBox(title: monitor.batteryPowerTitle, value: monitor.batWatts, icon: "bolt.fill", color: .yellow)
            }
            
            Text("電量變化趨勢").font(.title3.bold()).foregroundColor(.secondary).padding(.top, 16)
            Chart {
                ForEach(monitor.batteryHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("電量", data.level))
                        .foregroundStyle(monitor.batteryColor)
                        .interpolationMethod(.monotone)
                }
            }
            .frame(minHeight: 130).chartYScale(domain: 0...100).chartXAxis(.hidden)
            
            Spacer()
            Divider()
            HStack(spacing: 20) {
                Toggle("啟用電池模組", isOn: $monitor.showBatModule)
                Toggle("狀態列圖示", isOn: $monitor.showBatIcon)
                Toggle("狀態列百分比", isOn: $monitor.showBatText)
                Spacer()
            }
            .toggleStyle(.switch).tint(.green)
        }
        .padding(24)
    }
}
