import Foundation
import IOKit

// MARK: - USB‑C 連接埠、線材與充電器檔位

/// 充電器宣告的一組電壓／電流（USB‑PD 的固定檔位）。
nonisolated struct ChargerProfile: Identifiable, Equatable {
    let id: Int
    let volts: Double
    let amps: Double
    /// Mac 目前協商使用的檔位。
    let isActive: Bool
    var watts: Double { volts * amps }
}

/// 線材內 e‑marker 晶片回報的規格。
nonisolated struct CableInfo: Equatable {
    let vendor: String
    let isActive: Bool
    let speed: String
    let maxVolts: Int
    let amps: Int
    /// 線材額定可承載的功率：支援 EPR 的 5 A 線為 240 W，其餘為 20 V × 額定電流。
    let watts: Int

    var kindText: String { isActive ? "主動式" : "被動式" }
    var ratingText: String { "\(maxVolts) V／\(amps) A (\(watts) W)" }
}

nonisolated struct PortInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let isMagSafe: Bool
    let isConnected: Bool
    /// 對端裝置（充電器、Hub、顯示器…）的廠商；裝置沒有回報時為空字串。
    let partner: String
    let cable: CableInfo?
}

nonisolated extension SystemReaders {
    /// 指定類別所有 IOKit 節點的屬性。
    static func registryProperties(ofClass name: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {
                result.append(dict)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    /// 每個內建連接埠目前的連線狀態，以及接在上面的裝置與線材。
    /// 線材資訊來自 USB‑PD 的 SOP' 回應（e‑marker），沒有晶片的基本線材或 MagSafe 線讀不到。
    static func portInfos() -> [PortInfo] {
        func portKey(_ dict: [String: Any]) -> String {
            let type = dict["ParentPortTypeDescription"] as? String ?? ""
            let number = (dict["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            return "\(type)@\(number)"
        }
        var partners: [String: String] = [:]
        for dict in registryProperties(ofClass: "IOPortTransportComponentCCUSBPDSOP") {
            if let vendor = (dict["Vendor ID"] as? NSNumber)?.intValue, vendor > 0 { partners[portKey(dict)] = vendorName(vendor) }
        }
        var cables: [String: CableInfo] = [:]
        for dict in registryProperties(ofClass: "IOPortTransportComponentCCUSBPDSOPp") {
            if let cable = cableInfo(from: dict) { cables[portKey(dict)] = cable }
        }

        var ports: [PortInfo] = []
        for dict in registryProperties(ofClass: "IOPortTransportStateCC") {
            guard (dict["ParentPortBuiltIn"] as? Bool) != false else { continue }
            let type = dict["ParentPortTypeDescription"] as? String ?? "USB-C"
            let number = (dict["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            let key = portKey(dict)
            let isMagSafe = type.hasPrefix("MagSafe")
            ports.append(PortInfo(
                id: key,
                name: isMagSafe ? type : "USB‑C 連接埠 \(number)",
                isMagSafe: isMagSafe,
                isConnected: dict["Active"] as? Bool ?? false,
                partner: partners[key] ?? "",
                cable: cables[key]
            ))
        }
        // MagSafe 排在最前面，其餘依連接埠編號。
        return ports.sorted { ($0.isMagSafe ? 0 : 1, $0.id) < ($1.isMagSafe ? 0 : 1, $1.id) }
    }

    /// 解讀 Discover Identity 回應裡的線材 VDO（第 4 個 VDO）。
    private static func cableInfo(from dict: [String: Any]) -> CableInfo? {
        let metadata = dict["Metadata"] as? [String: Any] ?? [:]
        guard let raw = metadata["VDOs"] as? [Data], raw.count >= 4, raw[3].count >= 4 else { return nil }
        let vdo = raw[3].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard vdo != 0 else { return nil }

        let productType = (dict["Product Type"] as? NSNumber)?.intValue ?? 3
        let epr = vdo >> 17 & 1 == 1
        let maxVolts = [20, 30, 40, 50][Int(vdo >> 9 & 0b11)]
        let amps = vdo >> 5 & 0b11 == 0b10 ? 5 : 3
        let speeds = ["USB 2.0 (480 Mbps)", "USB 3.2 Gen 1 (5 Gbps)", "USB 3.2 Gen 2 (10 Gbps)", "USB4 Gen 3 (40 Gbps)", "USB4 Gen 4 (80 Gbps)"]
        let speedIndex = Int(vdo & 0b111)
        let vendor = (dict["Vendor ID"] as? NSNumber)?.intValue ?? 0
        return CableInfo(
            vendor: vendor > 0 ? vendorName(vendor) : "",
            isActive: productType == 4,
            speed: speedIndex < speeds.count ? speeds[speedIndex] : "未知速度",
            maxVolts: maxVolts,
            amps: amps,
            watts: epr && amps == 5 ? 240 : amps * 20
        )
    }

    /// 常見廠商的 USB‑IF Vendor ID；不在表內的顯示代碼。
    static func vendorName(_ id: Int) -> String {
        let known: [Int: String] = [
            0x05AC: "Apple", 0x291A: "Anker", 0x050D: "Belkin", 0x04E8: "Samsung", 0x18D1: "Google",
            0x8087: "Intel", 0x17EF: "Lenovo", 0x413C: "Dell", 0x03F0: "HP", 0x045E: "Microsoft",
            0x046D: "Logitech", 0x2B89: "UGREEN", 0x2717: "Xiaomi", 0x12D1: "Huawei", 0x0B05: "ASUS",
            0x1532: "Razer", 0x2188: "CalDigit", 0x0BDA: "Realtek", 0x2109: "VIA Labs", 0x0451: "Texas Instruments",
            0x04B4: "Cypress", 0x2E87: "Injoinic", 0x315C: "ConvenientPower"
        ]
        return known[id] ?? String(format: "廠商代碼 0x%04X", id)
    }

    /// AdapterDetails 裡充電器宣告的各組檔位，依瓦數由小到大。
    static func chargerProfiles(from adapter: [String: Any]) -> [ChargerProfile] {
        guard let menu = adapter["UsbHvcMenu"] as? [[String: Any]] else { return [] }
        let activeIndex = (adapter["UsbHvcHvcIndex"] as? NSNumber)?.intValue
        return menu.compactMap { item -> ChargerProfile? in
            guard let index = (item["Index"] as? NSNumber)?.intValue,
                  let millivolts = (item["MaxVoltage"] as? NSNumber)?.doubleValue, millivolts > 0,
                  let milliamps = (item["MaxCurrent"] as? NSNumber)?.doubleValue, milliamps > 0 else { return nil }
            return ChargerProfile(id: index, volts: millivolts / 1000, amps: milliamps / 1000, isActive: index == activeIndex)
        }
        .sorted { $0.watts < $1.watts }
    }
}

extension SystemMonitor {
    /// 讀一次各連接埠的狀態；只在插拔、畫面打開與低頻率的保底更新時呼叫。
    func fetchPortInfo() {
        runExclusive("portInfo") {
            let snapshot = SystemReaders.portInfos()
            await MainActor.run { self.assignIfChanged(\.portInfos, snapshot) }
        }
    }

    /// 插上線材後 e‑marker 要過一會兒才讀得到，所以隔幾秒再補讀一次。
    func refreshPortInfoAfterPlugChange() {
        fetchPortInfo()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.fetchPortInfo()
        }
    }

    /// 正在供電的那個連接埠：只有一個連接埠有連線時才能確定是它。
    var poweringPort: PortInfo? {
        let connected = portInfos.filter(\.isConnected)
        return connected.count == 1 ? connected.first : nil
    }

    /// 充電器所有檔位裡最高的瓦數；讀不到檔位時用系統回報的額定瓦數。
    var chargerMaxWatts: Int {
        let best = chargerProfiles.map(\.watts).max().map { Int($0.rounded()) } ?? 0
        return max(best, Int(adapterRating.replacingOccurrences(of: " W", with: "")) ?? 0)
    }

    /// 充電器與線材誰是瓶頸的一句結論；`limited` 為真代表換線材可以充得更快。
    var chargingVerdict: (text: String, limited: Bool)? {
        guard isPluggedIn, chargerMaxWatts > 0 else { return nil }
        let charger = chargerMaxWatts
        guard let port = poweringPort else {
            return portInfos.filter(\.isConnected).count > 1
                ? ("充電器最高可供 \(charger) W。有多個連接埠正在使用，各埠的線材規格請看「系統效能」分頁。", false)
                : ("充電器最高可供 \(charger) W。", false)
        }
        if port.isMagSafe { return ("充電器最高可供 \(charger) W。MagSafe 線材不提供線材規格。", false) }
        guard let cable = port.cable else {
            return ("充電器最高可供 \(charger) W。這條線材沒有 e‑marker 晶片（或目前讀不到），依規格最高承載 3 A（60 W）。", false)
        }
        if cable.watts < charger {
            return ("線材限制了充電速度：充電器最高可供 \(charger) W，但這條線材額定只能承載 \(cable.watts) W，換一條線可以充得更快。", true)
        }
        return ("充電器與線材搭配良好：充電器最高可供 \(charger) W，線材額定可承載 \(cable.watts) W。", false)
    }
}
