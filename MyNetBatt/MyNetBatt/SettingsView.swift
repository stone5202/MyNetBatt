import SwiftUI
import AppKit

// MARK: - 設定頁
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, windows, notifications, advanced
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: return "一般"
        case .menuBar: return "選單列"
        case .windows: return "小視窗與懸浮視窗"
        case .notifications: return "通知"
        case .advanced: return "進階"
        }
    }
}

struct SettingsDetailView: View {
    @Bindable var monitor: SystemMonitor
    @ObservedObject private var helper = PrivilegedHelperManager.shared
    @State private var confirmsUsageReset = false
    @State private var confirmsBatteryReset = false
    @State private var confirmsHealthReset = false
    @State private var confirmsTotalsReset = false
    @State private var notchMessage: String?
    @State private var notchApplied = NotchWallpaper.isApplied
    @AppStorage("settingsSection") private var section: SettingsSection = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "設定", symbol: MainTab.settings.symbol, color: MainTab.settings.color)
                Picker("分類", selection: $section) {
                    ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.pagePadding)
            .padding(.bottom, 4)

            Form {
                switch section {
                case .general: generalSections
                case .menuBar: menuBarSections
                case .windows: windowSections
                case .notifications: notificationSections
                case .advanced: advancedSections
                }
            }
            .formStyle(.grouped)
            .toggleStyle(SettingsSwitchStyle())
        }
    }

    // MARK: 一般
    @ViewBuilder
    private var generalSections: some View {
        Section {
            LabeledContent("外觀") {
                HStack(spacing: 14) {
                    // appearanceMode：0 自動、1 淺色、2 深色。
                    ForEach([(1, String(localized: "淺色")), (2, String(localized: "深色")), (0, String(localized: "自動"))], id: \.0) { mode, title in
                        ThemeOptionButton(monitor: monitor, mode: mode, title: LocalizedStringKey(title))
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("玻璃質感")
                    Toggle("玻璃質感", isOn: $monitor.glassStyle)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    GlassStylePreview(glass: monitor.glassStyle, frost: monitor.glassFrost)
                    HStack(spacing: 8) {
                        Image(systemName: "square.on.square.dashed")
                        Slider(value: $monitor.glassFrost, in: 0...1).labelsHidden()
                        Image(systemName: "square.fill.on.square.fill")
                    }
                    .foregroundStyle(.secondary)
                    .disabled(!monitor.glassStyle)
                    .help("霧化程度：往左較通透，往右較霧；後方內容始終是模糊的")
                }
                .frame(width: 290)
            }
            .help("小視窗、懸浮視窗與監控中心改用系統的玻璃材質，會透出後方的內容")
        }

        Section("主題") {
            LabeledContent("顏色") {
                HStack(spacing: 12) {
                    ForEach(SystemMonitor.accentPalette.indices, id: \.self) { index in
                        let item = SystemMonitor.accentPalette[index]
                        ColorSwatch(color: item.color, name: item.name, ring: item.color, selected: monitor.accentColorIndex == index) {
                            monitor.accentColorIndex = index
                        }
                    }
                }
                // 留出選取色名稱的高度。
                .padding(.bottom, 18)
            }
            Toggle("開機時自動啟動", isOn: $monitor.isAutoStartEnabled)
        }

        Section {
            Picker("語言", selection: $monitor.appLanguage) {
                Text("跟隨系統").tag(0)
                Text(verbatim: "繁體中文").tag(1)
                Text(verbatim: "English").tag(2)
            }
            .pickerStyle(.segmented)
            if monitor.languageNeedsRelaunch {
                HStack {
                    Label("重新啟動 MyNetBatt 後套用新的語言", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即重新啟動") { monitor.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } footer: {
            Text("桌面小工具也會跟著使用這個語言。")
        }

        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if notchApplied {
                        Button("還原原本的桌布") {
                            notchMessage = NotchWallpaper.restore()
                            notchApplied = NotchWallpaper.isApplied
                        }
                    }
                    Button(notchApplied ? "重新產生" : "套用") {
                        notchMessage = NotchWallpaper.apply()
                        notchApplied = NotchWallpaper.isApplied
                    }
                    .buttonStyle(.borderedProminent)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("抹黑劉海")
                    Text(notchApplied ? "已套用：選單列為全黑" : (NotchWallpaper.hasNotch ? "產生一張上緣全黑的桌布，讓劉海和選單列融為一體" : "這台 Mac 的螢幕沒有劉海；套用後主螢幕的選單列會變成全黑"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notchMessage {
                Label(notchMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("劉海")
        } footer: {
            Text("只會改變目前桌面空間的桌布，原本的桌布會記下來，可以隨時還原。更換桌布後再按一次「重新產生」。")
        }

        Section {
            Toggle("隱藏未使用的連接埠", isOn: $monitor.portsHideIdle)
            Toggle("顯示技術細節", isOn: $monitor.portsShowTechDetails)
        } header: {
            Text("連接埠頁")
        } footer: {
            Text("技術細節包括支援的傳輸方式、插拔次數、過電流次數與線材識別碼。選單列的連接埠小視窗只列出使用中的連接埠。")
        }

        Section {
            LabeledContent("加入方式") {
                Text("在桌面上按右鍵 › 編輯小工具，搜尋「MyNetBatt」").foregroundStyle(.secondary)
            }
            LabeledContent("可用的小工具") {
                Text("電池、數據用量、App 數據用量、儲存空間、Wi‑Fi、周邊電量").foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        } header: {
            Text("桌面小工具")
        } footer: {
            Text("在小工具上按右鍵 › 編輯，可以更換主題色；數據用量小工具還能選擇只顯示上傳或下載。")
        }
    }

    // MARK: 選單列
    @ViewBuilder
    private var menuBarSections: some View {
        Section("網路") {
            Toggle("啟用網路模組", isOn: $monitor.showNetModule)
            Toggle("流量圖表", isOn: $monitor.showNetChart)
            Picker("圖表樣式", selection: $monitor.netChartStyle) {
                Text("面積").tag(0)
                Text("上下對稱").tag(1)
                Text("長條").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(!monitor.showNetChart)
            Toggle("加寬圖表（顯示較長的時間）", isOn: $monitor.netChartWide)
                .disabled(!monitor.showNetChart)
            Toggle("即時速度", isOn: $monitor.showNetSpeed)
            VStack(alignment: .leading, spacing: 6) {
                Text("網速樣式")
                ForEach(NetSpeedLabel.styleNames.indices, id: \.self) { style in
                    NetSpeedStyleRow(monitor: monitor, style: style)
                }
            }
            .disabled(!monitor.showNetSpeed)
            Picker("網速寬度", selection: $monitor.netBarCompact) {
                Text("寬").tag(false)
                Text("窄").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("顯示箭頭", isOn: $monitor.showNetArrow)
        }

        Section("電池") {
            Toggle("啟用電池模組", isOn: $monitor.showBatModule)
            Toggle("圖示", isOn: $monitor.showBatIcon)
            Toggle("百分比", isOn: $monitor.showBatText)
            Toggle("電池圖示使用系統尺寸", isOn: $monitor.batIconLarge)
            LabeledContent("圖示顏色") {
                HStack(spacing: 12) {
                    ForEach(SystemMonitor.batteryColorOptions.indices, id: \.self) { index in
                        ColorSwatch(color: SystemMonitor.batteryColorOptions[index], name: nil, ring: monitor.accentColor, selected: monitor.selectedColorIndex == index) {
                            monitor.selectedColorIndex = index
                        }
                    }
                }
            }
            LabeledContent("圖示變紅的電量") {
                HStack(spacing: 8) {
                    Text("\(monitor.lowBatteryThreshold)%").monospacedDigit()
                    Stepper("圖示變紅的電量", value: $monitor.lowBatteryThreshold, in: 5...50, step: 5).labelsHidden()
                }
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
            Text("系統")
        } footer: {
            Text("點擊這些項目會打開監控中心的「系統效能」頁。")
        }

        Section {
            Toggle("連接埠狀態", isOn: $monitor.showPortsItem)
            LabeledContent("圖示") {
                Picker("圖示", selection: $monitor.portsIconStyle) {
                    ForEach(PortsBarView.symbols.indices, id: \.self) { index in
                        Image(systemName: PortsBarView.symbols[index]).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .disabled(!monitor.showPortsItem)
            Toggle("接上電源時顯示輸入功率", isOn: $monitor.showPortsWatts)
                .disabled(!monitor.showPortsItem)
        } header: {
            Text("連接埠")
        } footer: {
            Text("點擊會顯示各連接埠的連線速度、線材規格與充電狀態；有連接埠被線材限速時，圖示會出現橘色圓點。")
        }
    }

    // MARK: 小視窗與懸浮視窗
    @ViewBuilder
    private var windowSections: some View {
        Section("網路小視窗") {
            Toggle("今日數據用量", isOn: $monitor.popNetShowTotals)
            Toggle("正在使用網路的 App", isOn: $monitor.popNetShowActive)
            Toggle("今日 App 用量", isOn: $monitor.popNetShowAppUsage)
            Toggle("儲存空間", isOn: $monitor.popNetShowDisk)
            Toggle("狀態列顯示開關", isOn: $monitor.popNetShowBarToggles)
        }

        Section("電池小視窗") {
            Toggle("過去 48 小時圖表", isOn: $monitor.popBatShowChart)
            Toggle("周邊裝置電量", isOn: $monitor.popBatShowDevices)
        }

        Section("懸浮視窗") {
            Toggle("顯示懸浮視窗", isOn: $monitor.showFloatWindow)
            Picker("尺寸", selection: $monitor.floatSize) {
                Text("小").tag(0)
                Text("中").tag(1)
                Text("大").tag(2)
            }
            .pickerStyle(.segmented)
            LabeledContent("背景不透明度") {
                HStack {
                    Slider(value: $monitor.floatOpacity, in: 0...1.0)
                    Text("\(Int((monitor.floatOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("模糊背景", isOn: $monitor.floatBlur)
                .disabled(monitor.glassStyle)
                .help(monitor.glassStyle ? "已開啟「外觀」的玻璃質感，懸浮視窗使用玻璃材質" : "")
            Toggle("邊框", isOn: $monitor.floatBorder)
            Toggle("陰影", isOn: $monitor.floatShadow)
            Toggle("顯示網速", isOn: $monitor.floatShowNet)
            Toggle("顯示電量", isOn: $monitor.floatShowBattery)
            Toggle("顯示 CPU 與記憶體", isOn: $monitor.floatShowSystem)
        }
    }

    // MARK: 通知
    @ViewBuilder
    private var notificationSections: some View {
        if monitor.notificationPermissionDenied {
            Section {
                HStack {
                    Label("通知權限已被關閉", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("開啟系統設定") { monitor.openNotificationSettings() }
                }
            }
        }

        Section {
            Toggle("低電量通知", isOn: $monitor.notifyLowBattery)
            LabeledContent("提醒時機") {
                HStack(spacing: 6) {
                    ForEach(SystemMonitor.lowBatteryAlertChoices, id: \.self) { level in
                        LevelChip(level: level, selected: monitor.lowBatteryAlertLevels.contains(level), tint: monitor.accentColor) {
                            if monitor.lowBatteryAlertLevels.contains(level) {
                                // 至少保留一個提醒時機。
                                if monitor.lowBatteryAlertLevels.count > 1 { monitor.lowBatteryAlertLevels.remove(level) }
                            } else {
                                monitor.lowBatteryAlertLevels.insert(level)
                            }
                        }
                    }
                }
            }
            .disabled(!monitor.notifyLowBattery)
        } header: {
            Text("電池")
        } footer: {
            Text("使用電池時，電量每降到一個選取的百分比就提醒一次；接上電源後重新計算。")
        }

        Section {
            Toggle("充滿通知", isOn: $monitor.notifyFullyCharged)
            Toggle("電池高溫通知（\(monitor.highTemperatureLabel) 以上）", isOn: $monitor.notifyHighTemperature)
            Toggle("健康度下降通知", isOn: $monitor.notifyHealthDrop)
            Toggle("耗電暴增通知（使用電池時持續一分鐘）", isOn: $monitor.notifyPowerSurge)
            LabeledContent("耗電暴增門檻") {
                HStack(spacing: 8) {
                    Text("\(monitor.powerSurgeThreshold) W").monospacedDigit()
                    Stepper("耗電暴增門檻", value: $monitor.powerSurgeThreshold, in: 10...80, step: 5).labelsHidden()
                }
            }
            .disabled(!monitor.notifyPowerSurge)
            Toggle("睡眠耗電偏高通知", isOn: $monitor.notifySleepDrain)
            Toggle("周邊裝置電量低於 10% 通知", isOn: $monitor.notifyPeripheralLow)
        }

        Section {
            Toggle("連接埠接上或拔除時通知", isOn: $monitor.notifyPortChanges)
        } header: {
            Text("連接埠")
        } footer: {
            Text("接上時說明連線速度與線材規格；線材限制了速度時會播放提示音。")
        }

        Section("提示音") {
            Toggle("播放提示音", isOn: $monitor.notificationSound)
            LabeledContent("音效") {
                HStack(spacing: 8) {
                    Picker("音效", selection: $monitor.notificationSoundName) {
                        ForEach(BatteryNotifier.soundChoices, id: \.self) { name in
                            Text(name.isEmpty ? String(localized: "系統預設") : name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        if monitor.notificationSoundName.isEmpty {
                            NSSound.beep()
                        } else {
                            NSSound(named: NSSound.Name(monitor.notificationSoundName))?.play()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("試聽")
                }
            }
            .disabled(!monitor.notificationSound)
        }
    }

    // MARK: 進階
    @ViewBuilder
    private var advancedSections: some View {
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
            Toggle("電量偏低時自動開啟", isOn: $monitor.autoLowPowerMode)
            LabeledContent("開啟門檻") {
                HStack(spacing: 8) {
                    Text("\(monitor.autoLowPowerThreshold)%").monospacedDigit()
                    Stepper("開啟門檻", value: $monitor.autoLowPowerThreshold, in: 10...80, step: 5).labelsHidden()
                }
            }
            .disabled(!monitor.autoLowPowerMode)
            if monitor.autoLowPowerMode, helper.registrationState != .enabled {
                Label("尚未啟用 Helper，請先到「電池」頁切換一次低耗電模式完成啟用。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("低耗電模式自動化")
        } footer: {
            Text("使用電池且電量降到門檻時開啟低耗電模式；接上電源後，會關閉由這個功能開啟的低耗電模式。")
        }

        Section {
            Picker("數據用量顯示", selection: $monitor.usageGrouping) {
                Text("僅 App").tag(0)
                Text("App 與程序").tag(1)
            }
            .pickerStyle(.segmented)
            Toggle("暫停記錄 App 數據用量", isOn: $monitor.usageTrackingPaused)
        } header: {
            Text("數據用量")
        } footer: {
            Text("Helper 等附屬程序的流量會算在所屬的 App 上。選「僅 App」時，系統服務與指令列工具合併顯示為「其他程序」。")
        }

        Section("資料") {
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
}

/// 百分比的選取標籤（低電量提醒時機）。
private struct LevelChip: View {
    let level: Int
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(level)%")
                .font(.callout.weight(selected ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? tint : Color.secondary.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 網速樣式的一個選項：左邊是選單列實際顯示的樣子（即時數值），右邊是名稱與勾選標記。
private struct NetSpeedStyleRow: View {
    @Bindable var monitor: SystemMonitor
    let style: Int

    var body: some View {
        let selected = monitor.netSpeedStyle == style
        Button {
            monitor.netSpeedStyle = style
        } label: {
            HStack(spacing: 10) {
                NetSpeedLabel(monitor: monitor, style: style)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(NetSpeedLabel.styleNames[style]).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
                // 大小比照右側的開關，和其他列的控制項對齊。
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? monitor.accentColor : Color.secondary.opacity(0.4))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 外觀的一個選項：仿系統設定的縮圖（桌布、選單列、選取色與一個視窗），下方是名稱；「自動」左半淺色、右半深色。
private struct ThemeOptionButton: View {
    @Bindable var monitor: SystemMonitor
    let mode: Int
    let title: LocalizedStringKey

    private static let size = CGSize(width: 76, height: 50)

    var body: some View {
        let selected = monitor.appearanceMode == mode
        Button {
            monitor.appearanceMode = mode
        } label: {
            VStack(spacing: 5) {
                thumbnail
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    // 選取框和縮圖之間留一圈空隙，和系統設定一樣。
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(monitor.accentColor, lineWidth: selected ? 3 : 0))
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch mode {
        case 1: scene(dark: false)
        case 2: scene(dark: true)
        default:
            ZStack {
                scene(dark: false)
                scene(dark: true)
                    .mask(alignment: .trailing) { Rectangle().frame(width: Self.size.width / 2) }
            }
        }
    }

    /// 桌布、選單列、左上的選取色塊，以及右下方露出一角、帶紅黃綠按鈕的視窗。
    private func scene(dark: Bool) -> some View {
        let panel = dark ? Color(red: 0.13, green: 0.14, blue: 0.18) : Color(white: 0.96)
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: dark ? [Color(red: 0.20, green: 0.16, blue: 0.62), Color(red: 0.06, green: 0.10, blue: 0.42)]
                             : [Color(red: 0.55, green: 0.80, blue: 0.98), Color(red: 0.16, green: 0.42, blue: 0.90)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // 桌布上的斜向光帶。
            Capsule()
                .fill(Color.white.opacity(dark ? 0.12 : 0.35))
                .frame(width: 130, height: 12)
                .rotationEffect(.degrees(-32))
                .offset(x: -20, y: 26)
            Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(monitor.accentColor)
                .frame(width: 34, height: 9)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .offset(x: 6, y: 12)
            HStack(spacing: 3) {
                ForEach([Color.red, Color.yellow, Color.green], id: \.self) { color in
                    Circle().fill(color).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, 7)
            .frame(width: 50, height: 30, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .offset(x: Self.size.width - 40, y: Self.size.height - 22)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// 玻璃質感的預覽：風景上浮著一排工具列按鈕，開啟時按鈕是透出後方的玻璃，關閉時是不透明的底色。
private struct GlassStylePreview: View {
    let glass: Bool
    let frost: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.62, blue: 0.93), Color(red: 0.70, green: 0.85, blue: 0.97)],
                startPoint: .top, endPoint: .bottom
            )
            Circle().fill(Color.white.opacity(0.85)).frame(width: 46, height: 46).offset(x: -70, y: 34)
            Circle().fill(Color.white.opacity(0.75)).frame(width: 60, height: 60).offset(x: -34, y: 40)
            Ellipse().fill(Color(red: 0.24, green: 0.50, blue: 0.20)).frame(width: 260, height: 90).offset(x: -90, y: 62)
            Ellipse().fill(Color(red: 0.36, green: 0.62, blue: 0.26)).frame(width: 280, height: 80).offset(x: 80, y: 78)

            HStack(spacing: 8) {
                pill {
                    Image(systemName: "square.and.arrow.up")
                    Image(systemName: "ellipsis")
                }
                pill { Image(systemName: "square.on.square") }
                pill {
                    Image(systemName: "magnifyingglass")
                    Text("搜尋").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(10)
        }
        .frame(width: 290, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.2), value: glass)
        .accessibilityHidden(true)
    }

    /// 這裡用材質而不用 glassEffect：設定頁上出現玻璃元件時，系統會把整頁背景提亮。
    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background {
                if glass {
                    // 和監控中心同一種做法：模糊不變，只改變壓在上面的底色濃度。
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill((colorScheme == .dark ? Color.black : Color.white).opacity(frost * 0.75))
                } else {
                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(glass ? 0.5 : 0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

/// 顏色選項的圓點：選取時外圍多一圈環，有名稱時顯示在下方（和系統設定的「顏色」相同）。
private struct ColorSwatch: View {
    let color: Color
    let name: String?
    let ring: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(ring, lineWidth: selected ? 2.5 : 0))
                .overlay(alignment: .bottom) {
                    if selected, let name {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(y: 17)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name ?? "")
        .accessibilityLabel(name ?? String(localized: "顏色"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 設定頁的開關：標題在左、小尺寸的開關靠右，和系統設定一致。
private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        } label: {
            configuration.label
        }
    }
}
