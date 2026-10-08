import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 電池詳細視窗
struct BatteryDetailView: View {
    @Bindable var monitor: SystemMonitor
    @ObservedObject private var helper = PrivilegedHelperManager.shared

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("電池與電源狀態").font(.largeTitle.bold())
                Spacer()
                lowPowerControl
            }
            
            HStack(spacing: 20) {
                if monitor.isLowBatteryWarning {
                    Image(systemName: monitor.batteryIcon)
                        .resizable().scaledToFit().frame(height: 50)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.red)
                } else if monitor.isPluggedIn {
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
                    Text("\(monitor.batPct)%")
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(monitor.isLowBatteryWarning ? Color.red : Color.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: monitor.batPct)
                    Text(monitor.batteryPowerSource).font(.title3).foregroundColor(.secondary)
                }
                Spacer()
                lowBatteryWarningControl
            }
            .padding(.bottom, 10)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                InfoBox(title: "供電來源", value: monitor.batSourceType, icon: "powerplug.fill", color: .green)
                InfoBox(title: monitor.batteryTimeTitle, value: monitor.batTimeRemain, icon: "hourglass", color: .blue)
                InfoBox(title: "健康度", value: monitor.batHealth, icon: "heart.fill", color: .red)
                InfoBox(title: "循環次數", value: monitor.batCycle, icon: "arrow.3.trianglepath", color: .purple)
                InfoBox(title: "電池溫度", value: monitor.batTempDisplay, icon: "thermometer.medium", color: .orange)
                InfoBox(title: monitor.batteryPowerTitle, value: monitor.batWatts, icon: "bolt.fill", color: .yellow)
                if monitor.isPluggedIn {
                    InfoBox(title: "充電器", value: monitor.adapterRating, icon: "powerplug.portrait.fill", color: .teal)
                    InfoBox(title: "輸入功率", value: monitor.powerInText, icon: "arrow.down.to.line", color: .mint)
                    InfoBox(title: "系統耗電", value: monitor.systemLoadText, icon: "cpu", color: .indigo)
                }
            }

            if monitor.isPluggedIn, !monitor.adapterDetailText.isEmpty {
                Label(monitor.adapterDetailText, systemImage: "powerplug")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            if monitor.isPluggedIn { ChargerCableCard(monitor: monitor) }

            if !monitor.chargeSessionText.isEmpty {
                Label(monitor.chargeSessionText, systemImage: "bolt.badge.clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let error = helper.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    if helper.needsRepair {
                        Button("修復 Helper") {
                            helper.repairHelper()
                        }
                        .controlSize(.small)
                        .disabled(helper.isBusy)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            
            Text("電量變化趨勢").font(.title3.bold()).foregroundColor(.secondary).padding(.top, 16)
            BatteryHistoryChart(history: monitor.batteryHistory, height: 150)

            if !monitor.sleepSummaryText.isEmpty {
                Label(monitor.sleepSummaryText, systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            BatteryHealthLogSection(monitor: monitor)

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
        .onAppear { monitor.setBatteryDetailVisible(true, source: "mainWindow") }
        .onDisappear { monitor.setBatteryDetailVisible(false, source: "mainWindow") }
        .task {
            helper.refreshRegistrationState()
            helper.refreshLowPowerMode()
        }
    }

    @ViewBuilder
    private var lowPowerControl: some View {
        HStack(spacing: 10) {
            Image(systemName: helper.isLowPowerModeEnabled ? "leaf.fill" : "leaf")
                .foregroundStyle(helper.isLowPowerModeEnabled ? Color.green : Color.secondary)

            VStack(alignment: .trailing, spacing: 1) {
                Text("低耗電模式")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(helper.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Toggle("", isOn: Binding(
                get: { helper.isLowPowerModeEnabled },
                set: { helper.setLowPowerMode($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
            .disabled(helper.isBusy)

            if helper.isBusy {
                ProgressView().controlSize(.small)
            }

            if helper.hasLegacyInstall {
                Button("更新 Helper") {
                    helper.registerHelper()
                }
                .controlSize(.small)
                .disabled(helper.isBusy)
                .help("移除舊版安裝方式並改由系統管理 Helper（需輸入一次管理員密碼）")
            } else if helper.registrationState == .notRegistered {
                Button("啟用 Helper") {
                    helper.registerHelper()
                }
                .controlSize(.small)
                .disabled(helper.isBusy)
            } else if helper.registrationState == .requiresApproval {
                Button("開啟系統設定") {
                    helper.openApprovalSettings()
                }
                .controlSize(.small)
            } else if helper.registrationState == .notFound || helper.needsRepair {
                Button("修復 Helper") {
                    helper.repairHelper()
                }
                .controlSize(.small)
                .disabled(helper.isBusy)
            }
        }
        .help("使用受簽章的 Privileged Helper 透過 pmset 控制 macOS 低耗電模式")
    }

    private var lowBatteryWarningControl: some View {
        Stepper(
            value: $monitor.lowBatteryThreshold,
            in: 5...50,
            step: 5
        ) {
            HStack(spacing: 10) {
                Image(systemName: "battery.25")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("低電量提醒")
                    .font(.headline)
                Text("\(monitor.lowBatteryThreshold)%")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
        }
        .fixedSize()
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

/// 每天一筆的健康度與循環次數；累積兩天以上才畫趨勢圖。
struct BatteryHealthLogSection: View {
    @Bindable var monitor: SystemMonitor
    /// 要看的天數；0 代表全部。
    @State private var rangeDays = 90
    @State private var showsAllRows = false

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let health: Int
        let cycles: Int
        /// 與前一筆紀錄相比的變化。
        var healthChange = 0
        var cycleChange = 0
    }

    private static let collapsedRows = 7

    private var points: [Point] {
        var result: [Point] = []
        for entry in monitor.batteryHealthLog {
            guard let date = SystemMonitor.dayKeyFormatter.date(from: entry.day) else { continue }
            var point = Point(id: entry.day, date: date, health: entry.health, cycles: entry.cycles)
            if let previous = result.last {
                point.healthChange = entry.health - previous.health
                point.cycleChange = entry.cycles - previous.cycles
            }
            result.append(point)
        }
        guard rangeDays > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -rangeDays, to: Date()) else { return result }
        return result.filter { $0.date >= cutoff }
    }

    var body: some View {
        let total = monitor.batteryHealthLog.count
        let points = points
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("電池健康紀錄").font(.title3.bold()).foregroundColor(.secondary)
                Spacer()
                Text("已記錄 \(total) 天").font(.caption).foregroundStyle(.secondary)
            }
            Picker("範圍", selection: $rangeDays) {
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("1 年").tag(365)
                Text("全部").tag(0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let first = points.first, let last = points.last, points.count >= 2 {
                Text("\(first.id)：\(first.health)%、\(first.cycles) 次循環 → 目前 \(last.health)%、\(last.cycles) 次循環")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                let lowest = points.map(\.health).min() ?? 100
                Chart(points) { point in
                    LineMark(x: .value("日期", point.date), y: .value("健康度", point.health))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("日期", point.date), y: .value("健康度", point.health))
                        .symbolSize(points.count > 60 ? 0 : 18)
                }
                .foregroundStyle(.red)
                .chartYScale(domain: max(0, min(lowest - 5, 80))...100)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        if let v = value.as(Int.self) { AxisValueLabel("\(v)%") }
                    }
                }
                .chartXAxis {
                    // 一天一筆，刻度以「天」為單位，最多約 6 個。
                    let spanDays = max(1, Int(last.date.timeIntervalSince(first.date) / 86400))
                    AxisMarks(values: .stride(by: .day, count: max(1, spanDays / 5))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .frame(height: 120)
            } else {
                Text("每天會記錄一筆健康度與循環次數，累積兩天以上後顯示趨勢。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !points.isEmpty {
                let rows = Array(points.reversed())
                let visible = showsAllRows ? rows : Array(rows.prefix(Self.collapsedRows))
                VStack(spacing: 0) {
                    ForEach(visible) { point in
                        HStack {
                            Text(point.id).monospacedDigit()
                            Spacer()
                            Label("\(point.health)%\(Self.changeText(point.healthChange, unit: "%"))", systemImage: "heart.fill")
                                .foregroundStyle(point.healthChange < 0 ? Color.orange : Color.primary)
                                .frame(width: 120, alignment: .leading)
                            Label("\(point.cycles) 次\(Self.changeText(point.cycleChange, unit: ""))", systemImage: "arrow.3.trianglepath")
                                .frame(width: 120, alignment: .leading)
                        }
                        .font(.callout)
                        .monospacedDigit()
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        if point.id != visible.last?.id { Divider() }
                    }
                }
                .cardSurface(cornerRadius: 10)

                if rows.count > Self.collapsedRows {
                    Button(showsAllRows ? "只顯示最近 \(Self.collapsedRows) 天" : "顯示全部 \(rows.count) 天") { showsAllRows.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.top, 8)
    }

    /// 與前一筆相同時不顯示；有變化時顯示成「（−1%）」。
    private static func changeText(_ change: Int, unit: String) -> String {
        guard change != 0 else { return "" }
        return "（\(change > 0 ? "+" : "−")\(abs(change))\(unit)）"
    }
}

/// 接上電源時顯示：充電器與線材誰是瓶頸的結論、充電器的各組檔位，以及線材額定規格。
struct ChargerCableCard: View {
    @Bindable var monitor: SystemMonitor

    var body: some View {
        if let verdict = monitor.chargingVerdict {
            VStack(alignment: .leading, spacing: 12) {
                Label("充電器與線材", systemImage: "cable.connector").font(.headline)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: verdict.limited ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(verdict.limited ? Color.orange : Color.green)
                    Text(verdict.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }

                if !monitor.chargerProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("充電器檔位").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(monitor.chargerProfiles) { profile in
                                VStack(spacing: 2) {
                                    Text(Self.trim(profile.volts) + " V").font(.system(size: 14, weight: .semibold, design: .rounded))
                                    Text("\(Self.trim(profile.amps)) A · \(Self.trim(profile.watts)) W").font(.caption2)
                                        .foregroundStyle(profile.isActive ? monitor.accentContrastColor.opacity(0.85) : Color.secondary)
                                }
                                .monospacedDigit()
                                .foregroundStyle(profile.isActive ? monitor.accentContrastColor : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(profile.isActive ? monitor.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .help(profile.isActive ? "目前使用的檔位" : "")
                                .accessibilityLabel("\(Self.trim(profile.volts)) 伏特 \(Self.trim(profile.amps)) 安培\(profile.isActive ? "，目前使用" : "")")
                            }
                        }
                    }
                }

                if let cable = monitor.poweringPort?.cable {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("線材").font(.caption).foregroundStyle(.secondary)
                        Text("額定 \(cable.ratingText) · \(cable.speed)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 14)
        }
    }

    /// 整數不帶小數點，其餘保留到小數兩位（例如 5、2.25）。
    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}
