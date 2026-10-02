import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func fetchSystemInfo() {
        runExclusive("systemInfo") {
            var cpuModel = SystemReaders.cpuBrand
            if cpuModel.isEmpty { cpuModel = "Apple Silicon Processor" }

            let macModel = SystemReaders.hardwareModel

            let gpuModel = cpuModel.contains("Apple")
                ? "\(cpuModel) GPU"
                : "內建顯示晶片"

            let totalRamGb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let usedRamGb = (SystemReaders.memoryUsedBytes() ?? 0) / 1_073_741_824.0
            let ramStr = String(format: "%.1f GB / %.1f GB", usedRamGb, totalRamGb)
            let rPct = totalRamGb > 0 ? max(0, min(100, (usedRamGb / totalRamGb) * 100.0)) : 0

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

            let swap = SystemReaders.swapUsage()
            let swapUsedBytes = swap?.usedBytes ?? 0
            let swapTotalBytes = swap?.totalBytes ?? 0

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

            // 只有 Mach API 取樣失敗時才退回 top（top -l 2 本身就要 1 秒以上）。
            var cUsage = 0.0
            if let sampled = self.sampleSystemCPUUsage() {
                cUsage = sampled
            } else {
                let topOut = self.runCommand("/usr/bin/top", ["-l", "2", "-n", "0"])
                for line in topOut.components(separatedBy: .newlines).reversed() where line.contains("CPU usage:") {
                    if let idleStr = self.extract(pattern: "([0-9.]+)%\\s*idle", from: line),
                       let idle = Double(idleStr) {
                        cUsage = max(0, min(100, 100.0 - idle))
                        break
                    }
                }
            }

            let gpuUsage = SystemReaders.gpuUtilization() ?? 0.0

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
