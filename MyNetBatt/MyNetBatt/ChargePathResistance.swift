import Foundation

// MARK: - 充電路徑電阻估算（不碰 IOKit，方便單獨測試）
//
// 充電器輸出電壓固定時，Mac 端量到的輸入電壓會隨電流變大而下降：V = V₀ − I × R。
// 收集多筆（電流, 電壓）做線性迴歸，斜率的負值就是整段路徑的電阻（線材＋兩端接頭＋充電器輸出）。
// 系統的輸入電壓／電流（PowerTelemetryData）約每 60 秒才更新一次，所以要收集幾分鐘、而且期間負載要有變化。

nonisolated struct ResistanceEstimate: Equatable {
    let milliohms: Double
    let samples: Int
    /// 擬合程度（0～1），越接近 1 代表電壓與電流越符合直線關係。
    let rSquared: Double
    /// 樣本裡最大與最小電流的差（A）。
    let currentSpan: Double
}

nonisolated struct ResistanceSampler: Equatable {
    struct Sample: Equatable { let volts: Double; let amps: Double }

    enum Status: Equatable {
        /// 還在收集：目前筆數與電流變化範圍。
        case collecting(samples: Int, currentSpan: Double)
        case ready(ResistanceEstimate)
        /// 資料夠多，但電壓和電流不成直線關係（例如充電器電壓在變），不給數字。
        case unreliable(samples: Int)
    }

    static let maxSamples = 30
    static let minSamples = 5
    static let minCurrentSpan = 1.0
    static let minRSquared = 0.9
    /// 超過 1 Ω 不合理（多半是充電器在調電壓），不採用。
    static let maxMilliohms = 1000.0

    private(set) var samples: [Sample] = []
    private var lastUpdateTime: Int?
    /// 協商結果與充電器電壓；改變代表換了充電器或重新協商，舊樣本不能混用。
    private var context: [Int]?

    /// 加入一筆系統讀值。同一個更新時間只算一次；電流太小（幾乎沒在用充電器）不收。
    mutating func add(volts: Double, amps: Double, updateTime: Int, context: [Int]) {
        // 換了充電器或重新協商：清掉舊樣本，但保留上次的更新時間，
        // 系統還沒產生新讀數前（同一個 UpdateTime）的舊電壓電流不能算進新的路徑。
        if context != self.context { samples = []; self.context = context }
        guard updateTime != lastUpdateTime else { return }
        lastUpdateTime = updateTime
        guard volts > 0, amps >= 0.05 else { return }
        samples.append(Sample(volts: volts, amps: amps))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    /// 拔掉電源時清空。更新時間同樣保留，重新接上後要等系統的新讀數。
    mutating func reset() {
        samples = []
        context = nil
    }

    var status: Status {
        let amps = samples.map(\.amps)
        let span = (amps.max() ?? 0) - (amps.min() ?? 0)
        guard samples.count >= Self.minSamples, span >= Self.minCurrentSpan else {
            return .collecting(samples: samples.count, currentSpan: span)
        }
        let n = Double(samples.count)
        let meanI = amps.reduce(0, +) / n
        let meanV = samples.map(\.volts).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for s in samples {
            sxy += (s.amps - meanI) * (s.volts - meanV)
            sxx += (s.amps - meanI) * (s.amps - meanI)
            syy += (s.volts - meanV) * (s.volts - meanV)
        }
        guard sxx > 0, syy > 0 else { return .unreliable(samples: samples.count) }
        let slope = sxy / sxx
        let r2 = sxy * sxy / (sxx * syy)
        let milliohms = -slope * 1000
        guard slope < 0, r2 >= Self.minRSquared, milliohms <= Self.maxMilliohms else { return .unreliable(samples: samples.count) }
        return .ready(ResistanceEstimate(milliohms: milliohms, samples: samples.count, rSquared: r2, currentSpan: span))
    }
}
