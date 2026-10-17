import AppKit
import WidgetKit

// MARK: - 介面語言
extension SystemMonitor {
    static let languageCodes: [Int: String] = [1: "zh-Hant", 2: "en"]

    /// 寫入 App 自己的 AppleLanguages（只影響 MyNetBatt），並告訴小工具用哪個語言。
    func applyLanguagePreference() {
        let defaults = UserDefaults.standard
        defaults.set(appLanguage, forKey: "appLanguage")
        let shared = UserDefaults(suiteName: WidgetSnapshot.appGroup)
        if let code = Self.languageCodes[appLanguage] {
            defaults.set([code], forKey: "AppleLanguages")
            shared?.set(code, forKey: "appLanguage")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
            shared?.removeObject(forKey: "appLanguage")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    var languageNeedsRelaunch: Bool { appLanguage != launchLanguage }

    /// 等目前的程序結束後再開啟一個新的（同時執行兩份時，後開的那份會自行結束）。
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open '\(path)'"]
        try? process.run()
        NSApp.terminate(nil)
    }
}
