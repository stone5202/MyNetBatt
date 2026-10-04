import Foundation
import Darwin
import IOKit

/// 直接透過 sysctl、Mach、IOKit 讀取監控資料，取代每次輪詢都 spawn 子程序
/// （sysctl、vm_stat、netstat、ioreg），降低監控工具本身的耗電。
nonisolated enum SystemReaders {
    // mach_host_self() 每次呼叫都會增加一個 port right 參照，只取一次重複使用以免長期洩漏。
    static let hostPort: mach_port_t = mach_host_self()

    // CPU 型號與機型在執行期間不會改變，只讀一次。
    static let cpuBrand: String = sysctlString("machdep.cpu.brand_string") ?? ""
    static let hardwareModel: String = sysctlString("hw.model") ?? ""

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 開機時間（自 1970 起的秒數）；讀取失敗時為 0。
    static let bootTime: Double = {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return 0 }
        return Double(value.tv_sec)
    }()

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// 記憶體壓力：percent 為 100 減去系統回報的可用百分比（與 memory_pressure 指令相同來源）；
    /// level 為 1 正常、2 警告、4 嚴重。
    static func memoryPressure() -> (percent: Double, level: Int)? {
        guard let free = sysctlInt32("kern.memorystatus_level") else { return nil }
        let level = sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1
        return (Double(max(0, min(100, 100 - free))), Int(level))
    }

    /// 與 vm_stat 相同的計算方式：active + wired + compressor 佔用的頁數。
    static func memoryUsedBytes() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS else { return nil }

        let pages = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return pages * Double(pageSize)
    }

    static func swapUsage() -> (usedBytes: Double, totalBytes: Double)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Double(usage.xsu_used), Double(usage.xsu_total))
    }

    /// 以 IFMIB_IFDATA 讀取介面的 64 位元累計流量，數值與 netstat -ib 一致。
    /// （NET_RT_IFLIST2 對一般權限的程式會把計數取整並截斷，不能用來算流量。）
    static func interfaceByteCounts(namePrefix: String) -> (input: UInt64, output: UInt64)? {
        guard let interfaces = if_nameindex() else { return nil }
        defer { if_freenameindex(interfaces) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var cursor = interfaces
        while cursor.pointee.if_index != 0, let namePointer = cursor.pointee.if_name {
            defer { cursor += 1 }
            guard String(cString: namePointer).hasPrefix(namePrefix) else { continue }

            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(cursor.pointee.if_index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { continue }
            totalIn &+= data.ifmd_data.ifi_ibytes
            totalOut &+= data.ifmd_data.ifi_obytes
        }
        return (totalIn, totalOut)
    }

    /// 讀取 IOAccelerator（Apple Silicon 為其子類別 AGXAccelerator）的 PerformanceStatistics。
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let stats = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            for key in ["Device Utilization %", "Device Utilization % at cur p-state"] {
                if let value = (stats[key] as? NSNumber)?.doubleValue, value >= 0, value <= 100 {
                    return value
                }
            }
            if let raw = (stats["GPU Core Utilization"] as? NSNumber)?.doubleValue, raw >= 0 {
                if raw <= 100 { return raw }
                let pct = raw / 4_294_967_295.0 * 100.0
                if pct <= 100 { return pct }
            }
        }
        return nil
    }

    /// AppleSmartBattery 及其子節點（AppleSmartBatteryPack 等）的屬性，順序與 ioreg -r -c AppleSmartBattery -l 相同；
    /// 溫度、AppleRawMaxCapacity 等欄位只出現在子節點。沒有電池時回傳空陣列。
    static func smartBatteryPropertySets() -> [[String: Any]] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        func properties(of entry: io_registry_entry_t) -> [String: Any]? {
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
                return nil
            }
            return properties?.takeRetainedValue() as? [String: Any]
        }

        var sets: [[String: Any]] = []
        if let root = properties(of: service) { sets.append(root) }

        var iterator: io_iterator_t = 0
        if IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var child = IOIteratorNext(iterator)
            while child != 0 {
                if let childProperties = properties(of: child) { sets.append(childProperties) }
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
        }
        return sets
    }

    /// 依序在每組屬性中先找最上層的 key、再往巢狀字典找，涵蓋範圍與原本對 ioreg 全文做 regex 一致。
    static func lookup(_ key: String, in sets: [[String: Any]]) -> Any? {
        for set in sets {
            if let found = lookup(key, in: set) { return found }
        }
        return nil
    }

    static func lookup(_ key: String, in dict: [String: Any]) -> Any? {
        if let value = dict[key] { return value }
        for value in dict.values {
            if let nested = value as? [String: Any], let found = lookup(key, in: nested) {
                return found
            }
        }
        return nil
    }
}

/// 監聽 USB / Thunderbolt 裝置插拔，讓 system_profiler 只在裝置變動時執行，而不是固定輪詢。
final class DeviceChangeObserver {
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .defaultMode
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        for className in ["IOUSBHostDevice", "IOThunderboltSwitch"] {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(
                    port, notification, IOServiceMatching(className),
                    { refcon, iterator in
                        guard let refcon else { return }
                        MainActor.assumeIsolated {
                            let observer = Unmanaged<DeviceChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
                            DeviceChangeObserver.drain(iterator)
                            observer.onChange()
                        }
                    },
                    context, &iterator
                )
                guard result == KERN_SUCCESS else { continue }
                // 註冊後必須先取完既有項目，通知才會開始觸發；既有裝置不算變動。
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
}
