import Foundation

// MARK: - USB‑PD 供電檔位（PDO）、協商結果（RDO）與控制器計數（不碰 IOKit，方便單獨測試）

/// 充電器宣告的一個供電檔位（Source PDO）。
nonisolated struct PDObject: Equatable, Identifiable {
    enum Kind: Equatable {
        /// 固定電壓。
        case fixed(volts: Double, amps: Double)
        /// 電池型：電壓範圍＋最大功率。
        case battery(minVolts: Double, maxVolts: Double, watts: Double)
        /// 可變電壓：電壓範圍＋最大電流。
        case variable(minVolts: Double, maxVolts: Double, amps: Double)
        /// 可程式電源（PPS）：可微調的電壓範圍＋最大電流。
        case pps(minVolts: Double, maxVolts: Double, amps: Double)
        /// EPR 可調電壓（AVS）：電壓範圍＋最大功率。
        case eprAVS(minVolts: Double, maxVolts: Double, watts: Double)
        /// SPR 可調電壓（AVS，9–20 V）：9–15 V 與 15–20 V 兩段各自的最大電流。
        case sprAVS(amps15: Double, amps20: Double)
    }

    /// 在 PD 協商裡的檔位編號（從 1 起算；EPR 檔位從 8 起算）。
    let position: Int
    let kind: Kind
    /// 是否屬於 28 V 以上的 EPR 擴充檔位。
    let isEPR: Bool
    var id: Int { position }

    /// 這個檔位最多能給的功率。
    var maxWatts: Double {
        switch kind {
        case .fixed(let v, let a): v * a
        case .battery(_, _, let w): w
        case .variable(_, let v, let a): v * a
        case .pps(_, let v, let a): v * a
        case .eprAVS(_, _, let w): w
        case .sprAVS(let a15, let a20): max(15 * a15, 20 * a20)
        }
    }

    /// 解讀一個 32 位元的 Source PDO；空白（0）或看不懂的回傳 nil。
    init?(raw value: UInt32, position: Int, isEPR: Bool = false) {
        guard value != 0 else { return nil }
        self.position = position
        self.isEPR = isEPR
        func bits(_ high: Int, _ low: Int) -> Double { Double((value >> UInt32(low)) & ((1 << UInt32(high - low + 1)) - 1)) }
        switch value >> 30 {
        case 0b00: kind = .fixed(volts: bits(19, 10) * 0.05, amps: bits(9, 0) * 0.01)
        case 0b01: kind = .battery(minVolts: bits(19, 10) * 0.05, maxVolts: bits(29, 20) * 0.05, watts: bits(9, 0) * 0.25)
        case 0b10: kind = .variable(minVolts: bits(19, 10) * 0.05, maxVolts: bits(29, 20) * 0.05, amps: bits(9, 0) * 0.01)
        default:
            switch (value >> 28) & 0b11 {
            case 0b00: kind = .pps(minVolts: bits(15, 8) * 0.1, maxVolts: bits(24, 17) * 0.1, amps: bits(6, 0) * 0.05)
            case 0b01: kind = .eprAVS(minVolts: bits(15, 8) * 0.1, maxVolts: bits(25, 17) * 0.1, watts: bits(7, 0))
            case 0b10: kind = .sprAVS(amps15: bits(19, 10) * 0.01, amps20: bits(9, 0) * 0.01)
            default: return nil
            }
        }
    }

    /// 例如「20 V」「PPS 3.3–21 V」。
    var voltageText: String {
        switch kind {
        case .fixed(let v, _): "\(Self.num(v)) V"
        case .battery(let lo, let hi, _), .variable(let lo, let hi, _): "\(Self.num(lo))–\(Self.num(hi)) V"
        case .pps(let lo, let hi, _): "PPS \(Self.num(lo))–\(Self.num(hi)) V"
        case .eprAVS(let lo, let hi, _): "AVS \(Self.num(lo))–\(Self.num(hi)) V"
        case .sprAVS: "AVS 9–20 V"
        }
    }

    /// 例如「4.8 A · 96 W」「3 A」「140 W」。
    var limitText: String {
        switch kind {
        case .fixed(_, let a), .variable(_, _, let a): "\(Self.num(a)) A · \(Self.num(maxWatts)) W"
        case .pps(_, _, let a): "\(Self.num(a)) A"
        case .battery(_, _, let w), .eprAVS(_, _, let w): "\(Self.num(w)) W"
        case .sprAVS(let a15, let a20): "≤15 V \(Self.num(a15)) A · ≤20 V \(Self.num(a20)) A"
        }
    }

    /// 整數不帶小數點，其餘最多兩位（例如 5、4.8、3.25）。
    static func num(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

/// Mac 向充電器要求並談妥的供電（Request Data Object）。
nonisolated struct PDContract: Equatable {
    /// 選用的檔位編號，對應 PDObject.position。
    let position: Int
    /// 協商的電壓；可變電壓與電池型檔位的 RDO 不含電壓，只知道範圍，這時為 nil。
    let volts: Double?
    /// 協商的電流；電池型檔位只協商功率，這時為 nil。
    let amps: Double?
    /// 電池型檔位協商的功率。
    let requestedWatts: Double?
    /// 電壓不確定時顯示的範圍（例如「5–20 V」）。
    let voltageRange: String?
    /// Mac 需要的電力超過這個檔位能給的（Capability Mismatch）。
    let capabilityMismatch: Bool

    /// 協商的功率；可變電壓檔位不知道實際電壓，無法換算時為 nil。
    var watts: Double? {
        if let volts, let amps { return volts * amps }
        return requestedWatts
    }

    /// 依所選檔位的類型解讀 RDO；檔位不存在或 RDO 為 0（沒有協商）時回傳 nil。
    init?(raw value: UInt32, pdos: [PDObject]) {
        let position = Int(value >> 28)
        guard value != 0, position > 0, let pdo = pdos.first(where: { $0.position == position }) else { return nil }
        func bits(_ high: Int, _ low: Int) -> Double { Double((value >> UInt32(low)) & ((1 << UInt32(high - low + 1)) - 1)) }
        self.position = position
        capabilityMismatch = (value >> 26) & 1 == 1
        var volts: Double?, amps: Double?, requested: Double?, range: String?
        switch pdo.kind {
        case .fixed(let v, _):
            volts = v; amps = bits(19, 10) * 0.01
        case .variable(let lo, let hi, _):
            amps = bits(19, 10) * 0.01; range = "\(PDObject.num(lo))–\(PDObject.num(hi)) V"
        case .battery(let lo, let hi, _):
            requested = bits(19, 10) * 0.25; range = "\(PDObject.num(lo))–\(PDObject.num(hi)) V"
        case .pps:
            volts = bits(20, 9) * 0.02; amps = bits(6, 0) * 0.05
        case .eprAVS, .sprAVS:
            volts = bits(20, 9) * 0.025; amps = bits(6, 0) * 0.05
        }
        self.volts = volts; self.amps = amps; requestedWatts = requested; voltageRange = range
    }

    /// 例如「20 V × 4.7 A（94 W）」；電壓不確定時「5–20 V × 2 A」「9–20 V · 45 W」。
    var text: String {
        if let volts, let amps {
            let v = PDObject.num(volts), a = PDObject.num(amps), w = PDObject.num((volts * amps).rounded())
            return String(localized: "\(v) V × \(a) A（\(w) W）")
        }
        let range = voltageRange ?? ""
        if let amps { let a = PDObject.num(amps); return String(localized: "\(range) × \(a) A") }
        let w = PDObject.num(requestedWatts ?? 0)
        return String(localized: "\(range) · \(w) W")
    }
}

/// PD 控制器累計的異常計數；只列出意思明確的項目，不據此判斷線材好壞。
nonisolated struct PDHealth: Equatable {
    var hardResets = 0
    var shortDetects = 0
    var commErrors = 0
    var roleSwapFailures = 0

    var hasIssues: Bool { hardResets > 0 || shortDetects > 0 }
}

/// 一個 PD 控制器（通常一個連接埠一個）回報的供電資料。
nonisolated struct PortPower: Equatable {
    /// 充電器宣告的檔位；沒有協商時可能是上一次接過的充電器留下的舊資料，所以只在 contract 存在時顯示。
    let pdos: [PDObject]
    let contract: PDContract?
    let health: PDHealth
    /// 控制器回報的連線次數，用來對應是哪個連接埠。
    let attachCount: Int

    /// 這個控制器目前正在從對端取得電力。
    var isSupplying: Bool { contract != nil }
    var maxWatts: Double { pdos.map(\.maxWatts).max() ?? 0 }

    /// 從 AppleSmartBattery 的 PortControllerInfo 一筆資料解讀。
    /// PortControllerPortPDO 共 13 格：前 7 格是一般（SPR）檔位，後 6 格是 EPR 檔位。
    init(controller dict: [String: Any]) {
        func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        let raw = (dict["PortControllerPortPDO"] as? [NSNumber] ?? []).map { UInt32(truncatingIfNeeded: $0.int64Value) }
        let spr = min(int("PortControllerNPDOs"), 7), epr = min(int("PortControllerNEprPDOs"), 6)
        var list: [PDObject] = []
        for i in 0..<spr where i < raw.count {
            if let pdo = PDObject(raw: raw[i], position: i + 1) { list.append(pdo) }
        }
        for i in 0..<epr where 7 + i < raw.count {
            if let pdo = PDObject(raw: raw[7 + i], position: 8 + i, isEPR: true) { list.append(pdo) }
        }
        pdos = list
        contract = PDContract(raw: UInt32(truncatingIfNeeded: int("PortControllerActiveContractRdo")), pdos: list)
        health = PDHealth(
            hardResets: int("PortControllerHardResetCount"),
            shortDetects: int("PortControllerShortDetectCount"),
            commErrors: int("PortControllerI2cErrCount"),
            roleSwapFailures: int("PortControllerDataRoleSwapFailCount") + int("PortControllerPwrRoleSwapFailCount"))
        attachCount = int("PortControllerAttachCount")
    }

    init(pdos: [PDObject], contract: PDContract?, health: PDHealth = PDHealth(), attachCount: Int = 0) {
        self.pdos = pdos
        self.contract = contract
        self.health = health
        self.attachCount = attachCount
    }

    /// 控制器資料沒有標示是哪個連接埠：用「控制器的連線次數＝連接埠的連線次數」對應，
    /// 而且兩邊都必須只有唯一一筆相符，否則寧可不對應，也不要掛錯連接埠。
    static func match(controllers: [PortPower], portConnections: [String: Int]) -> [String: PortPower] {
        var result: [String: PortPower] = [:]
        for controller in controllers {
            let ports = portConnections.filter { $0.value == controller.attachCount }.map(\.key)
            let sameCount = controllers.filter { $0.attachCount == controller.attachCount }.count
            if ports.count == 1, sameCount == 1 { result[ports[0]] = controller }
        }
        return result
    }

    /// 正在供電給 Mac 的控制器。同時有好幾個控制器有協商時，無法確定 Mac 實際從哪一個取電，回傳 nil（不猜）。
    static func activeSupply(_ controllers: [PortPower]) -> PortPower? {
        let supplying = controllers.filter(\.isSupplying)
        return supplying.count == 1 ? supplying[0] : nil
    }

    /// 正在供電的連接埠：和 activeSupply 是同一個控制器的那個埠。
    /// 有好幾個埠在協商（activeSupply 為 nil）時回傳 nil；沒有任何 PD 協商時，只有一個連接埠有連線才能確定是它。
    static func poweringPortID(connected: [(id: String, power: PortPower?)], supply: PortPower?) -> String? {
        if let supply, let match = connected.first(where: { $0.power == supply }) { return match.id }
        if supply == nil, connected.contains(where: { $0.power?.isSupplying == true }) { return nil }
        return connected.count == 1 ? connected[0].id : nil
    }

    /// 各控制器的協商結果（RDO）與充電器宣告的檔位（PDO 與數量）；和上一次不同代表重新協商或供電能力變了，要重讀連接埠資料。
    static func contractFingerprint(_ controllers: [[String: Any]]) -> [Int] {
        controllers.flatMap { dict -> [Int] in
            func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
            let pdos = (dict["PortControllerPortPDO"] as? [NSNumber] ?? []).map(\.intValue)
            return [int("PortControllerActiveContractRdo"), int("PortControllerNPDOs"), int("PortControllerNEprPDOs")] + pdos
        }
    }
}
