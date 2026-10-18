import Foundation

// MARK: - 連接埠連線狀態的解讀（不碰 IOKit，方便單獨測試）

/// Thunderbolt／USB4 的連線速率：每條通道的速度 × 通道數。
nonisolated struct LinkRate: Equatable {
    let perLane: Double
    let lanes: Int
    var total: Double { perLane * Double(lanes) }

    /// 例如「20 Gb/s × 2」。
    var laneText: String { "\(LinkRate.gbps(perLane)) Gb/s × \(lanes)" }

    /// 速度代碼（Thunderbolt 通道設定的位元）：0x2＝40、0x4＝20、0x8＝10 Gb/s。
    /// 「支援的速度」可能同時有好幾個位元，取最快的。
    static func perLane(code: Int) -> Double? {
        if code & 0x2 != 0 { return 40 }
        if code & 0x4 != 0 { return 20 }
        if code & 0x8 != 0 { return 10 }
        return nil
    }

    /// 通道寬度代碼：0x1 單通道、0x2 雙通道；0x4／0x8 是 Thunderbolt 5 的非對稱模式（單向 3 條）。
    static func lanes(widthCode: Int) -> Int? {
        switch widthCode {
        case 1: return 1
        case 2, 3: return 2
        case 4...15: return 3
        default: return nil
        }
    }

    init(perLane: Double, lanes: Int) {
        self.perLane = perLane
        self.lanes = lanes
    }

    init?(speedCode: Int, widthCode: Int) {
        guard let speed = Self.perLane(code: speedCode), let lanes = Self.lanes(widthCode: widthCode) else { return nil }
        self.init(perLane: speed, lanes: lanes)
    }

    static func gbps(_ value: Double) -> String {
        value < 1 ? String(format: "%.2f", value) : (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value))
    }
}

/// 一台透過這個連接埠傳送影像的顯示器。
nonisolated struct DisplayLink: Equatable, Identifiable {
    let id: String
    let name: String
    /// 例如「5.4 Gbps (HBR2)」。
    let rate: String
    let lanes: Int
    /// 透過 Thunderbolt 隧道傳送（不是 USB‑C 直接切換成 DisplayPort）。
    let tunneled: Bool
}

/// 連接埠的技術細節：支援的傳輸方式與控制器累計的計數。
nonisolated struct PortTech: Equatable {
    var supported: [String] = []
    var plugEvents: Int?
    var connections: Int?
    var overcurrent: Int?
    var activeCable: Bool?
    var opticalCable: Bool?
    /// 線材 e‑marker 的 Vendor ID／Product ID（十六進位）。
    var cableID: String?
}

/// 連接埠上「正在傳什麼」與「誰在限速」的一句結論。
nonisolated struct PortVerdict: Equatable {
    enum Level: Equatable { case good, info, warning }
    let title: String
    let detail: String
    let level: Level
}

nonisolated enum PortAnalysis {
    /// 與上一次比較，哪些連接埠新接上、哪些被拔除。沒有上一次的紀錄（剛啟動）時不算變化。
    static func changes(previous: Set<String>?, current: Set<String>) -> (added: Set<String>, removed: Set<String>) {
        guard let previous else { return ([], []) }
        return (current.subtracting(previous), previous.subtracting(current))
    }

    /// 線材 e‑marker 的速度欄位（0～4）對應的最高資料速度（Gb/s）。USB4 Gen 3 線為 2 × 20 Gb/s。
    static func cableGbps(speedIndex: Int) -> Double? {
        let table: [Double] = [0.48, 5, 10, 40, 80]
        return table.indices.contains(speedIndex) ? table[speedIndex] : nil
    }

    /// 系統回報的傳輸方式代碼（TransportsActive）轉成使用者看得懂的名稱；CC（協商用的控制線）不列。
    static func transportNames(_ codes: [String]) -> [String] {
        var names: [String] = []
        for code in codes {
            let name: String?
            switch code {
            case "CIO": name = "Thunderbolt / USB4"
            case "USB3": name = "USB 3"
            case "USB2": name = "USB 2"
            case "DisplayPort": name = String(localized: "DisplayPort 影像")
            case "CC": name = nil
            default: name = code
            }
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// 判斷這個連接埠目前的資料連線，以及 Mac、線材、裝置之中誰在限速。
    /// - Parameters:
    ///   - transports: 作用中的傳輸方式代碼。
    ///   - link: Thunderbolt／USB4 實際連線速率。
    ///   - macMax: 這個連接埠支援的最高 Thunderbolt／USB4 速度（Gb/s）。
    ///   - cableGbps: 線材 e‑marker 宣告的最高速度；沒有 e‑marker 時為 nil。
    ///   - isHDMI: HDMI 埠（不是 USB‑C）。
    static func verdict(transports: [String], link: LinkRate?, macMax: Double?, cableGbps: Double?, displayCount: Int, isHDMI: Bool = false) -> PortVerdict {
        let set = Set(transports)
        if isHDMI {
            return PortVerdict(title: String(localized: "正在傳輸影像"), detail: String(localized: "HDMI 連接埠正在輸出影像。"), level: .good)
        }
        if set.contains("CIO"), link == nil {
            // 系統已回報 Thunderbolt／USB4 作用中，只是速率還沒讀到（剛接上或找不到對應的通道），不能說成只有供電。
            return PortVerdict(title: String(localized: "Thunderbolt / USB4 連線中"), detail: String(localized: "連線速率讀取中或無法取得。"), level: .good)
        }
        if set.contains("CIO"), let link {
            let speed = LinkRate.gbps(link.total)
            // 實際速度要跑到線材上限（容許 10% 誤差）才算線材造成的限制；低於線材上限時，原因可能在裝置。
            if let cableGbps, let macMax, cableGbps < macMax, link.total >= cableGbps * 0.9 {
                return PortVerdict(
                    title: String(localized: "線材可能限制了速度（\(speed) Gbps）"),
                    detail: String(localized: "這個連接埠最高支援 \(LinkRate.gbps(macMax)) Gbps，但線材只能承載 \(LinkRate.gbps(cableGbps)) Gbps。如果裝置也支援更高速度，換一條更快的線材可以提升速度。"),
                    level: .warning)
            }
            if let macMax, link.total + 0.01 >= macMax {
                return PortVerdict(
                    title: String(localized: "以最高速度 \(speed) Gbps 運作"),
                    detail: String(localized: "已達這個連接埠支援的最高速度，線材沒有限制速度。"),
                    level: .good)
            }
            let ceiling = [macMax, cableGbps].compactMap { $0 }.min()
            if let ceiling, link.total < ceiling {
                return PortVerdict(
                    title: String(localized: "以 \(speed) Gbps 運作"),
                    detail: String(localized: "連接埠與線材最高可到 \(LinkRate.gbps(ceiling)) Gbps。通常是裝置本身只支援這個速度；如果裝置規格更高，重新插拔試試。"),
                    level: .info)
            }
            return PortVerdict(title: String(localized: "以 \(speed) Gbps 運作"), detail: String(localized: "Thunderbolt / USB4 連線作用中。"), level: .good)
        }
        if set.contains("USB3") {
            return PortVerdict(title: String(localized: "USB 3 高速資料連線"), detail: String(localized: "裝置以 USB 3（5 Gbps 以上）連線。"), level: .good)
        }
        if set.contains("USB2") {
            if let cableGbps, cableGbps < 1 {
                return PortVerdict(
                    title: String(localized: "線材只支援 USB 2.0"),
                    detail: String(localized: "線材 e‑marker 宣告只有 USB 2.0（480 Mbps），裝置若支援更高速度，請換一條支援 USB 3 以上的線材。"),
                    level: .warning)
            }
            return PortVerdict(
                title: String(localized: "只有 USB 2.0 速度（480 Mbps）"),
                detail: String(localized: "裝置只支援 USB 2，或這是一條只能充電／只有 USB 2 的線材。"),
                level: .info)
        }
        if set.contains("DisplayPort") || displayCount > 0 {
            let detail = set.contains("DisplayPort")
                ? String(localized: "USB‑C 直接切換成 DisplayPort 傳送影像，沒有其他資料連線。")
                : String(localized: "這個連接埠正在輸出影像。")
            return PortVerdict(title: String(localized: "正在傳輸影像"), detail: detail, level: .good)
        }
        return PortVerdict(title: String(localized: "只有供電"), detail: String(localized: "這個連接埠目前只有電力，沒有資料連線。"), level: .info)
    }
}

// MARK: - 連接埠插拔通知

/// 每個連接埠記住目前等待送出的那一次連線（代號）。接上後要等幾秒才送通知，
/// 這段時間拔除、重插或關閉通知，舊的那一則就作廢。
nonisolated struct PortNotifyPlan {
    private var tokens: [String: Int] = [:]
    private var counter = 0

    /// 接上：回傳這次連線的代號。
    mutating func connected(_ id: String) -> Int {
        counter += 1
        tokens[id] = counter
        return counter
    }

    mutating func disconnected(_ id: String) { tokens[id] = nil }
    mutating func reset() { tokens = [:] }

    /// 延遲時間到時要不要送出：通知仍開著、仍是同一次連線、連接埠仍連著。
    func shouldDeliver(_ id: String, token: Int, enabled: Bool, stillConnected: Bool) -> Bool {
        enabled && stillConnected && tokens[id] == token
    }

    /// 只有線材限速的警告才出聲，而且要尊重「播放提示音」開關。
    static func playsSound(soundEnabled: Bool, verdict: PortVerdict?) -> Bool {
        soundEnabled && verdict?.level == .warning
    }
}

// MARK: - 接上電源但沒在充電的原因

nonisolated enum ChargeState: Equatable {
    case charging
    /// 電池已充滿，Mac 直接由充電器供電。
    case full
    /// macOS 暫停充電：充電上限或「最佳化電池充電」（系統沒有區分是哪一個）。
    case onHold
    /// 接著充電器，電池卻在放電：充電器功率不夠或沒有實際供電。
    case drainingOnCharger

    /// - Parameters:
    ///   - batteryWatts: 電池端功率，放電為負。
    static func evaluate(plugged: Bool, charging: Bool, percent: Int, fullyCharged: Bool, batteryWatts: Double) -> ChargeState? {
        guard plugged else { return nil }
        if charging { return .charging }
        // 明顯放電要先判斷：100% 或 FullyCharged 時負載過大，電池一樣會放電，不能說成直接由充電器供電。
        if batteryWatts < -2 { return .drainingOnCharger }
        if percent >= 100 || fullyCharged { return .full }
        return .onHold
    }
}
