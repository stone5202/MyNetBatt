import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

extension SystemMonitor {
    func toggleTemperatureUnit() {
        tempDisplayInFahrenheit.toggle()
    }
    
    static let batteryColorOptions: [Color] = [.primary, .red, .orange, .yellow, .green]

    func updateBatteryColor() {
        let colors = Self.batteryColorOptions
        if selectedColorIndex >= 0 && selectedColorIndex < colors.count { batteryColor = colors[selectedColorIndex] }
    }
    
    /// 在背景執行取樣；同一個 key 的上一輪還沒完成時直接略過，避免慢的取樣越疊越多。
    func runExclusive(_ key: String, _ work: @escaping @Sendable () async -> Void) {
        guard inFlightFetches.insert(key).inserted else { return }
        Task.detached {
            await work()
            await MainActor.run { _ = self.inFlightFetches.remove(key) }
        }
    }

    nonisolated func runCommand(_ path: String, _ args: [String]) -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        task.environment = env
        let pipe = Pipe(); task.standardOutput = pipe; try? task.run()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    nonisolated func runCommandData(_ path: String, _ args: [String]) -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return Data()
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    nonisolated func extract(pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // 直接向 Mach kernel 取得整台 Mac 的 CPU tick，避免 top/ps 文字格式或語系變動。
    nonisolated func hostCPULoadInfo() -> host_cpu_load_info? {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let info = host_cpu_load_info_t.allocate(capacity: 1)
        defer { info.deallocate() }

        let result = info.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            host_statistics(SystemReaders.hostPort, HOST_CPU_LOAD_INFO, ptr, &count)
        }

        guard result == KERN_SUCCESS else { return nil }
        return info.pointee
    }

    /// 與上一輪取樣的 CPU tick 相減，取得兩次取樣之間（約 2 秒）的平均使用率，不必睡眠等待；
    /// 只有第一次沒有上一輪資料時，才短暫等待 150 毫秒取得基準。
    nonisolated func sampleSystemCPUUsage() -> Double? {
        guard let second = hostCPULoadInfo() else { return nil }
        guard let first = CPUTickHistory.shared.exchange(second) else {
            usleep(150_000)
            return sampleSystemCPUUsage()
        }

        let user = Double(second.cpu_ticks.0 &- first.cpu_ticks.0)
        let system = Double(second.cpu_ticks.1 &- first.cpu_ticks.1)
        let idle = Double(second.cpu_ticks.2 &- first.cpu_ticks.2)
        let nice = Double(second.cpu_ticks.3 &- first.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return max(0, min(100, (user + system + nice) / total * 100.0))
    }

    func startNetworkSpeedMonitor() {
        Task {
            while !Task.isCancelled {
                fetchNetworkTraffic()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // Per-App 網路用量由 startPerAppNetworkMonitor()（SystemMonitor+Scheduling.swift）以 nettop 取樣：網路頁面打開時每 2 秒，關著時每 60 秒。
}

/// 保存上一輪的 CPU tick；取樣在背景執行緒進行，因此以 lock 保護。
nonisolated final class CPUTickHistory: @unchecked Sendable {
    static let shared = CPUTickHistory()
    private let lock = NSLock()
    private var previous: host_cpu_load_info?

    /// 存入這一輪的值並取回上一輪的值。
    func exchange(_ current: host_cpu_load_info) -> host_cpu_load_info? {
        lock.lock()
        defer { lock.unlock() }
        let last = previous
        previous = current
        return last
    }
}
