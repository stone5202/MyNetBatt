import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchSystemInfo() {
        Task.detached {
            var cpuModel = self.runCommand("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cpuModel.isEmpty { cpuModel = "Apple Silicon Processor" }

            let macModel = self.runCommand("/usr/sbin/sysctl", ["-n", "hw.model"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let gpuModel = cpuModel.contains("Apple")
                ? "\(cpuModel) GPU"
                : "內建顯示晶片"

            let totalRamGb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let vmStatOut = self.runCommand("/usr/bin/vm_stat", [])
            var pageSize: Double = 4096
            var activePages = 0.0
            var wiredPages = 0.0
            var compressedPages = 0.0

            if let pageSizeString = self.extract(pattern: "page size of\\s+(\\d+)\\s+bytes", from: vmStatOut),
               let detectedPageSize = Double(pageSizeString) {
                pageSize = detectedPageSize
            }

            for line in vmStatOut.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: ":")
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let valueString = parts[1]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                let value = Double(valueString) ?? 0

                if key == "Pages active" { activePages = value }
                else if key == "Pages wired down" { wiredPages = value }
                else if key == "Pages occupied by compressor" { compressedPages = value }
            }

            let usedRamGb = ((activePages + wiredPages + compressedPages) * pageSize) / 1_073_741_824.0
            let ramStr = String(format: "%.1f GB / %.1f GB", usedRamGb, totalRamGb)
            let rPct = totalRamGb > 0 ? max(0, min(100, (usedRamGb / totalRamGb) * 100.0)) : 0

            func bytesFromSwapValue(_ value: String, unit: String) -> Double {
                guard let number = Double(value) else { return 0 }
                switch unit.uppercased() {
                case "K": return number * 1024
                case "M": return number * 1024 * 1024
                case "G": return number * 1024 * 1024 * 1024
                case "T": return number * 1024 * 1024 * 1024 * 1024
                default: return number
                }
            }

            func formatStorageBytes(_ bytes: Double) -> String {
                if bytes >= 1024 * 1024 * 1024 {
                    return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
                } else if bytes >= 1024 * 1024 {
                    return String(format: "%.1f MB", bytes / (1024 * 1024))
                } else if bytes >= 1024 {
                    return String(format: "%.1f KB", bytes / 1024)
                } else {
                    return String(format: "%.0f B", bytes)
                }
            }

            let swapOut = self.runCommand("/usr/sbin/sysctl", ["vm.swapusage"])
            var swapUsedBytes = 0.0
            var swapTotalBytes = 0.0

            if let usedValue = self.extract(pattern: "used\\s*=\\s*([0-9.]+)([KMGT]?)", from: swapOut) {
                if let regex = try? NSRegularExpression(pattern: "used\\s*=\\s*([0-9.]+)([KMGT]?)", options: .caseInsensitive),
                   let match = regex.firstMatch(in: swapOut, range: NSRange(swapOut.startIndex..., in: swapOut)),
                   let vRange = Range(match.range(at: 1), in: swapOut),
                   let uRange = Range(match.range(at: 2), in: swapOut) {
                    swapUsedBytes = bytesFromSwapValue(String(swapOut[vRange]), unit: String(swapOut[uRange]))
                } else {
                    swapUsedBytes = Double(usedValue) ?? 0
                }
            }

            if let regex = try? NSRegularExpression(pattern: "total\\s*=\\s*([0-9.]+)([KMGT]?)", options: .caseInsensitive),
               let match = regex.firstMatch(in: swapOut, range: NSRange(swapOut.startIndex..., in: swapOut)),
               let vRange = Range(match.range(at: 1), in: swapOut),
               let uRange = Range(match.range(at: 2), in: swapOut) {
                swapTotalBytes = bytesFromSwapValue(String(swapOut[vRange]), unit: String(swapOut[uRange]))
            }

            let swapStr = "\(formatStorageBytes(swapUsedBytes)) / \(formatStorageBytes(swapTotalBytes))"
            let sPct = swapTotalBytes > 0 ? max(0, min(100, (swapUsedBytes / swapTotalBytes) * 100)) : 0

            var dUsedStr = "-- GB"
            var dFreeStr = "-- GB"
            var dTotalStr = "-- GB"
            var dPct = 0.0

            let fileURL = URL(fileURLWithPath: "/")
            if let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
               let total = values.volumeTotalCapacity {
                let availableImportant = values.volumeAvailableCapacityForImportantUsage
                let availableNormal = values.volumeAvailableCapacity
                let available = Double(availableImportant ?? Int64(availableNormal ?? 0))
                let totalD = Double(total)
                let used = max(0, totalD - available)

                dUsedStr = String(format: "%.1f GB", used / 1_000_000_000.0)
                dFreeStr = String(format: "%.1f GB", available / 1_000_000_000.0)
                dTotalStr = String(format: "%.1f GB", totalD / 1_000_000_000.0)
                if totalD > 0 { dPct = max(0, min(100, used / totalD * 100)) }
            }

            let volumeKeys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey
            ]
            var volumes: [StorageVolumeInfo] = []
            if let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(volumeKeys),
                options: [.skipHiddenVolumes]
            ) {
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: volumeKeys),
                          values.volumeIsLocal == true,
                          let total = values.volumeTotalCapacity, total > 0 else { continue }
                    let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0))
                    let total64 = Int64(total)
                    let used = max(0, total64 - available)
                    let isInternal = values.volumeIsInternal ?? (url.path == "/")
                    if isInternal && url.path != "/" { continue }
                    let name = values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                    volumes.append(StorageVolumeInfo(
                        id: url.path, name: name, mountPath: url.path, usedBytes: used,
                        availableBytes: available, totalBytes: total64, isInternal: isInternal
                    ))
                }
            }
            volumes.sort { lhs, rhs in
                if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            var cUsage = self.sampleSystemCPUUsage() ?? 0.0
            if cUsage <= 0.0001 {
                let topOut = self.runCommand("/usr/bin/top", ["-l", "2", "-n", "0"])
                for line in topOut.components(separatedBy: .newlines).reversed() where line.contains("CPU usage:") {
                    if let idleStr = self.extract(pattern: "([0-9.]+)%\\s*idle", from: line),
                       let idle = Double(idleStr) {
                        cUsage = max(0, min(100, 100.0 - idle))
                        break
                    }
                }
            }

            func gpuUsageFromIOReg(className: String) -> Double? {
                let data = self.runCommandData("/usr/sbin/ioreg", ["-a", "-r", "-c", className])
                guard !data.isEmpty,
                      let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                    return nil
                }

                func search(_ object: Any) -> Double? {
                    if let dict = object as? [String: Any] {
                        let directKeys = ["Device Utilization %", "Device Utilization % at cur p-state"]
                        for key in directKeys {
                            if let n = dict[key] as? NSNumber {
                                let v = n.doubleValue
                                if v >= 0 && v <= 100 { return v }
                            }
                        }

                        if let n = dict["GPU Core Utilization"] as? NSNumber {
                            let raw = n.doubleValue
                            if raw >= 0 {
                                if raw <= 100 { return raw }
                                let pct = raw / 4_294_967_295.0 * 100.0
                                if pct >= 0 && pct <= 100 { return pct }
                            }
                        }

                        for value in dict.values {
                            if let found = search(value) { return found }
                        }
                    } else if let array = object as? [Any] {
                        for value in array {
                            if let found = search(value) { return found }
                        }
                    }
                    return nil
                }

                return search(root)
            }

            let gpuUsage = gpuUsageFromIOReg(className: "AGXAccelerator")
                ?? gpuUsageFromIOReg(className: "IOAccelerator")
                ?? 0.0

            let fCpu = cpuModel
            let fMac = macModel
            let fGpu = gpuModel
            let fRam = ramStr
            let fSwap = swapStr
            let fCpuUsage = cUsage
            let fGpuUsage = gpuUsage
            let fRamPct = rPct
            let fSwapPct = sPct
            let fDiskUsed = dUsedStr
            let fDiskFree = dFreeStr
            let fDiskTotal = dTotalStr
            let fDiskPct = dPct
            let fVolumes = volumes
            let fDiskSummary = String(format: "%.1f%% 已使用", dPct)

            await MainActor.run {
                self.cpuModelStr = fCpu
                self.macModelStr = fMac
                self.gpuModelStr = fGpu
                self.ramUsageStr = fRam
                self.ramUsagePct = fRamPct
                self.swapUsageStr = fSwap
                self.swapUsagePct = fSwapPct
                self.diskUsageStr = fDiskSummary
                self.diskUsedStr = fDiskUsed
                self.diskFreeStr = fDiskFree
                self.diskTotalStr = fDiskTotal
                self.diskUsagePct = fDiskPct
                self.storageVolumes = fVolumes
                self.currentCpuUsage = fCpuUsage
                self.currentGpuUsage = fGpuUsage

                self.cpuHistory.append(SimpleData(time: Date(), value: fCpuUsage))
                if self.cpuHistory.count > 60 { self.cpuHistory.removeFirst() }

                self.gpuHistory.append(SimpleData(time: Date(), value: fGpuUsage))
                if self.gpuHistory.count > 60 { self.gpuHistory.removeFirst() }
            }
        }
    }

}
