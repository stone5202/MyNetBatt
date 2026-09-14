import Foundation

final class HelperService: NSObject, MyNetBattPrivilegedHelperProtocol {
    func getLowPowerMode(withReply reply: @escaping (Bool, String?) -> Void) {
        guard let enabled = Self.readLowPowerMode() else {
            reply(false, "無法讀取目前低耗電模式狀態。")
            return
        }
        reply(enabled, nil)
    }

    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let value = enabled ? "1" : "0"
        let result = Self.runCommand("/usr/bin/pmset", ["-a", "lowpowermode", value])

        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            reply(false, detail.isEmpty ? "pmset 執行失敗（exit \(result.exitCode)）。" : detail)
            return
        }

        guard let actual = Self.readLowPowerMode() else {
            reply(false, "已執行 pmset，但無法重新讀取狀態。")
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
        let pattern = #"(?m)^\s*lowpowermode\s+(\d+)"#
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
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
