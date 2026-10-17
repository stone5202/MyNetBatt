import Foundation
import IOKit

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

    /// 兩個來源以名稱合併；IOKit 的值較即時，優先採用。
    static func merge(profiler: [PeripheralDevice], hid: [PeripheralDevice]) -> [PeripheralDevice] {
        var byName: [String: PeripheralDevice] = [:]
        for device in profiler { byName[device.name] = device }
        for device in hid {
            if var existing = byName[device.name] {
                existing.level = device.level
                byName[device.name] = existing
            } else {
                byName[device.name] = device
            }
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

extension SystemMonitor {
    /// IOKit 每輪都讀；system_profiler 在有畫面顯示周邊電量時每 30 秒、平常每 5 分鐘讀一次。
    static let peripheralProfilerVisibleInterval: TimeInterval = 30
    static let peripheralProfilerBackgroundInterval: TimeInterval = 300

    func startPeripheralMonitor() {
        Task {
            while !Task.isCancelled {
                fetchPeripheralBatteries()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func fetchPeripheralBatteries(forceProfiler: Bool = false) {
        let interval = batteryViewers.isEmpty ? Self.peripheralProfilerBackgroundInterval : Self.peripheralProfilerVisibleInterval
        let needsProfiler = forceProfiler || lastPeripheralProfilerTime.map { Date().timeIntervalSince($0) >= interval - 1 } ?? true
        if needsProfiler { lastPeripheralProfilerTime = Date() }
        let cached = peripheralProfilerCache
        runExclusive("peripherals") {
            let profiler = needsProfiler
                ? PeripheralBatteryReader.readBluetoothProfiler(run: { self.runCommandData($0, $1) })
                : cached
            let merged = PeripheralBatteryReader.merge(profiler: profiler, hid: PeripheralBatteryReader.readHIDDevices())
            await MainActor.run {
                if needsProfiler { self.peripheralProfilerCache = profiler }
                self.assignIfChanged(\.peripherals, merged)
                self.evaluatePeripheralNotifications()
            }
        }
    }

    /// 周邊裝置電量降到 10% 時通知一次，充電回 20% 以上才重新計算；通知關閉時不算已提醒。
    func evaluatePeripheralNotifications() {
        let result = AlertPolicy.peripherals(
            peripherals.map { ($0.name, $0.primaryLevel) }, notified: peripheralLowNotified, enabled: notifyPeripheralLow
        )
        peripheralLowNotified = result.notified
        for name in result.notify {
            let level = peripherals.first { $0.name == name }?.primaryLevel ?? 0
            BatteryNotifier.shared.post(
                id: "peripheral-\(name)", title: String(localized: "周邊裝置電量不足"),
                body: String(localized: "「\(name)」電量剩餘 \(level)%，請記得充電。"),
                sound: notificationSound
            )
        }
    }
}
