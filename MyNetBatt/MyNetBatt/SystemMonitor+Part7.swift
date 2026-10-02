import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchDynamicBatteryInfo() {
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

            let batType = tempPlugged ? "變壓器 (AC)" : "電池供電"

            let rawCurrentCapacity = number(["AppleRawCurrentCapacity"]).map(Double.init) ?? 0
            let rawMaxCapacity = number(["AppleRawMaxCapacity"]).map(Double.init) ?? 0

            let voltageMv = number(["AppleRawBatteryVoltage", "Voltage"]).map(Double.init) ?? 0
            var currentMa = number(["InstantAmperage"]) ?? 0
            if currentMa == 0, let avgCurrent = number(["Amperage"]) {
                currentMa = avgCurrent
            }

            var timeRemain = "計算中..."
            if tempPlugged {
                if tempPct >= 100 {
                    timeRemain = "已充滿"
                } else if tempCharging {
                    if let mins = validMinutes(number(["AvgTimeToFull"])) {
                        timeRemain = formatMinutes(mins)
                    } else if rawMaxCapacity > rawCurrentCapacity, currentMa > 0 {
                        let minutes = Int(((rawMaxCapacity - rawCurrentCapacity) / Double(currentMa)) * 60.0)
                        timeRemain = minutes > 0 && minutes < 24 * 60 ? formatMinutes(minutes) : "計算中..."
                    } else if let t = self.extract(pattern: "(\\d+:\\d+) until full", from: pmOutput()) {
                        timeRemain = t
                    }
                } else {
                    timeRemain = "暫停充電"
                }
            } else {
                if let mins = validMinutes(number(["TimeRemaining"]))
                    ?? validMinutes(number(["InstantTimeToEmpty"]))
                    ?? validMinutes(number(["AvgTimeToEmpty"])) {
                    timeRemain = formatMinutes(mins)
                } else if rawCurrentCapacity > 0, currentMa < 0 {
                    let minutes = Int((rawCurrentCapacity / abs(Double(currentMa))) * 60.0)
                    timeRemain = minutes > 0 && minutes < 24 * 60 ? formatMinutes(minutes) : "計算中..."
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
            if tempCharging {
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

            let fSource = tempCharging ? "充電中" : (tempPlugged ? "已接上電源" : "放電中")
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

            await MainActor.run {
                self.batteryStatus = fStatus
                self.batPct = fPct
                self.batteryPowerSource = fSource
                self.batSourceType = fType
                self.batTimeRemain = fTime
                self.batTemp = fTemp
                self.batTempDouble = fTempD
                self.batWatts = fWatts
                if let fCycle, !fCycle.isEmpty { self.batCycle = fCycle }
                self.batteryIcon = fIcon
                self.isCharging = isChg
                self.isPluggedIn = isPlugged

                let now = Date()
                if let last = self.batteryHistory.last {
                    if now.timeIntervalSince(last.time) >= 60 {
                        self.batteryHistory.append(BatteryData(time: now, level: fPct))
                    }
                } else {
                    self.batteryHistory.append(BatteryData(time: now, level: fPct))
                }
                if self.batteryHistory.count > 2880 { self.batteryHistory.removeFirst() }
            }
        }
    }
    
}
