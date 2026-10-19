import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchDynamicBatteryInfo() {
        lastBatterySampleTime = Date()
        runExclusive("dynamicBattery") {
            // 直接讀 IOKit 屬性，取代每 1.5 秒 spawn 一次 ioreg 並對整段文字做 regex。
            let batteryProperties = SystemReaders.smartBatteryPropertySets()

            func number(_ keys: [String]) -> Int64? {
                for key in keys {
                    // 負的電流以 64 位元數值儲存，int64Value 會還原成正確的負數。
                    if let value = SystemReaders.lookup(key, in: batteryProperties) as? NSNumber {
                        return value.int64Value
                    }
                }
                return nil
            }

            func boolValue(_ key: String) -> Bool? {
                (SystemReaders.lookup(key, in: batteryProperties) as? NSNumber)?.boolValue
            }

            func validMinutes(_ value: Int64?) -> Int? {
                guard let value, value > 0, value < 65_535 else { return nil }
                return Int(value)
            }

            func formatMinutes(_ minutes: Int) -> String {
                let h = minutes / 60
                let m = minutes % 60
                if h > 0 { return String(format: "%d:%02d", h, m) }
                return String(format: "0:%02d", m)
            }

            // pmset 只在 IOKit 缺少欄位時當備援，需要時才執行一次。
            var cachedPmOutput: String?
            func pmOutput() -> String {
                if let cachedPmOutput { return cachedPmOutput }
                let output = self.runCommand("/usr/bin/pmset", ["-g", "batt"])
                cachedPmOutput = output
                return output
            }

            let tempCharging = boolValue("IsCharging")
                ?? pmOutput().localizedCaseInsensitiveContains("; charging;")
            let tempPlugged = boolValue("ExternalConnected")
                ?? pmOutput().localizedCaseInsensitiveContains("AC Power")
            let tempPct: Int? = {
                if let state = number(["CurrentCapacity"]), state > 0, state <= 100 {
                    return Int(state)
                }
                if let value = self.extract(pattern: "(\\d+)%", from: pmOutput()),
                   let percentage = Int(value), percentage > 0, percentage <= 100 {
                    return percentage
                }
                return nil
            }()

            // ioreg and pmset can both be temporarily unavailable while macOS is
            // waking. A missing sample is not a real 0% battery reading, so leave
            // the last good UI value and history untouched until the next poll.
            guard let tempPct else { return }

            let batType = tempPlugged ? String(localized: "變壓器 (AC)") : String(localized: "電池供電")

            let rawCurrentCapacity = number(["AppleRawCurrentCapacity"]).map(Double.init) ?? 0
            let rawMaxCapacity = number(["AppleRawMaxCapacity"]).map(Double.init) ?? 0

            let voltageMv = number(["AppleRawBatteryVoltage", "Voltage"]).map(Double.init) ?? 0
            var currentMa = number(["InstantAmperage"]) ?? 0
            if currentMa == 0, let avgCurrent = number(["Amperage"]) {
                currentMa = avgCurrent
            }

            var timeRemain = String(localized: "計算中...")
            if tempPlugged {
                if tempPct >= 100 {
                    timeRemain = String(localized: "已充滿")
                } else if tempCharging {
                    if let mins = validMinutes(number(["AvgTimeToFull"])) {
                        timeRemain = formatMinutes(mins)
                    } else if rawMaxCapacity > rawCurrentCapacity, currentMa > 0 {
                        let minutes = Int(((rawMaxCapacity - rawCurrentCapacity) / Double(currentMa)) * 60.0)
                        timeRemain = minutes > 0 && minutes < 24 * 60 ? formatMinutes(minutes) : String(localized: "計算中...")
                    } else if let t = self.extract(pattern: "(\\d+:\\d+) until full", from: pmOutput()) {
                        timeRemain = t
                    }
                } else {
                    timeRemain = String(localized: "暫停充電")
                }
            } else {
                if let mins = validMinutes(number(["TimeRemaining"]))
                    ?? validMinutes(number(["InstantTimeToEmpty"]))
                    ?? validMinutes(number(["AvgTimeToEmpty"])) {
                    timeRemain = formatMinutes(mins)
                } else if rawCurrentCapacity > 0, currentMa < 0 {
                    let minutes = Int((rawCurrentCapacity / abs(Double(currentMa))) * 60.0)
                    timeRemain = minutes > 0 && minutes < 24 * 60 ? formatMinutes(minutes) : String(localized: "計算中...")
                } else if let t = self.extract(pattern: "(\\d+:\\d+) remaining", from: pmOutput()) {
                    timeRemain = t
                }
            }

            let signedBatteryWatts = (voltageMv * Double(currentMa)) / 1_000_000.0
            let displayedWatts: Double
            if tempPlugged {
                displayedWatts = tempCharging ? max(0, signedBatteryWatts) : 0
            } else {
                displayedWatts = abs(signedBatteryWatts)
            }
            let wattsStr = (voltageMv > 0 && currentMa != 0) || tempPlugged
                ? String(format: "%.2f W", displayedWatts)
                : "--"

            var tempStr = "--"
            var foundTempDouble = 0.0
            let rawTemperature = number(["Temperature", "BatteryTemperature", "VirtualTemperature", "BatteryTemp", "AverageTemperature"])

            if let rawTemp = rawTemperature {
                let v = Double(rawTemp)
                let candidates: [Double] = [v / 100.0, v / 10.0, v, v / 1000.0]
                if let celsius = candidates.first(where: { $0 >= 5 && $0 <= 80 }) {
                    foundTempDouble = celsius
                    tempStr = String(format: "%.1f°C", celsius)
                }
            }

            var cycle: String?
            if let c = number(["CycleCount"]), c >= 0 {
                cycle = String(c)
            }

            var tIcon = "battery.100"
            // 接著電源就顯示閃電：充滿或最佳化充電暫停時 IsCharging 為 false，但仍在使用外部電源。
            if tempPlugged {
                tIcon = "battery.100.bolt"
            } else if tempPct > 80 {
                tIcon = "battery.100"
            } else if tempPct > 60 {
                tIcon = "battery.75"
            } else if tempPct > 35 {
                tIcon = "battery.50"
            } else if tempPct > 15 {
                tIcon = "battery.25"
            } else {
                tIcon = "battery.0"
            }

            let fSource = tempCharging ? String(localized: "充電中") : (tempPlugged ? String(localized: "已接上電源") : String(localized: "放電中"))
            let fStatus = "\(tempPct)"
            let fIcon = tIcon
            let fTemp = tempStr
            let fWatts = wattsStr
            let fPct = tempPct
            let fCycle = cycle
            let fType = batType
            let fTime = timeRemain
            let fTempD = foundTempDouble
            let isChg = tempCharging
            let isPlugged = tempPlugged
            let fSignedWatts = signedBatteryWatts

            // 供電細節：這些鍵在別的子字典裡有同名項目（例如 BatteryPower、Current），所以先取出各自的字典再讀。
            let telemetry = SystemReaders.lookup("PowerTelemetryData", in: batteryProperties) as? [String: Any] ?? [:]
            let adapter = SystemReaders.lookup("AdapterDetails", in: batteryProperties) as? [String: Any] ?? [:]
            func milli(_ dict: [String: Any], _ key: String) -> Double? {
                guard let value = (dict[key] as? NSNumber)?.doubleValue, value > 0 else { return nil }
                return value / 1000.0
            }
            var fAdapterRating = "--", fPowerIn = "--", fSystemLoad = "--", fAdapterDetail = ""
            if tempPlugged {
                if let rated = (adapter["Watts"] as? NSNumber)?.intValue, rated > 0 { fAdapterRating = "\(rated) W" }
                if let powerIn = milli(telemetry, "SystemPowerIn") { fPowerIn = String(format: "%.1f W", powerIn) }
                if let load = milli(telemetry, "SystemLoad") { fSystemLoad = String(format: "%.1f W", load) }
                var parts: [String] = []
                if let name = adapter["Name"] as? String, !name.isEmpty { parts.append(name) }
                if let volts = milli(adapter, "AdapterVoltage"), let amps = milli(adapter, "Current") {
                    parts.append(String(format: "%.1f V / %.2f A", volts, amps))
                }
                if let loss = milli(telemetry, "AdapterEfficiencyLoss") { let lossText = String(format: "%.1f", loss); parts.append(String(localized: "轉換損耗 \(lossText) W")) }
                fAdapterDetail = parts.joined(separator: String(localized: "，"))
            }
            let supply = (rating: fAdapterRating, powerIn: fPowerIn, load: fSystemLoad, detail: fAdapterDetail)
            let fPowerInWatts = tempPlugged ? (milli(telemetry, "SystemPowerIn") ?? 0) : 0
            let fProfiles = tempPlugged ? SystemReaders.chargerProfiles(from: adapter) : []
            let fTelemetryIn: (volts: Double, amps: Double, time: Int, adapterMV: Int)? = tempPlugged ? {
                guard let mv = (telemetry["SystemVoltageIn"] as? NSNumber)?.doubleValue,
                      let ma = (telemetry["SystemCurrentIn"] as? NSNumber)?.doubleValue,
                      let time = (SystemReaders.lookup("UpdateTime", in: batteryProperties) as? NSNumber)?.intValue else { return nil }
                return (mv / 1000, ma / 1000, time, (adapter["AdapterVoltage"] as? NSNumber)?.intValue ?? 0)
            }() : nil
            let fContracts = PortPower.contractFingerprint(SystemReaders.lookup("PortControllerInfo", in: batteryProperties) as? [[String: Any]] ?? [])
            let fChargeState = ChargeState.evaluate(
                plugged: tempPlugged, charging: tempCharging, percent: tempPct,
                fullyCharged: (SystemReaders.lookup("FullyCharged", in: batteryProperties) as? NSNumber)?.boolValue ?? false,
                batteryWatts: signedBatteryWatts)

            await MainActor.run {
                self.assignIfChanged(\.batteryStatus, fStatus)
                self.assignIfChanged(\.batPct, fPct)
                self.assignIfChanged(\.batteryPowerSource, fSource)
                self.assignIfChanged(\.batSourceType, fType)
                self.assignIfChanged(\.batTimeRemain, fTime)
                self.assignIfChanged(\.batTemp, fTemp)
                self.assignIfChanged(\.batTempDouble, fTempD)
                self.assignIfChanged(\.batWatts, fWatts)
                if let fCycle, !fCycle.isEmpty { self.batCycle = fCycle }
                self.assignIfChanged(\.batteryIcon, fIcon)
                self.assignIfChanged(\.isCharging, isChg)
                let plugChanged = self.isPluggedIn != isPlugged
                self.assignIfChanged(\.isPluggedIn, isPlugged)
                self.assignIfChanged(\.chargerProfiles, fProfiles)
                self.assignIfChanged(\.chargeState, fChargeState)
                if plugChanged { self.refreshPortInfoAfterPlugChange(); self.layoutChanged.send() }
                // 沒有插拔但重新協商了（例如多孔充電器另一孔插上手機），也要更新「目前協商」。
                if let previous = self.lastContractFingerprint, previous != fContracts, !plugChanged { self.fetchPortInfo() }
                self.lastContractFingerprint = fContracts
                // 充電路徑電阻：換充電器或重新協商（context 改變）會清掉舊樣本。
                if let input = fTelemetryIn {
                    self.resistanceSampler.add(volts: input.volts, amps: input.amps, updateTime: input.time,
                                               context: fContracts + [input.adapterMV])
                    self.assignIfChanged(\.chargePathResistance, self.resistanceSampler.status)
                } else {
                    self.resistanceSampler.reset()
                    self.assignIfChanged(\.chargePathResistance, nil)
                }
                self.assignIfChanged(\.powerInWatts, (fPowerInWatts * 10).rounded() / 10)
                self.batterySignedWatts = fSignedWatts
                self.assignIfChanged(\.adapterRating, supply.rating)
                self.assignIfChanged(\.powerInText, supply.powerIn)
                self.assignIfChanged(\.systemLoadText, supply.load)
                self.assignIfChanged(\.adapterDetailText, supply.detail)
                self.evaluateBatteryNotifications()
                self.evaluateAutoLowPowerMode()
                self.finishSleepRecordIfNeeded()
                self.updateChargeSession()

                let now = Date()
                if let last = self.batteryHistory.last {
                    if now.timeIntervalSince(last.time) >= 60 {
                        self.batteryHistory.append(BatteryData(time: now, level: fPct, plugged: isPlugged))
                    }
                } else {
                    self.batteryHistory.append(BatteryData(time: now, level: fPct, plugged: isPlugged))
                }
                if self.batteryHistory.count > 2880 { self.batteryHistory.removeFirst() }
                self.saveBatteryHistory()
                self.publishWidgetSnapshot()
            }
        }
    }
    

    /// 記錄一次充電從開始到結束（充滿、暫停或拔掉電源）的起訖電量與耗時。
    /// App 在充電途中才啟動時，以啟動當下作為起點。
    func updateChargeSession() {
        func format(_ interval: TimeInterval) -> String {
            let minutes = max(0, Int(interval / 60))
            return minutes >= 60 ? String(localized: "\(minutes / 60) 小時 \(minutes % 60) 分") : String(localized: "\(minutes) 分")
        }
        let now = Date()
        if isCharging, isPluggedIn {
            guard let start = chargeSessionStart else {
                chargeSessionStart = now
                chargeSessionStartLevel = batPct
                return
            }
            if batPct > chargeSessionStartLevel {
                let elapsed = format(now.timeIntervalSince(start))
                assignIfChanged(\.chargeSessionText, String(localized: "本次充電：\(chargeSessionStartLevel)% → \(batPct)%，已 \(elapsed)"))
            }
        } else if let start = chargeSessionStart {
            chargeSessionStart = nil
            guard batPct > chargeSessionStartLevel else { return }
            let elapsed = format(now.timeIntervalSince(start))
            let summary = String(localized: "上次充電：\(chargeSessionStartLevel)% → \(batPct)%，用時 \(elapsed)")
            assignIfChanged(\.chargeSessionText, summary)
            UserDefaults.standard.set(summary, forKey: "lastChargeSummary")
        }
    }

    func resetBatteryHistory() {
        batteryHistory.removeAll()
        saveBatteryHistory(force: true)
    }

    /// 48 小時電量紀錄最多 2880 筆，最多每 10 分鐘寫入一次；App 結束時由 AppDelegate 強制寫入。
    func saveBatteryHistory(force: Bool = false) {
        let now = Date()
        if !force, let last = lastBatteryHistorySave, now.timeIntervalSince(last) < 600 { return }
        lastBatteryHistorySave = now
        if let encoded = try? JSONEncoder().encode(batteryHistory) {
            UserDefaults.standard.set(encoded, forKey: "batteryHistory")
        }
    }

    func fetchBatteryHealthInfo() {
        runExclusive("batteryHealth") {
            // Keep macOS Maximum Capacity as the single source of truth.
            // AppleRawMaxCapacity is a fluctuating gauge value and can differ
            // by several percentage points from the health shown by macOS.
            let output = self.runCommand("/usr/sbin/system_profiler", ["SPPowerDataType"])
            var cycle: String?
            var health: String?

            for line in output.components(separatedBy: .newlines) {
                if line.contains("Cycle Count:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value, !value.isEmpty { cycle = value }
                }

                if line.contains("Maximum Capacity:") {
                    let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let value, !value.isEmpty { health = value }
                }
            }

            let finalCycle = cycle
            let finalHealth = health

            await MainActor.run {
                if let finalCycle { self.batCycle = finalCycle }
                if let finalHealth { self.batHealth = finalHealth }
                self.recordBatteryHealth()
            }
        }
    }

    /// 把今天的健康度與循環次數記進長期紀錄；同一天只保留最新的一筆。
    func recordBatteryHealth() {
        guard let health = Int(batHealth.trimmingCharacters(in: CharacterSet(charactersIn: "% "))),
              (1...150).contains(health), let cycles = Int(batCycle) else { return }
        notifyHealthDropIfNeeded(health)
        let entry = BatteryHealthEntry(day: Self.dayKeyFormatter.string(from: Date()), health: health, cycles: cycles)
        if batteryHealthLog.last?.day == entry.day {
            guard batteryHealthLog.last != entry else { return }
            batteryHealthLog[batteryHealthLog.count - 1] = entry
        } else {
            batteryHealthLog.append(entry)
        }
        if batteryHealthLog.count > 730 { batteryHealthLog.removeFirst(batteryHealthLog.count - 730) }
        saveBatteryHealthLog()
    }

    func saveBatteryHealthLog() {
        if let encoded = try? JSONEncoder().encode(batteryHealthLog) {
            UserDefaults.standard.set(encoded, forKey: "batteryHealthLogV1")
        }
    }

    func resetBatteryHealthLog() {
        batteryHealthLog.removeAll()
        saveBatteryHealthLog()
        recordBatteryHealth()
    }
}
