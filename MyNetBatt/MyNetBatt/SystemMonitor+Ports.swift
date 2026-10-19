import Foundation
import IOKit
import CoreGraphics

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
    /// e‑marker 的速度欄位（0＝USB 2.0 … 4＝USB4 Gen 4）。
    let speedIndex: Int
    let maxVolts: Int
    let amps: Int
    /// 線材額定可承載的功率：支援 EPR 的 5 A 線為 240 W，其餘為 20 V × 額定電流。
    let watts: Int

    var kindText: String { isActive ? String(localized: "主動式") : String(localized: "被動式") }
    var ratingText: String { String(localized: "\(maxVolts) V／\(amps) A (\(watts) W)") }
}

nonisolated struct PortInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let isMagSafe: Bool
    let isConnected: Bool
    /// 對端裝置（充電器、Hub、顯示器…）的廠商；裝置沒有回報時為空字串。
    let partner: String
    let cable: CableInfo?
    /// 作用中的傳輸方式代碼（CC、USB2、USB3、CIO、DisplayPort）。
    var transports: [String] = []
    /// Thunderbolt／USB4 實際連線速率，以及這個連接埠支援的最高速度（Gb/s）。
    var link: LinkRate? = nil
    var macMaxGbps: Double? = nil
    /// 透過這個連接埠輸出影像的顯示器。
    var displays: [DisplayLink] = []
    var tech: PortTech? = nil
    /// PD 控制器的供電檔位、協商結果與異常計數（對應不到連接埠時為 nil）。
    var power: PortPower? = nil

    var transportNames: [String] { PortAnalysis.transportNames(transports) }

    /// 有連線時，正在傳什麼、誰在限速的結論。MagSafe 只供電，不判斷。
    var verdict: PortVerdict? {
        guard isConnected, !isMagSafe else { return nil }
        return PortAnalysis.verdict(transports: transports, link: link, macMax: macMaxGbps,
                                    cableGbps: cable.flatMap { PortAnalysis.cableGbps(speedIndex: $0.speedIndex) },
                                    displayCount: displays.count, isHDMI: id.hasPrefix("HDMI@"))
    }
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
    static func portInfos(controllers: [PortPower] = []) -> [PortInfo] {
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
        var cableIDs: [String: String] = [:]
        for dict in registryProperties(ofClass: "IOPortTransportComponentCCUSBPDSOPp") {
            if let cable = cableInfo(from: dict) { cables[portKey(dict)] = cable }
            let vid = (dict["Vendor ID"] as? NSNumber)?.intValue ?? 0, pid = (dict["Product ID"] as? NSNumber)?.intValue ?? 0
            if vid > 0 || pid > 0 { cableIDs[portKey(dict)] = String(format: "VID 0x%04X · PID 0x%04X", vid, pid) }
        }

        // Thunderbolt／USB4 對端裝置的名稱（例如「BenQ PD2725U」），比 PD 的廠商代碼好懂。
        var tbDevices: [String: String] = [:]
        for dict in registryProperties(ofClass: "IOPortTransportStateCIO") where dict["Active"] as? Bool == true {
            let vendor = dict["Device Vendor Name"] as? String ?? ""
            let model = dict["Device Model Name"] as? String ?? ""
            let name = model.hasPrefix(vendor) ? model : [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { tbDevices[portKey(dict)] = name }
        }
        // 每個連接埠作用中的傳輸方式。
        var transports: [String: [String]] = [:]
        var techs: [String: PortTech] = [:]
        var connectionCounts: [String: Int] = [:]
        for dict in registryProperties(ofClass: "IOAccessoryManager") {
            guard let type = dict["PortTypeDescription"] as? String, let number = (dict["PortNumber"] as? NSNumber)?.intValue else { continue }
            let key = "\(type)@\(number)"
            transports[key] = dict["TransportsActive"] as? [String] ?? []
            func int(_ name: String) -> Int? { (dict[name] as? NSNumber)?.intValue }
            if let count = int("ConnectionCount") { connectionCounts[key] = count }
            techs[key] = PortTech(
                supported: PortAnalysis.transportNames(dict["TransportsSupported"] as? [String] ?? []),
                plugEvents: int("Plug Event Count"), connections: int("ConnectionCount"), overcurrent: int("Overcurrent Count"),
                activeCable: dict["ActiveCable"] as? Bool, opticalCable: dict["OpticalCable"] as? Bool)
        }
        for (key, id) in cableIDs { techs[key, default: PortTech()].cableID = id }
        let links = thunderboltLinks()
        let displays = displayLinks(transports: transports)
        let powers = PortPower.match(controllers: controllers, portConnections: connectionCounts)

        var ports: [PortInfo] = []
        for dict in registryProperties(ofClass: "IOPortTransportStateCC") {
            guard (dict["ParentPortBuiltIn"] as? Bool) != false else { continue }
            let type = dict["ParentPortTypeDescription"] as? String ?? "USB-C"
            let number = (dict["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            let key = portKey(dict)
            let isMagSafe = type.hasPrefix("MagSafe")
            ports.append(PortInfo(
                id: key,
                name: isMagSafe ? type : String(localized: "USB‑C 連接埠 \(number)"),
                isMagSafe: isMagSafe,
                isConnected: dict["Active"] as? Bool ?? false,
                partner: tbDevices[key] ?? partners[key] ?? "",
                cable: cables[key],
                transports: transports[key] ?? [],
                link: (transports[key] ?? []).contains("CIO") ? links[number]?.current : nil,
                macMaxGbps: isMagSafe ? nil : links[number]?.max,
                displays: displays[key] ?? [],
                tech: techs[key],
                power: powers[key]
            ))
        }
        // HDMI 等非 USB‑C 的影像埠：有接顯示器時才列出。
        for (key, list) in displays where key.hasPrefix("HDMI@") && !list.isEmpty {
            ports.append(PortInfo(id: key, name: String(localized: "HDMI 連接埠"), isMagSafe: false, isConnected: true,
                                  partner: list.map(\.name).formatted(.list(type: .and)), cable: nil,
                                  transports: ["DisplayPort"], displays: list))
        }
        // MagSafe 排在最前面，接著 USB‑C 依連接埠編號，HDMI 最後。
        func rank(_ port: PortInfo) -> Int { port.isMagSafe ? 0 : (port.id.hasPrefix("HDMI@") ? 2 : 1) }
        return ports.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }

    /// AppleSmartBattery 回報的各 PD 控制器資料（供電檔位、協商結果、異常計數）。
    static func powerControllers() -> [PortPower] {
        guard let battery = registryProperties(ofClass: "AppleSmartBattery").first,
              let list = battery["PortControllerInfo"] as? [[String: Any]] else { return [] }
        return list.map(PortPower.init(controller:))
    }

    /// 每個 USB‑C 連接埠（以 Thunderbolt 的 Socket ID 對應連接埠編號）的實際連線速率與支援的最高速度。
    private static func thunderboltLinks() -> [Int: (current: LinkRate?, max: Double?)] {
        var result: [Int: (current: LinkRate?, max: Double?)] = [:]
        for dict in registryProperties(ofClass: "IOThunderboltPort") {
            // 只看 Mac 這一端、第一條通道的連接埠；外接裝置上的連接埠沒有 Socket ID。
            guard let socket = (dict["Socket ID"] as? String).flatMap(Int.init),
                  (dict["Lane"] as? NSNumber)?.intValue == 1 else { continue }
            func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
            let current = LinkRate(speedCode: int("Current Link Speed"), widthCode: int("Current Link Width"))
            let maxLanes = int("Supported Link Width") >= 2 ? 2.0 : 1.0
            let max = LinkRate.perLane(code: int("Supported Link Speed")).map { $0 * maxLanes }
            result[socket] = (current, max)
        }
        return result
    }

    /// macOS 目前接著的外接螢幕：用 EDID 的廠商／產品／序號對應，取目前更新率與原生解析度下可選的更新率。
    private struct ScreenMode { let vendor: Int; let model: Int; let serial: Int; let current: Double; let width: Int; let height: Int; let modes: [(w: Int, h: Int, refresh: Int)] }
    private static func screenModes() -> [ScreenMode] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            return ScreenMode(vendor: Int(CGDisplayVendorNumber(id)), model: Int(CGDisplayModelNumber(id)),
                              serial: Int(CGDisplaySerialNumber(id)), current: mode.refreshRate, width: mode.pixelWidth, height: mode.pixelHeight,
                              modes: all.flatMap { [($0.pixelWidth, $0.pixelHeight, Int($0.refreshRate.rounded())),
                                                    ($0.width, $0.height, Int($0.refreshRate.rounded()))] })
        }
    }

    /// 各連接埠上正在輸出影像的顯示器（名稱、DisplayPort 連線速率與通道數、模式診斷）。
    private static func displayLinks(transports: [String: [String]]) -> [String: [DisplayLink]] {
        var result: [String: [DisplayLink]] = [:]
        let screens = screenModes()
        for dict in registryProperties(ofClass: "IOPortTransportStateDisplayPort") where dict["Active"] as? Bool == true {
            guard (dict["ParentPortBuiltIn"] as? Bool) != false else { continue }
            let type = dict["ParentPortTypeDescription"] as? String ?? ""
            let number = (dict["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            let metadata = dict["Metadata"] as? [String: Any] ?? [:]
            let name = (metadata["ProductName"] as? String) ?? (dict["ManufacturerName"] as? String) ?? String(localized: "顯示器")
            let rate = dict["LinkRateDescription"] as? String ?? ""
            let lanes = (dict["LaneCount"] as? NSNumber)?.intValue ?? 0
            let tunneled = dict["Tunneled"] as? Bool ?? false
            var diagnosis: DisplayDiagnosis?
            if let data = (dict["EDID"] as? Data) ?? (metadata["EDID"] as? Data), let edid = EDIDInfo([UInt8](data)), let best = edid.best {
                // 同型號接兩台時要靠序號區分；仍然分不出來就不拿目前模式。
                var matches = screens.filter { $0.vendor == edid.vendorID && $0.model == edid.productID }
                if matches.count > 1 { matches = matches.filter { $0.serial == edid.serial } }
                let screen = matches.count == 1 ? matches[0] : nil
                let offered = Set(screen?.modes.filter { $0.w == best.width && $0.h == best.height }.map(\.refresh) ?? [])
                diagnosis = DisplayDiagnosis.evaluate(
                    edid: edid, currentRefresh: screen?.current, offeredRefreshes: offered,
                    linkRate: DisplayDiagnosis.rate(from: rate), lanes: lanes,
                    maxLanes: (dict["MaxLaneCount"] as? NSNumber)?.intValue ?? lanes,
                    usbShared: (transports["\(type)@\(number)"] ?? []).contains("USB3"), tunneled: tunneled,
                    currentWidth: screen?.width, currentHeight: screen?.height)
            }
            let link = DisplayLink(
                id: dict["TransportDescription"] as? String ?? UUID().uuidString,
                name: name,
                rate: rate,
                lanes: lanes,
                tunneled: tunneled,
                diagnosis: diagnosis)
            result["\(type)@\(number)", default: []].append(link)
        }
        return result.mapValues { $0.sorted { $0.id < $1.id } }
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
            speed: speedIndex < speeds.count ? speeds[speedIndex] : String(localized: "未知速度"),
            speedIndex: speedIndex,
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
        let hex = String(format: "0x%04X", id)
        return known[id] ?? String(localized: "廠商代碼 \(hex)")
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
            let controllers = SystemReaders.powerControllers()
            let snapshot = SystemReaders.portInfos(controllers: controllers)
            let supply = PortPower.activeSupply(controllers)
            await MainActor.run {
                let previous = self.portInfos
                self.assignIfChanged(\.portInfos, snapshot)
                self.assignIfChanged(\.activeSupply, supply)
                self.evaluatePortNotifications(previous: previous, current: snapshot)
            }
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

    /// 連接埠接上或拔除時通知。接上後 e‑marker 與連線速度要幾秒才讀得到，所以等 6 秒再用最新資料描述。
    func evaluatePortNotifications(previous: [PortInfo], current: [PortInfo]) {
        let connected = Set(current.filter(\.isConnected).map(\.id))
        let (added, removed) = PortAnalysis.changes(previous: portNotifyBaseline, current: connected)
        portNotifyBaseline = connected
        for id in removed {
            portNotifyTasks.removeValue(forKey: id)?.cancel()
            portNotifyPlan.disconnected(id)
        }
        guard notifyPortChanges else { return }
        for id in added {
            let token = portNotifyPlan.connected(id)
            portNotifyTasks.removeValue(forKey: id)?.cancel()
            portNotifyTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self else { return }
                self.portNotifyTasks[id] = nil
                let port = self.portInfos.first(where: { $0.id == id })
                guard let port, self.portNotifyPlan.shouldDeliver(id, token: token, enabled: self.notifyPortChanges, stillConnected: port.isConnected) else { return }
                var parts: [String] = []
                if !port.partner.isEmpty { parts.append(port.partner) }
                if let verdict = port.verdict {
                    parts.append(verdict.title)
                    if verdict.level == .warning { parts.append(verdict.detail) }
                }
                if let cable = port.cable { parts.append(String(localized: "線材 \(cable.speed) · \(cable.ratingText)")) }
                BatteryNotifier.shared.post(id: "port-\(id)", title: String(localized: "\(port.name) 已連接"),
                                            body: parts.joined(separator: "\n"),
                                            sound: PortNotifyPlan.playsSound(soundEnabled: self.notificationSound, verdict: port.verdict))
            }
        }
        for id in removed {
            let name = previous.first(where: { $0.id == id })?.name ?? id
            BatteryNotifier.shared.post(id: "port-\(id)", title: String(localized: "\(name) 已拔除"), body: "", sound: false)
        }
    }

    /// 正在供電的那個連接埠：和 activeSupply 同一個 PD 控制器的埠；判斷不出來時為 nil。
    var poweringPort: PortInfo? {
        let connected = portInfos.filter(\.isConnected)
        let id = PortPower.poweringPortID(connected: connected.map { ($0.id, $0.power) }, supply: activeSupply)
        return connected.first { $0.id == id }
    }

    /// 充電器所有檔位裡最高的瓦數；讀不到檔位時用系統回報的額定瓦數。
    var chargerMaxWatts: Int {
        let best = max(chargerProfiles.map(\.watts).max() ?? 0, activeSupply?.maxWatts ?? 0).rounded()
        return max(Int(best), Int(adapterRating.replacingOccurrences(of: " W", with: "")) ?? 0)
    }

    /// 充電器與線材誰是瓶頸的一句結論；`limited` 為真代表換線材可以充得更快。
    var chargingVerdict: (text: String, limited: Bool)? {
        guard isPluggedIn, chargerMaxWatts > 0 else { return nil }
        let charger = chargerMaxWatts
        guard let port = poweringPort else {
            return portInfos.filter(\.isConnected).count > 1
                ? (String(localized: "充電器最高可供 \(charger) W。有多個連接埠正在使用，各埠的線材規格請看「連接埠」分頁。"), false)
                : (String(localized: "充電器最高可供 \(charger) W。"), false)
        }
        if port.isMagSafe { return (String(localized: "充電器最高可供 \(charger) W。MagSafe 線材不提供線材規格。"), false) }
        guard let cable = port.cable else {
            return (String(localized: "充電器最高可供 \(charger) W。這條線材沒有 e‑marker 晶片（或目前讀不到），依規格最高承載 3 A（60 W）。"), false)
        }
        if cable.watts < charger {
            return (String(localized: "線材限制了充電速度：充電器最高可供 \(charger) W，但這條線材額定只能承載 \(cable.watts) W，換一條線可以充得更快。"), true)
        }
        return (String(localized: "充電器與線材搭配良好：充電器最高可供 \(charger) W，線材額定可承載 \(cable.watts) W。"), false)
    }
}
