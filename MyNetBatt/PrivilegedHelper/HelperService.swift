import Foundation

final class HelperService: NSObject, MyNetBattPrivilegedHelperProtocol {
    /// 閒置一段時間後自行結束；launchd 會在下一次連線時按需重新啟動。
    /// 這樣 App 更新後，舊版 Helper 不會一直留在記憶體裡。
    private static let idleTimeout: TimeInterval = 60
    private var idleExitWorkItem: DispatchWorkItem?

    func scheduleIdleExit() {
        DispatchQueue.main.async {
            self.idleExitWorkItem?.cancel()
            let workItem = DispatchWorkItem { exit(0) }
            self.idleExitWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: workItem)
        }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        scheduleIdleExit()
    }

    func exitForUpdate(withReply reply: @escaping () -> Void) {
        reply()
        // 稍等一下讓回覆送出後再結束。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void) {
        defer { scheduleIdleExit() }
        guard let enabled = Self.readLowPowerMode() else {
            reply(false, "無法讀取目前低耗電模式狀態。")
            return
        }
        reply(enabled, nil)
    }

    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        defer { scheduleIdleExit() }
        let value = enabled ? "1" : "0"
        var result = Self.runCommand("/usr/bin/pmset", ["-a", "lowpowermode", value])
        if result.exitCode != 0 {
            // 支援高效能模式的機型把這個設定叫做 powermode（0 自動、1 低耗電、2 高效能）。
            result = Self.runCommand("/usr/bin/pmset", ["-a", "powermode", value])
        }

        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            reply(false, detail.isEmpty ? "pmset 執行失敗（exit \(result.exitCode)）。" : detail)
            return
        }

        // pmset 的輸出格式因機型而異，讀不回來不代表失敗；主程式會再以 ProcessInfo 確認實際狀態。
        guard let actual = Self.readLowPowerMode() else {
            reply(true, nil)
            return
        }

        guard actual == enabled else {
            reply(false, "pmset 已執行，但系統回報的低耗電模式狀態沒有改變。")
            return
        }

        reply(true, nil)
    }

    private static func readLowPowerMode() -> Bool? {
        let batt = runCommand("/usr/bin/pmset", ["-g", "batt"]).stdout
        let custom = runCommand("/usr/bin/pmset", ["-g", "custom"]).stdout
        guard !custom.isEmpty else { return nil }

        let sectionName = batt.localizedCaseInsensitiveContains("AC Power") ? "AC Power" : "Battery Power"

        if let sectionRange = custom.range(of: sectionName + ":") {
            let tail = String(custom[sectionRange.upperBound...])
            let section = tail.components(separatedBy: "\n\n").first ?? tail
            if let value = parseLowPowerMode(from: section) {
                return value
            }
        }

        return parseLowPowerMode(from: custom)
    }

    private static func parseLowPowerMode(from text: String) -> Bool? {
        // 支援高效能模式的機型列出的是 powermode，1 同樣代表低耗電。
        let pattern = #"(?m)^\s*(?:low)?powermode\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return text[range] == "1"
    }

    private static func runCommand(_ path: String, _ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // 先讀完 pipe 再等待結束；若先 waitUntilExit()，輸出超過 pipe buffer 時子程序會卡住。
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
