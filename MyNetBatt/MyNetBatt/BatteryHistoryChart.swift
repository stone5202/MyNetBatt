import SwiftUI
import Charts

/// 把每分鐘一筆的電量紀錄整理成每 30 分鐘一格，並找出連續的充電／用電區段。
struct BatteryTimeline {
    struct Bucket: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        /// 這一格沒有紀錄（App 沒在執行或電腦在睡眠）時為 nil。
        let level: Int?
        /// 3.7 以前的紀錄沒有電源狀態，為 nil。
        let plugged: Bool?
    }

    struct Segment: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        let plugged: Bool
        /// 區段內第一筆與最後一筆紀錄的時間與電量，用來算耗時與電量變化。
        let firstSample: Date
        let lastSample: Date
        let firstLevel: Int
        let lastLevel: Int
        let reachesNow: Bool
    }

    static let bucketSeconds: TimeInterval = 1800
    static let bucketCount = 96

    let buckets: [Bucket]
    let segments: [Segment]
    var domain: ClosedRange<Date> { (buckets.first?.start ?? Date())...(buckets.last?.end ?? Date()) }

    /// 範圍內每個午夜與中午；以日曆計算，不用 stride（它從範圍起點起算，刻度不會落在整點）。
    var axisDates: [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        var date = calendar.startOfDay(for: domain.lowerBound)
        while date <= domain.upperBound {
            if date >= domain.lowerBound { dates.append(date) }
            guard let next = calendar.date(byAdding: .hour, value: 12, to: date) else { break }
            date = next
        }
        return dates
    }

    init(history: [BatteryData], now: Date = Date()) {
        let lastIndex = Int(now.timeIntervalSince1970 / Self.bucketSeconds)
        let firstIndex = lastIndex - Self.bucketCount + 1
        var grouped: [[BatteryData]] = Array(repeating: [], count: Self.bucketCount)
        for sample in history {
            let offset = Int(sample.time.timeIntervalSince1970 / Self.bucketSeconds) - firstIndex
            if grouped.indices.contains(offset) { grouped[offset].append(sample) }
        }

        var buckets: [Bucket] = []
        var segments: [Segment] = []
        // 目前累積中的區段：起點那一格的位置，以及頭尾兩筆紀錄。
        var run: (startOffset: Int, plugged: Bool, first: BatteryData, last: BatteryData)?

        func closeRun(endOffset: Int) {
            guard let current = run else { return }
            segments.append(Segment(
                id: segments.count,
                start: buckets[current.startOffset].start,
                end: buckets[endOffset].end,
                plugged: current.plugged,
                firstSample: current.first.time,
                lastSample: current.last.time,
                firstLevel: current.first.level,
                lastLevel: current.last.level,
                reachesNow: endOffset >= Self.bucketCount - 2
            ))
            run = nil
        }

        for (offset, samples) in grouped.enumerated() {
            let start = Date(timeIntervalSince1970: Double(firstIndex + offset) * Self.bucketSeconds)
            let end = start.addingTimeInterval(Self.bucketSeconds)
            guard let first = samples.first, let last = samples.last else {
                buckets.append(Bucket(id: offset, start: start, end: end, level: nil, plugged: nil))
                if offset > 0 { closeRun(endOffset: offset - 1) }
                continue
            }
            let level = samples.reduce(0) { $0 + $1.level } / samples.count
            let known = samples.compactMap { $0.plugged }
            guard !known.isEmpty else {
                // 沒有電源狀態的舊紀錄只畫電量，不猜是充電還是用電。
                buckets.append(Bucket(id: offset, start: start, end: end, level: level, plugged: nil))
                if offset > 0 { closeRun(endOffset: offset - 1) }
                continue
            }
            let plugged = known.filter { $0 }.count * 2 >= known.count
            // 同一格裡可能混有舊紀錄，區段的起訖只看有電源狀態的紀錄。
            let runFirst = samples.first { $0.plugged != nil } ?? first
            let runLast = samples.last { $0.plugged != nil } ?? last
            buckets.append(Bucket(id: offset, start: start, end: end, level: level, plugged: plugged))

            if let current = run, current.plugged == plugged {
                run = (current.startOffset, plugged, current.first, runLast)
            } else {
                if offset > 0 { closeRun(endOffset: offset - 1) }
                run = (offset, plugged, runFirst, runLast)
            }
        }
        closeRun(endOffset: Self.bucketCount - 1)

        self.buckets = buckets
        self.segments = segments
    }
}

/// 過去 48 小時的電量長條圖：下方的時間軸標出接電源與使用電池的區段，並寫出目前這一段的耗時與電量變化。
struct BatteryHistoryChart: View {
    let history: [BatteryData]
    var height: CGFloat = 112

    static let batteryColor = Color(red: 0.93, green: 0.66, blue: 0.0)
    static let pluggedColor = Color.green

    var body: some View {
        let timeline = BatteryTimeline(history: history)
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(timeline.buckets) { bucket in
                    RectangleMark(
                        xStart: .value("開始", bucket.start.addingTimeInterval(150)),
                        xEnd: .value("結束", bucket.end.addingTimeInterval(-150)),
                        yStart: .value("電量", 0),
                        yEnd: .value("電量", bucket.level ?? 100)
                    )
                    .foregroundStyle(Self.barStyle(bucket))
                    .cornerRadius(1)
                }
                ForEach(timeline.segments) { segment in
                    RectangleMark(
                        xStart: .value("開始", segment.start.addingTimeInterval(150)),
                        xEnd: .value("結束", segment.end.addingTimeInterval(-150)),
                        yStart: .value("電量", -17),
                        yEnd: .value("電量", -10)
                    )
                    .foregroundStyle(segment.plugged ? Self.pluggedColor : Self.batteryColor)
                    .cornerRadius(2)
                }
            }
            .chartYScale(domain: -20...100)
            .chartXScale(domain: timeline.domain)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine()
                    if let val = value.as(Int.self) { AxisValueLabel("\(val)%") }
                }
            }
            .chartXAxis {
                AxisMarks(values: timeline.axisDates) { value in
                    AxisTick()
                    if let date = value.as(Date.self) {
                        // 午夜的刻度標日期，中午的刻度標時間。
                        let isMidnight = Calendar.current.component(.hour, from: date) == 0
                        AxisValueLabel(isMidnight ? date.formatted(.dateTime.month(.defaultDigits).day()) : "12:00")
                    }
                }
            }
            .frame(height: height)

            HStack(spacing: 10) {
                if let current = timeline.segments.last, current.reachesNow {
                    Label(Self.summary(of: current), systemImage: current.plugged ? "bolt.fill" : "battery.50")
                        .foregroundStyle(current.plugged ? Self.pluggedColor : Self.batteryColor)
                        .bold()
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                legend("電池", Self.batteryColor)
                legend("電源", Self.pluggedColor)
            }
            .font(.caption2)
            .lineLimit(1)
        }
    }

    private static func barStyle(_ bucket: BatteryTimeline.Bucket) -> AnyShapeStyle {
        guard bucket.level != nil else { return AnyShapeStyle(Color.secondary.opacity(0.12)) }
        guard let plugged = bucket.plugged else { return AnyShapeStyle(Color.secondary.opacity(0.45)) }
        return AnyShapeStyle(plugged ? pluggedColor : batteryColor)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 5)
            Text(title).foregroundStyle(.secondary)
        }
    }

    static func summary(of segment: BatteryTimeline.Segment) -> String {
        let minutes = max(0, Int(segment.lastSample.timeIntervalSince(segment.firstSample) / 60))
        let duration = minutes >= 60 ? "\(minutes / 60) 小時 \(minutes % 60) 分" : "\(minutes) 分"
        let change = segment.lastLevel - segment.firstLevel
        let changeText = change > 0 ? "+\(change)%" : (change < 0 ? "−\(-change)%" : "±0%")
        return "\(segment.plugged ? "接上電源" : "使用電池") \(duration) · \(changeText)"
    }
}
