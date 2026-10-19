import Foundation

// MARK: - 螢幕診斷：EDID 解析、模式比較與頻寬判斷（不碰 IOKit／CoreGraphics，方便單獨測試）

/// 一個顯示模式（解析度＋更新率＋像素時脈）。
nonisolated struct DisplayTiming: Equatable {
    let width: Int
    let height: Int
    let refresh: Double
    /// 像素時脈（MHz）；由 VIC 代碼查表或 EDID 時序算出。
    let pixelClockMHz: Double

    /// 8 bit 色深（24 bpp）所需的影像資料量（Gbps）。
    var requiredGbps: Double { pixelClockMHz * 24 / 1000 }
    var resolutionText: String { "\(width)×\(height)" }
    var refreshText: String { "\(Int(refresh.rounded())) Hz" }
}

/// 從 EDID 讀到的螢幕資訊。
nonisolated struct EDIDInfo: Equatable {
    /// 廠商代碼（EDID 第 8–9 位元組，大端序；和 CGDisplayVendorNumber 相同）。
    let vendorID: Int
    /// 產品代碼（第 10–11 位元組，小端序；和 CGDisplayModelNumber 相同）。
    let productID: Int
    let serial: Int
    let name: String?
    /// 第一個詳細時序＝螢幕建議（原生）的模式。
    let preferred: DisplayTiming?
    /// EDID 裡找得到的所有模式（基本區塊、CTA‑861、DisplayID）。
    let timings: [DisplayTiming]
    /// 範圍限制描述的最高垂直更新率。
    let maxRefreshLimit: Int?

    /// 原生解析度下更新率最高的模式。
    var best: DisplayTiming? {
        guard let preferred else { return nil }
        return timings.filter { $0.width == preferred.width && $0.height == preferred.height }
            .max { $0.refresh < $1.refresh } ?? preferred
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128, bytes[0] == 0, bytes[1] == 0xFF, bytes[7] == 0 else { return nil }
        vendorID = Int(bytes[8]) << 8 | Int(bytes[9])
        productID = Int(bytes[10]) | Int(bytes[11]) << 8
        serial = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
        var timings: [DisplayTiming] = []
        var name: String?
        var maxRefresh: Int?
        for i in 0..<4 {
            let block = Array(bytes[(54 + 18 * i)..<(72 + 18 * i)])
            if let timing = Self.detailedTiming(block) {
                timings.append(timing)
            } else if block[3] == 0xFC {
                name = String(decoding: block[5..<18], as: UTF8.self)
                    .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
            } else if block[3] == 0xFD {
                // 第 4 位元組 bit 1：最高垂直更新率要再加 255。
                maxRefresh = Int(block[6]) + (block[4] & 0x02 != 0 ? 255 : 0)
            }
        }
        preferred = timings.first
        timings += Self.standardTimings(bytes)
        // 延伸區塊：CTA‑861（0x02）與 DisplayID（0x70）。
        var offset = 128
        while offset + 128 <= bytes.count {
            let ext = Array(bytes[offset..<(offset + 128)])
            if ext[0] == 0x02 { timings += Self.ctaTimings(ext) }
            if ext[0] == 0x70 { timings += Self.displayIDTimings(ext) }
            offset += 128
        }
        self.name = name
        self.maxRefreshLimit = maxRefresh
        self.timings = timings
    }

    /// 18 位元組的詳細時序描述（DTD）；像素時脈為 0 的是其他描述，回傳 nil。
    static func detailedTiming(_ b: [UInt8]) -> DisplayTiming? {
        guard b.count >= 18 else { return nil }
        let clock = Double(Int(b[0]) | Int(b[1]) << 8) * 10_000
        guard clock > 0 else { return nil }
        let h = Int(b[2]) | Int(b[4] & 0xF0) << 4, hBlank = Int(b[3]) | Int(b[4] & 0x0F) << 8
        let v = Int(b[5]) | Int(b[7] & 0xF0) << 4, vBlank = Int(b[6]) | Int(b[7] & 0x0F) << 8
        guard h > 0, v > 0 else { return nil }
        return DisplayTiming(width: h, height: v, refresh: clock / Double((h + hBlank) * (v + vBlank)), pixelClockMHz: clock / 1_000_000)
    }

    /// 基本區塊第 38–53 位元組的 8 組標準時序（Standard Timings）。
    /// 水平像素＝第一個位元組 × 8 + 248；第二個位元組高 2 位是長寬比、低 6 位＋60 是更新率；0x01 0x01 表示未使用。
    static func standardTimings(_ bytes: [UInt8]) -> [DisplayTiming] {
        guard bytes.count >= 54 else { return [] }
        let isV13 = bytes[18] > 1 || bytes[19] >= 3
        return (0..<8).compactMap { i in
            let b0 = bytes[38 + 2 * i], b1 = bytes[39 + 2 * i]
            guard !(b0 == 0x01 && b1 == 0x01), !(b0 == 0 && b1 == 0) else { return nil }
            let width = Int(b0) * 8 + 248
            let height: Int = switch b1 >> 6 {
            case 0: isV13 ? width * 10 / 16 : width
            case 1: width * 3 / 4
            case 2: width * 4 / 5
            default: width * 9 / 16
            }
            let refresh = Double(Int(b1 & 0x3F) + 60)
            return DisplayTiming(width: width, height: height, refresh: refresh,
                                 pixelClockMHz: estimatedPixelClock(width: width, height: height, refresh: refresh))
        }
    }

    /// 沒有完整時序時，用 CVT 精簡空白（水平多 160 像素、垂直空白約 460 µs）估算像素時脈（MHz）。
    static func estimatedPixelClock(width: Int, height: Int, refresh: Double) -> Double {
        let blankRatio = 460e-6 * refresh
        let vTotal = Double(height) / max(1 - blankRatio, 0.5)
        return Double(width + 160) * vTotal * refresh / 1_000_000
    }

    /// CTA‑861 延伸區塊：詳細時序，加上常見的 VIC 代碼。
    static func ctaTimings(_ x: [UInt8]) -> [DisplayTiming] {
        var result: [DisplayTiming] = []
        let dtdStart = Int(x[2])
        var i = 4
        while i < min(dtdStart, 127) {
            let tag = x[i] >> 5, length = Int(x[i] & 0x1F)
            if tag == 2 {
                for j in 0..<length where i + 1 + j < 127 {
                    let code = x[i + 1 + j]
                    // 1–64 的 bit 7 是「原生」旗標。
                    let vic = code >= 129 && code <= 192 ? Int(code & 0x7F) : Int(code)
                    if let timing = vicTable[vic] { result.append(timing) }
                }
            }
            i += 1 + length
        }
        var j = dtdStart
        while dtdStart >= 4, j + 18 <= 127 {
            guard let timing = detailedTiming(Array(x[j..<(j + 18)])) else { break }
            result.append(timing)
            j += 18
        }
        return result
    }

    /// DisplayID 延伸區塊的 Type I（0x03）與 Type VII（0x22）詳細時序，每筆 20 位元組。
    static func displayIDTimings(_ x: [UInt8]) -> [DisplayTiming] {
        var result: [DisplayTiming] = []
        let end = min(5 + Int(x[2]), 127)
        var i = 5
        while i + 3 <= end {
            let tag = x[i], length = Int(x[i + 2])
            guard tag != 0 || length != 0 else { break }
            if tag == 0x03 || tag == 0x22 {
                let unit = tag == 0x03 ? 10_000.0 : 1_000.0
                var k = i + 3
                while k + 20 <= min(i + 3 + length, 128) {
                    let t = Array(x[k..<(k + 20)])
                    let clock = Double((Int(t[0]) | Int(t[1]) << 8 | Int(t[2]) << 16) + 1) * unit
                    let h = (Int(t[4]) | Int(t[5]) << 8) + 1, hBlank = (Int(t[6]) | Int(t[7]) << 8) + 1
                    let v = (Int(t[12]) | Int(t[13]) << 8) + 1, vBlank = (Int(t[14]) | Int(t[15]) << 8) + 1
                    result.append(DisplayTiming(width: h, height: v, refresh: clock / Double((h + hBlank) * (v + vBlank)),
                                                pixelClockMHz: clock / 1_000_000))
                    k += 20
                }
            }
            i += 3 + length
        }
        return result
    }

    /// 常見的 CTA VIC 代碼（只收螢幕常用的高解析度／高更新率模式）。
    static let vicTable: [Int: DisplayTiming] = [
        16: DisplayTiming(width: 1920, height: 1080, refresh: 60, pixelClockMHz: 148.5),
        63: DisplayTiming(width: 1920, height: 1080, refresh: 120, pixelClockMHz: 297),
        64: DisplayTiming(width: 1920, height: 1080, refresh: 100, pixelClockMHz: 297),
        95: DisplayTiming(width: 3840, height: 2160, refresh: 30, pixelClockMHz: 297),
        97: DisplayTiming(width: 3840, height: 2160, refresh: 60, pixelClockMHz: 594),
        102: DisplayTiming(width: 4096, height: 2160, refresh: 60, pixelClockMHz: 594),
        117: DisplayTiming(width: 3840, height: 2160, refresh: 100, pixelClockMHz: 1188),
        118: DisplayTiming(width: 3840, height: 2160, refresh: 120, pixelClockMHz: 1188),
    ]
}

/// 螢幕目前的模式和它能跑的最佳模式比較後的結論。
nonisolated struct DisplayDiagnosis: Equatable {
    enum Level: Equatable { case good, info, warning }
    let level: Level
    let title: String
    let detail: String
    /// 原生解析度＋最高更新率。
    let best: DisplayTiming?
    /// 目前的更新率（讀不到螢幕目前模式時為 nil）。
    let currentRefresh: Double?
    /// 最佳模式需要的頻寬與這條 DisplayPort 連線可用的頻寬（Gbps）。
    let requiredGbps: Double?
    let availableGbps: Double?

    /// DisplayPort 每條通道的實際可用頻寬：HBR（≤ 8.1 Gbps）用 8b/10b 編碼剩 80%，UHBR 用 128b/132b。
    static func usableGbps(rate: Double, lanes: Int) -> Double {
        rate * Double(lanes) * (rate > 8.1 ? 128.0 / 132.0 : 0.8)
    }

    /// 從「8.1 Gbps (HBR3)」取出 8.1。
    static func rate(from description: String) -> Double? {
        description.split(separator: " ").first.flatMap { Double($0) }
    }

    /// - Parameters:
    ///   - currentRefresh: macOS 目前的更新率；對應不到螢幕時為 nil，回報 0（部分可變更新率螢幕）也視為不知道。
    ///   - currentWidth／currentHeight: 目前模式的像素尺寸（HiDPI 時是繪製尺寸，不會小於實際輸出）。
    ///   - offeredRefreshes: macOS 在原生解析度提供的更新率（四捨五入）；對應不到時為空。
    ///   - usbShared: 這個 USB‑C 埠同時在跑 USB 3 資料（DisplayPort Alt Mode 只剩 2 條通道）。
    static func evaluate(edid: EDIDInfo, currentRefresh: Double?, offeredRefreshes: Set<Int>,
                         linkRate: Double?, lanes: Int, maxLanes: Int, usbShared: Bool, tunneled: Bool,
                         currentWidth: Int? = nil, currentHeight: Int? = nil) -> DisplayDiagnosis? {
        guard var best = edid.best else { return nil }
        // EDID 不一定解得出全部模式：macOS 在原生解析度提供更高更新率時，以 macOS 的為準。
        if let offeredMax = offeredRefreshes.max(), Double(offeredMax) > best.refresh + 1 {
            best = DisplayTiming(width: best.width, height: best.height, refresh: Double(offeredMax),
                                 pixelClockMHz: best.pixelClockMHz * Double(offeredMax) / best.refresh)
        }
        let currentRefresh = currentRefresh.flatMap { $0 > 0 ? $0 : nil }
        let available = linkRate.map { usableGbps(rate: $0, lanes: lanes) }
        let required = best.requiredGbps
        let bestText = "\(best.resolutionText) · \(best.refreshText)"
        func make(_ level: Level, _ title: String, _ detail: String) -> DisplayDiagnosis {
            DisplayDiagnosis(level: level, title: title, detail: detail, best: best, currentRefresh: currentRefresh,
                             requiredGbps: tunneled ? nil : required, availableGbps: tunneled ? nil : available)
        }
        let bestRate = Int(best.refresh.rounded())
        guard let currentRefresh else {
            return make(.info, String(localized: "螢幕最高支援 \(bestText)"), String(localized: "讀不到這台螢幕目前的模式。"))
        }
        let current = Int(currentRefresh.rounded())
        // 目前像素尺寸比原生小＝輸出的不是原生解析度（HiDPI 縮放模式的像素尺寸不會比原生小）。
        if let w = currentWidth, let h = currentHeight, w > 0, h > 0, w < best.width || h < best.height {
            return make(.info, String(localized: "目前不是原生解析度"),
                        String(localized: "目前輸出 \(w)×\(h) · \(current) Hz，螢幕原生 \(best.resolutionText)，最高 \(best.refreshText)。可到「系統設定 › 顯示器」選原生解析度。"))
        }
        if current >= bestRate {
            return make(.good, String(localized: "已是螢幕的最佳模式"), String(localized: "\(bestText)，螢幕支援的最高更新率。"))
        }
        let currentText = "\(current) Hz"
        if offeredRefreshes.contains(where: { abs($0 - bestRate) <= 1 }) {
            return make(.info, String(localized: "可以切換到 \(best.refreshText)"),
                        String(localized: "目前 \(currentText)，螢幕最高支援 \(bestText)，可到「系統設定 › 顯示器」更改更新率。"))
        }
        // macOS 沒提供最佳模式：用頻寬推測原因。macOS 可能用 DSC 壓縮跑超過頻寬的模式，所以這只是推測。
        let need = String(format: "%.1f", required)
        if !tunneled, let available, required > available {
            let have = String(format: "%.1f", available)
            if usbShared && maxLanes < 4 && lanes < 4 {
                return make(.warning, String(localized: "USB 資料佔用了影像通道"),
                            String(localized: "這個 USB‑C 埠同時傳 USB 3 資料，影像只剩 \(lanes) 條通道（約 \(have) Gbps），\(bestText) 約需 \(need) Gbps，所以目前只能 \(currentText)。可在螢幕選單把 USB‑C 改成影像優先（USB 會降為 2.0），或改用 Thunderbolt／DisplayPort 線。"))
            }
            return make(.warning, String(localized: "連線頻寬不足"),
                        String(localized: "\(bestText) 約需 \(need) Gbps，這條連線只有約 \(have) Gbps，所以目前只能 \(currentText)。線材、轉接器或 Hub 可能限制了速度。"))
        }
        return make(.info, String(localized: "macOS 沒有提供 \(best.refreshText)"),
                    String(localized: "螢幕宣稱支援 \(bestText)，目前 \(currentText)。頻寬看起來足夠，可能是轉接器、Hub 或系統限制。"))
    }
}
