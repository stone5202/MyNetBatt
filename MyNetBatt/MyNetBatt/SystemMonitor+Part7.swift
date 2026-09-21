import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchDynamicBatteryInfo() {
        Task.detached {
            let ioText = self.runCommand("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery", "-l", "-w0"])

            func number(_ keys: [String]) -> Int64? {
                for key in keys {
                    let escapedKey = NSRegularExpression.escapedPattern(for: key)
                    if let value = self.extract(
                        pattern: "\\\"\(escapedKey)\\\"\\s*=\\s*(-?[0-9]+)",
                        from: ioText
                    ) {
                        if let signed = Int64(value) { return signed }
                        // ioreg prints negative amperage as its UInt64 bit pattern.
                        if let unsigned = UInt64(value) { return Int64(bitPattern: unsigned) }
                    }
                }
                return nil
            }

            func boolValue(_ key: String) -> Bool? {
                let escapedKey = NSRegularExpression.escapedPattern(for: key)
                guard let value = self.extract(
                    pattern: "\\\"\(escapedKey)\\\"\\s*=\\s*(Yes|No|true|false|1|0)",
                    from: ioText
                )?.lowercased() else { return nil }
                return ["yes", "true", "1"].contains(value)
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

            let pmOutput = self.runCommand("/usr/bin/pmset", ["-g", "batt"])

            let tempCharging = boolValue("IsCharging")
                ?? pmOutput.localizedCaseInsensitiveContains("; charging;")
            let tempPlugged = boolValue("ExternalConnected")
                ?? pmOutput.localizedCaseInsensitiveContains("AC Power")
            let tempPct: Int? = {
                if let state = number(["CurrentCapacity"]), state > 0, state <= 100 {
                    return Int(state)
                }
                if let value = self.extract(pattern: "(\\d+)%", from: pmOutput),
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
            let designCapacity = number(["DesignCapacity"]).map(Double.init) ?? 0

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
                    } else if let t = self.extract(pattern: "(\\d+:\\d+) until full", from: pmOutput) {
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
                } else if let t = self.extract(pattern: "(\\d+:\\d+) remaining", from: pmOutput) {
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
            var rawTemperature = number(["Temperature", "BatteryTemperature", "VirtualTemperature", "BatteryTemp"])
            if rawTemperature == nil {
                let patterns = [
                    "\"Temperature\"\\s*=\\s*([0-9]+)",
                    "\"BatteryTemperature\"\\s*=\\s*([0-9]+)"
                ]
                for pattern in patterns {
                    if let matched = self.extract(pattern: pattern, from: ioText), let value = Int64(matched) {
                        rawTemperature = value
                        break
                    }
                }
            }
            if rawTemperature == nil {
                rawTemperature = number(["AverageTemperature"])
            }

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

            var healthPctStr: String?
            if designCapacity > 0 && rawMaxCapacity > 0 {
                let health = min(100.0, max(0.0, (rawMaxCapacity / designCapacity) * 100.0))
                healthPctStr = String(format: "%.0f%%", health)
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
            let fHealth = healthPctStr
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
                if let fHealth, !fHealth.isEmpty { self.batHealth = fHealth }
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
