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
            }
            
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
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            Text("電量變化趨勢").font(.title3.bold()).foregroundColor(.secondary).padding(.top, 16)
            // 顏色整張圖只算一次，不要在每個資料點（最多 2880 點）重複計算。
            let chartColor = monitor.displayedBatteryColor
            Chart {
                ForEach(monitor.batteryHistory) { data in
                    LineMark(x: .value("時間", data.time), y: .value("電量", data.level))
                        .interpolationMethod(.monotone)
                }
                .foregroundStyle(chartColor)
            }
            .frame(height: 150).chartYScale(domain: 0...100).chartXAxis(.hidden)

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
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

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
