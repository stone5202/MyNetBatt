import Foundation
import ServiceManagement

@MainActor
final class PrivilegedHelperManager: ObservableObject {
    static let shared = PrivilegedHelperManager()

    enum RegistrationState: String {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    @Published private(set) var registrationState: RegistrationState = .unknown
    @Published private(set) var isLowPowerModeEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: PrivilegedHelperConstants.daemonPlistName)
    private var connection: NSXPCConnection?

    private init() {
        refreshRegistrationState()
        refreshLowPowerMode()
    }

    var statusText: String {
        switch registrationState {
        case .enabled:
            return isLowPowerModeEnabled ? "已開啟" : "已關閉"
        case .requiresApproval:
            return "等待系統核准"
        case .notRegistered:
            return "尚未啟用控制"
        case .notFound:
            return "找不到 Helper"
        case .unknown:
            return "讀取中"
        }
    }

    func refreshRegistrationState() {
        switch service.status {
        case .notRegistered:
            registrationState = .notRegistered
        case .enabled:
            registrationState = .enabled
        case .requiresApproval:
            registrationState = .requiresApproval
        case .notFound:
            registrationState = .notFound
        @unknown default:
            registrationState = .unknown
        }
    }

    func registerHelper() {
        lastError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            try service.register()
            refreshRegistrationState()

            if registrationState == .enabled {
                refreshLowPowerMode()
            } else if registrationState == .requiresApproval {
                lastError = "Helper 已註冊，但 macOS 尚未核准。請到「系統設定 → 一般 → 登入項目與延伸功能」允許 MyNetBatt 在背景執行。"
            }
        } catch {
            refreshRegistrationState()
            lastError = "註冊 Privileged Helper 失敗：\(error.localizedDescription)"
        }
    }

    func unregisterHelper() {
        lastError = nil
        isBusy = true
        defer { isBusy = false }

        invalidateConnection()
        do {
            try service.unregister()
            refreshRegistrationState()
        } catch {
            refreshRegistrationState()
            lastError = "移除 Privileged Helper 失敗：\(error.localizedDescription)"
        }
    }

    func refreshLowPowerMode() {
        lastError = nil
        refreshRegistrationState()

        guard registrationState == .enabled else {
            if let localValue = Self.readLowPowerModeLocally() {
                isLowPowerModeEnabled = localValue
            }
            return
        }

        guard let proxy = remoteProxy() else {
            if let localValue = Self.readLowPowerModeLocally() {
                isLowPowerModeEnabled = localValue
            }
            return
        }

        proxy.getLowPowerMode { [weak self] enabled, errorText in
            Task { @MainActor in
                guard let self else { return }
                if let errorText, !errorText.isEmpty {
                    self.lastError = errorText
                } else {
                    self.isLowPowerModeEnabled = enabled
                }
            }
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        lastError = nil
        refreshRegistrationState()

        guard registrationState == .enabled else {
            registerHelper()
            refreshRegistrationState()
            guard registrationState == .enabled else { return }
            setLowPowerMode(enabled)
            return
        }

        guard let proxy = remoteProxy() else { return }
        isBusy = true

        proxy.setLowPowerMode(enabled) { [weak self] success, errorText in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if success {
                    self.isLowPowerModeEnabled = enabled
                    self.lastError = nil
                } else {
                    self.lastError = errorText ?? "低耗電模式切換失敗。"
                    self.refreshLowPowerMode()
                }
            }
        }
    }

    private func remoteProxy() -> MyNetBattPrivilegedHelperProtocol? {
        let connection: NSXPCConnection

        if let existing = self.connection {
            connection = existing
        } else {
            let newConnection = NSXPCConnection(
                machServiceName: PrivilegedHelperConstants.machServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(with: MyNetBattPrivilegedHelperProtocol.self)
            newConnection.setCodeSigningRequirement(PrivilegedHelperConstants.helperSigningRequirement)
            newConnection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.invalidateConnection() }
            }
            newConnection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.invalidateConnection() }
            }
            newConnection.resume()
            self.connection = newConnection
            connection = newConnection
        }

        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.lastError = "無法連線到 Privileged Helper：\(error.localizedDescription)"
                self?.invalidateConnection()
            }
        } as? MyNetBattPrivilegedHelperProtocol
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    nonisolated private static func readLowPowerModeLocally() -> Bool? {
        let batt = runCommand("/usr/bin/pmset", ["-g", "batt"])
        let custom = runCommand("/usr/bin/pmset", ["-g", "custom"])
        guard !custom.isEmpty else { return nil }

        let sectionName: String
        if batt.localizedCaseInsensitiveContains("AC Power") {
            sectionName = "AC Power"
        } else {
            sectionName = "Battery Power"
        }

        guard let sectionRange = custom.range(of: sectionName + ":") else {
            return parseLowPowerMode(from: custom)
        }

        let tail = String(custom[sectionRange.upperBound...])
        let section = tail.components(separatedBy: "\n\n").first ?? tail
        return parseLowPowerMode(from: section)
    }

    nonisolated private static func parseLowPowerMode(from text: String) -> Bool? {
        let pattern = #"(?m)^\s*lowpowermode\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return text[range] == "1"
    }

    nonisolated private static func runCommand(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
