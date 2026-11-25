// 共用核心（見 CaptiveModels.swift 開頭說明）
import Foundation
import Combine

struct CaptiveLogEntry: Identifiable {
    enum Level { case info, success, warning }
    let id = UUID()
    let date: Date
    let text: String
    let level: Level
}

/// App 內的事件紀錄（選單與設定視窗看得到），同時寫進
/// ~/Library/Application Support/WiFiAutoLogin/events.log 方便除錯。
@MainActor
final class CaptiveLog: ObservableObject {
    static let shared = CaptiveLog()
    @Published private(set) var entries: [CaptiveLogEntry] = []

    private lazy var fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(CaptiveConfig.logFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.log")
    }()

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func add(_ text: String, _ level: CaptiveLogEntry.Level = .info) {
        let entry = CaptiveLogEntry(date: Date(), text: text, level: level)
        entries.insert(entry, at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
        let line = "\(stamp.string(from: entry.date)) \(text)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        appendToFile(line)
    }

    private func appendToFile(_ line: String) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: fileURL, to: old)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
    }

    var logFileURL: URL { fileURL }

    func allText() -> String {
        entries.reversed().map { "\(stamp.string(from: $0.date)) \($0.text)" }.joined(separator: "\n")
    }
}
