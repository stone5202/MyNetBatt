import Foundation
import IOKit
import IOKit.ps

// MARK: - 藍牙周邊電量

/// 一個已連線、會回報電量的周邊裝置。AirPods 這類耳機分成左耳、右耳與充電盒三個值。
nonisolated struct PeripheralDevice: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case keyboard, mouse, trackpad, headphones, speaker, gamepad, other }

    var id: String { name }
    let name: String
    let kind: Kind
    /// 單一電量（鍵盤、滑鼠等）；耳機改看 left／right／case。
    var level: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// 列表與選單列用的代表值：耳機取左右耳較低的一個。
    func renamed(_ newName: String) -> PeripheralDevice {
        PeripheralDevice(name: newName, kind: kind, level: level, left: left, right: right, caseLevel: caseLevel)
    }

    var primaryLevel: Int? {
        if let level { return level }
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? caseLevel
    }

    var symbol: String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .headphones:
            let lower = name.lowercased()
            if lower.contains("max") { return "airpodsmax" }
            if lower.contains("pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case .speaker: return "hifispeaker"
        case .gamepad: return "gamecontroller"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

nonisolated enum PeripheralBatteryReader {
    /// system_profiler 的藍牙資料：已連線且有電量欄位的裝置（含 AirPods 左右耳與充電盒、第三方滑鼠）。
    /// 實測約 0.1 秒，但仍是子程序，由呼叫端控制頻率。
    static func readBluetoothProfiler(run: (String, [String]) -> Data) -> [PeripheralDevice] {
        let data = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [PeripheralDevice] = []
        for block in blocks {
            guard let connected = block["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let main = percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"])
                    let left = percent(info["device_batteryLevelLeft"])
                    let right = percent(info["device_batteryLevelRight"])
                    let caseLevel = percent(info["device_batteryLevelCase"])
                    guard main != nil || left != nil || right != nil || caseLevel != nil else { continue }
                    devices.append(PeripheralDevice(
                        name: name, kind: kind(minorType: info["device_minorType"] as? String, name: name),
                        level: main, left: left, right: right, caseLevel: caseLevel
                    ))
                }
            }
        }
        return devices
    }

    /// 妙控鍵盤／滑鼠／觸控板透過 IOKit 回報的電量；不需要子程序，可以頻繁讀取。
    static func readHIDDevices() -> [PeripheralDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [PeripheralDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let level = property(service, "BatteryPercent") as? Int,
                  let name = property(service, "Product") as? String, !name.isEmpty else { continue }
            devices.append(PeripheralDevice(name: name, kind: kind(minorType: nil, name: name), level: max(0, min(100, level))))
        }
        return devices
    }

    /// 系統的配件電源（與 `pmset -g accps` 同一份資料）：藍牙服務整理好的周邊電量，
    /// 含第三方 BLE 滑鼠與 AirPods 左右耳／充電盒。macOS 27 起 system_profiler 與
    /// AppleDeviceManagementHIDEventService 不一定再提供這些裝置的電量，這裡是主要來源。
    static func readAccessoryPowerSources() -> [PeripheralDevice] {
        guard let copyByType = accessorySourcesFunction,
              let blob = copyByType(accessorySourceType)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        return parseAccessorySources(descriptions)
    }

    /// IOPSCopyPowerSourcesByType 沒有公開標頭（pmset 有用到）；4 是配件電源（2026-10-25 在 macOS 27.0.1 實測：
    /// 0＝全部、1／3＝內建電池、4＝只有配件）。找不到函式時回傳 nil，其他來源照常運作。
    private typealias CopySourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let accessorySourceType: Int32 = 4
    private static let accessorySourcesFunction: CopySourcesByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopySourcesByType.self)
    }()

    /// 把配件電源的描述整理成裝置：同一個 Group Identifier（AirPods 本體與充電盒）合成一台，
    /// Combined 的 Combined Parts 拆成左右耳，Part Identifier 為 Case 的是充電盒。
    static func parseAccessorySources(_ sources: [[String: Any]]) -> [PeripheralDevice] {
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for source in sources {
            guard source["Type"] as? String == "Accessory Source",
                  (source["Is Present"] as? Bool) ?? true,
                  let name = source["Name"] as? String, !name.isEmpty else { continue }
            let key = (source["Group Identifier"] as? String) ?? (source["Accessory Identifier"] as? String) ?? name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(source)
        }
        return order.compactMap { key in
            guard let entries = groups[key] else { return nil }
            var level: Int?, left: Int?, right: Int?, caseLevel: Int?
            var name: String?, category: String?
            for entry in entries {
                let part = entry["Part Identifier"] as? String
                let capacity = capacityPercent(entry)
                switch part {
                case "Case":
                    caseLevel = capacity
                case "Left": left = capacity; name = name ?? entry["Name"] as? String
                case "Right": right = capacity; name = name ?? entry["Name"] as? String
                default:
                    name = entry["Name"] as? String
                    category = entry["Accessory Category"] as? String
                    let parts = entry["Combined Parts"] as? [[String: Any]] ?? []
                    for item in parts {
                        switch item["Part Identifier"] as? String {
                        case "Left": left = capacityPercent(item)
                        case "Right": right = capacityPercent(item)
                        case "Case": caseLevel = capacityPercent(item)
                        default: break
                        }
                    }
                    if parts.isEmpty || (left == nil && right == nil) { level = capacity }
                }
                if category == nil, part != "Case" { category = entry["Accessory Category"] as? String }
            }
            if name == nil, let caseName = entries.first?["Name"] as? String {
                // 只有充電盒的資料時，名稱去掉系統加的「 Case」。
                name = caseName.hasSuffix(" Case") ? String(caseName.dropLast(5)) : caseName
                category = category ?? "Headphones"
            }
            guard let name, level != nil || left != nil || right != nil || caseLevel != nil else { return nil }
            return PeripheralDevice(
                name: name, kind: kind(category: category, name: name),
                level: level, left: left, right: right, caseLevel: caseLevel
            )
        }
    }

    private static func capacityPercent(_ entry: [String: Any]) -> Int? {
        guard let current = entry["Current Capacity"] as? Int else { return nil }
        let maximum = entry["Max Capacity"] as? Int ?? 100
        let value = maximum > 0 && maximum != 100 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        return max(0, min(100, value))
    }

    private static func kind(category: String?, name: String) -> PeripheralDevice.Kind {
        switch (category ?? "").lowercased() {
        case "mouse": return .mouse
        case "keyboard": return .keyboard
        case "trackpad": return .trackpad
        case "headset", "headphones", "audio battery case": return .headphones
        case "speaker": return .speaker
        case "game controller", "gamecontroller": return .gamepad
        default: return kind(minorType: category, name: name)
        }
    }

    /// 以名稱合併，後面的來源覆蓋前面的同欄位：system_profiler → 配件電源 → IOKit HID（最即時）。
    /// 配件電源裡有同名的多台裝置（識別碼不同）時，各自保留並在名稱後加「 (2)」等編號；
    /// 其他來源只有名稱、分不出是哪一台，同名的資料不拿來覆蓋。
    static func merge(profiler: [PeripheralDevice], accessories: [PeripheralDevice] = [], hid: [PeripheralDevice]) -> [PeripheralDevice] {
        let counts = Dictionary(accessories.map { ($0.name, 1) }, uniquingKeysWith: +)
        let ambiguous = Set(counts.filter { $0.value > 1 }.keys)
        var seen: [String: Int] = [:]
        let numbered = accessories.map { device -> PeripheralDevice in
            guard ambiguous.contains(device.name) else { return device }
            seen[device.name, default: 0] += 1
            let index = seen[device.name]!
            return index == 1 ? device : device.renamed("\(device.name) (\(index))")
        }
        var byName: [String: PeripheralDevice] = [:]
        let others = { (list: [PeripheralDevice]) in list.filter { !ambiguous.contains($0.name) } }
        for device in others(profiler) + numbered + others(hid) {
            guard var existing = byName[device.name] else { byName[device.name] = device; continue }
            // 新來源帶了左右耳，就整組採用它的（包括總電量），不留下舊來源的總電量蓋住左右耳。
            let hasBuds = device.left != nil || device.right != nil
            existing = PeripheralDevice(
                name: existing.name,
                kind: existing.kind == .other ? device.kind : existing.kind,
                level: hasBuds ? device.level : (device.level ?? existing.level),
                left: hasBuds ? device.left : existing.left,
                right: hasBuds ? device.right : existing.right,
                caseLevel: device.caseLevel ?? existing.caseLevel
            )
            byName[device.name] = existing
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return order(lhs.kind) < order(rhs.kind) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func order(_ kind: PeripheralDevice.Kind) -> Int {
        [.headphones, .keyboard, .mouse, .trackpad, .gamepad, .speaker, .other].firstIndex(of: kind) ?? 9
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return (value as? Int).map { max(0, min(100, $0)) } }
        let digits = text.filter(\.isNumber)
        return Int(digits).map { max(0, min(100, $0)) }
    }

    private static func kind(minorType: String?, name: String) -> PeripheralDevice.Kind {
        let type = (minorType ?? "").lowercased()
        let lower = name.lowercased()
        if type.contains("keyboard") || lower.contains("keyboard") { return .keyboard }
        if type.contains("trackpad") || lower.contains("trackpad") { return .trackpad }
        if type.contains("mouse") || lower.contains("mouse") || lower.contains("mx master") || lower.contains("mx anywhere") { return .mouse }
        if type.contains("headphone") || type.contains("headset") || type.contains("audio") || lower.contains("airpods") || lower.contains("beats") { return .headphones }
        if type.contains("speaker") { return .speaker }
        if type.contains("gamepad") || type.contains("joystick") || lower.contains("controller") { return .gamepad }
        return .other
    }
}
