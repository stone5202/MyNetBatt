import SwiftUI
import AppKit

// MARK: - 設定頁
struct SettingsDetailView: View {
    @Bindable var monitor: SystemMonitor
    @State private var confirmsUsageReset = false
    @State private var confirmsBatteryReset = false
    @State private var confirmsHealthReset = false
    @State private var confirmsTotalsReset = false

    var body: some View {
        Form {
            Section("外觀") {
                Picker("主題", selection: $monitor.appearanceMode) {
                    Text("自動").tag(0)
                    Text("淺色").tag(1)
                    Text("深色").tag(2)
                }
                .pickerStyle(.segmented)

                LabeledContent("強調色") {
                    HStack(spacing: 8) {
                        ForEach(SystemMonitor.accentPalette.indices, id: \.self) { index in
                            Circle()
                                .fill(SystemMonitor.accentPalette[index].color)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: monitor.accentColorIndex == index ? 2 : 0).padding(-3))
                                .onTapGesture { monitor.accentColorIndex = index }
                                .help(SystemMonitor.accentPalette[index].name)
                        }
                    }
                }
            }

            Section("選單列－網路") {
                Toggle("啟用網路模組", isOn: $monitor.showNetModule)
                Toggle("流量圖表", isOn: $monitor.showNetChart)
                Toggle("即時速度", isOn: $monitor.showNetSpeed)
                Picker("網速顯示", selection: $monitor.netSpeedStyle) {
                    Text("上傳＋下載").tag(0)
                    Text("僅上傳").tag(1)
                    Text("僅下載").tag(2)
                }
                Picker("網速寬度", selection: $monitor.netBarCompact) {
                    Text("寬").tag(false)
                    Text("窄").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("顯示箭頭", isOn: $monitor.showNetArrow)
            }

            Section("選單列－電池") {
                Toggle("啟用電池模組", isOn: $monitor.showBatModule)
                Toggle("圖示", isOn: $monitor.showBatIcon)
                Toggle("百分比", isOn: $monitor.showBatText)
                Toggle("電池圖示使用系統尺寸", isOn: $monitor.batIconLarge)
                LabeledContent("圖示顏色") {
                    HStack(spacing: 8) {
                        ForEach(SystemMonitor.batteryColorOptions.indices, id: \.self) { index in
                            Circle()
                                .fill(SystemMonitor.batteryColorOptions[index])
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                .overlay(Circle().stroke(monitor.accentColor, lineWidth: monitor.selectedColorIndex == index ? 2 : 0).padding(-3))
                                .onTapGesture { monitor.selectedColorIndex = index }
                        }
                    }
                }
                Stepper(value: $monitor.lowBatteryThreshold, in: 5...50, step: 5) {
                    LabeledContent("低電量提醒") { Text("\(monitor.lowBatteryThreshold)%").monospacedDigit() }
                }
                Picker("溫度單位", selection: $monitor.tempDisplayInFahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("CPU 使用率", isOn: $monitor.showCpuItem)
                Toggle("記憶體使用率", isOn: $monitor.showMemItem)
                Toggle("儲存空間使用率", isOn: $monitor.showDiskItem)
            } header: {
                Text("選單列－系統")
            } footer: {
                Text("點擊這些項目會打開監控中心的「系統效能」頁。")
            }

            Section("小視窗內容") {
                Toggle("網路：累計上傳／下載", isOn: $monitor.popNetShowTotals)
                Toggle("網路：正在使用網路的 App", isOn: $monitor.popNetShowActive)
                Toggle("網路：今日 App 用量", isOn: $monitor.popNetShowAppUsage)
                Toggle("網路：儲存空間", isOn: $monitor.popNetShowDisk)
                Toggle("網路：狀態列顯示開關", isOn: $monitor.popNetShowBarToggles)
                Toggle("電池：過去 48 小時圖表", isOn: $monitor.popBatShowChart)
            }

            Section("懸浮視窗") {
                Toggle("顯示懸浮視窗", isOn: $monitor.showFloatWindow)
                Picker("尺寸", selection: $monitor.floatSize) {
                    Text("小").tag(0)
                    Text("中").tag(1)
                    Text("大").tag(2)
                }
                .pickerStyle(.segmented)
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: $monitor.floatOpacity, in: 0.3...1.0)
                        Text("\(Int((monitor.floatOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("模糊背景", isOn: $monitor.floatBlur)
                Toggle("邊框", isOn: $monitor.floatBorder)
                Toggle("陰影", isOn: $monitor.floatShadow)
                Toggle("顯示網速", isOn: $monitor.floatShowNet)
                Toggle("顯示電量", isOn: $monitor.floatShowBattery)
                Toggle("顯示 CPU 與記憶體", isOn: $monitor.floatShowSystem)
            }

            Section {
                ForEach(HotKeyAction.allCases, id: \.rawValue) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
            } header: {
                Text("鍵盤快捷鍵")
            } footer: {
                Text("按一下後輸入組合鍵（需包含 ⌘、⌥ 或 ⌃）；按 Esc 取消。")
            }

            Section {
                Toggle("低電量通知（剩餘 \(monitor.lowBatteryThreshold)% 時）", isOn: $monitor.notifyLowBattery)
                Toggle("充滿通知", isOn: $monitor.notifyFullyCharged)
                Toggle("播放提示音", isOn: $monitor.notificationSound)
                if monitor.notificationPermissionDenied {
                    HStack {
                        Label("通知權限已被關閉", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("開啟系統設定") { monitor.openNotificationSettings() }
                    }
                }
            } header: {
                Text("通知")
            } footer: {
                Text("低電量的門檻為上方「選單列－電池」的「低電量提醒」。")
            }

            Section("資料") {
                Toggle("暫停記錄 App 數據用量", isOn: $monitor.usageTrackingPaused)

                LabeledContent("累計上傳／下載量") {
                    Button("重置…", role: .destructive) { confirmsTotalsReset = true }
                }
                .confirmationDialog("確定要重置累計上傳／下載量嗎？", isPresented: $confirmsTotalsReset) {
                    Button("重置", role: .destructive) { monitor.resetTrafficTotals() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("累計量會從 0 重新計算；重新開機後會回到系統自開機以來的累計值。")
                }

                LabeledContent("電池健康紀錄") {
                    Button("重置…", role: .destructive) { confirmsHealthReset = true }
                }
                .confirmationDialog("確定要重置電池健康紀錄嗎？", isPresented: $confirmsHealthReset) {
                    Button("重置", role: .destructive) { monitor.resetBatteryHealthLog() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("會清除每天記錄的健康度與循環次數，無法復原。")
                }

                LabeledContent("數據用量與 App 數據用量") {
                    Button("重置…", role: .destructive) { confirmsUsageReset = true }
                }
                .confirmationDialog("確定要重置數據用量嗎？", isPresented: $confirmsUsageReset) {
                    Button("重置", role: .destructive) { monitor.resetAppUsageHistory() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("會清除每個 App 的每日與每月用量紀錄，無法復原。")
                }

                LabeledContent("電量歷史紀錄") {
                    Button("重置…", role: .destructive) { confirmsBatteryReset = true }
                }
                .confirmationDialog("確定要重置電量歷史紀錄嗎？", isPresented: $confirmsBatteryReset) {
                    Button("重置", role: .destructive) { monitor.resetBatteryHistory() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("會清除過去 48 小時的電量趨勢，無法復原。")
                }
            }
        }
        .formStyle(.grouped)
    }
}
