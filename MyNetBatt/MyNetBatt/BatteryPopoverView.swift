import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 電池子視窗 (Popover)

struct BatteryPopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject private var helper = PrivilegedHelperManager.shared
    let colorOptions: [Color] = [.primary, .red, .orange, .yellow, .green]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // 第一排
            HStack(spacing: 12) {
                WidgetCard {
                    VStack(alignment: .leading) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(monitor.batPct)")
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .foregroundStyle(monitor.isLowBatteryWarning ? Color.red : Color.primary)
                            Text(" %")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                        Text("剩餘電量").font(.caption).foregroundColor(.secondary)
                        
                        Spacer()
                        ProgressView(value: Double(monitor.batPct), total: 100.0)
                            .tint(monitor.displayedBatteryColor)
                            .scaleEffect(x: 1, y: 1.5, anchor: .center)
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                
                WidgetCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("百分比").font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $monitor.showBatText).labelsHidden().toggleStyle(.switch).tint(.blue).controlSize(.mini)
                        }
                        HStack {
                            Text("圖示").font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $monitor.showBatIcon).labelsHidden().toggleStyle(.switch).tint(.blue).controlSize(.mini)
                        }
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("圖標顏色").font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach(0..<5) { index in
                                Circle()
                                    .fill(colorOptions[index])
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                    .overlay(
                                        Circle().stroke(Color.blue, lineWidth: monitor.selectedColorIndex == index ? 2 : 0).padding(-2)
                                    )
                                    .onTapGesture { monitor.selectedColorIndex = index }
                            }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("低電量提醒").font(.caption)
                                Text("未接電源時顯示紅色")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Stepper(
                                value: $monitor.lowBatteryThreshold,
                                in: 5...50,
                                step: 5
                            ) {
                                Text("\(monitor.lowBatteryThreshold)%")
                                    .monospacedDigit()
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                            .fixedSize()
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            
            // 第二～四排：六個資訊卡固定相同高度、相同間距與主資訊字級
            HStack(spacing: 12) {
                WidgetCard {
                    HStack(spacing: 10) {
                        Image(systemName: "hourglass")
                            .foregroundColor(.blue)
                            .font(.title2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.batTimeRemain)
                                .font(.title3.bold())
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(monitor.batteryTimeTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)

                WidgetCard {
                    HStack(spacing: 10) {
                        Image(systemName: "powerplug.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.batWatts)
                                .font(.title3.bold())
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(monitor.batteryPowerTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)
            }

            HStack(spacing: 12) {
                WidgetCard {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.3.trianglepath")
                            .foregroundColor(.blue)
                            .font(.title2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.batCycle)
                                .font(.title3.bold())
                                .monospacedDigit()
                                .lineLimit(1)
                            Text("循環次數")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)

                WidgetCard {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.title2)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(monitor.batHealth)
                                .font(.title3.bold())
                                .monospacedDigit()
                                .lineLimit(1)
                            Text("健康度")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)
            }

            HStack(spacing: 12) {
                Button {
                    monitor.toggleTemperatureUnit()
                } label: {
                    WidgetCard {
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
                                    .minimumScaleFactor(0.72)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)

                Button {
                    helper.setLowPowerMode(!helper.isLowPowerModeEnabled)
                } label: {
                    WidgetCard {
                        HStack(spacing: 10) {
                            Image(systemName: helper.isLowPowerModeEnabled ? "leaf.fill" : "leaf")
                                .foregroundStyle(helper.isLowPowerModeEnabled ? Color.green : Color.secondary)
                                .font(.title2)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(helper.isLowPowerModeEnabled ? "已開啟" : "已關閉")
                                    .font(.title3.bold())
                                    .lineLimit(1)
                                Text(helper.isBusy ? "正在切換…" : "低耗電模式")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)
                .disabled(helper.isBusy)
                .help("切換 macOS 低耗電模式")
            }

            // 第五排
            WidgetCard {
                Text("過去 48 小時").font(.caption).foregroundColor(.blue).bold()
                Chart {
                    ForEach(monitor.batteryHistory) { data in
                        BarMark(
                            x: .value("時間", data.time),
                            y: .value("電量", data.level)
                        )
                        .foregroundStyle(Color.gray.opacity(0.4))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine()
                        if let val = value.as(Int.self) { AxisValueLabel("\(val)%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 100)
                .padding(.top, 4)
            }
            
            Spacer()
            Divider()
            HStack {
                Button("結束程式") { NSApplication.shared.terminate(nil) }.controlSize(.small)
                Spacer()
                Text("啟用").font(.caption).foregroundColor(.secondary)
                Toggle("", isOn: $monitor.showBatModule).labelsHidden().toggleStyle(.switch).tint(.green).controlSize(.mini)
                Button(action: { NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil) }) {
                    Image(systemName: "gearshape.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
