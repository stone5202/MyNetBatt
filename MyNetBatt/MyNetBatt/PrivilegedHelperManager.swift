import Foundation
import Combine

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
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var needsRepair = false

    private let installedHelperPath = "/Library/PrivilegedHelperTools/\(PrivilegedHelperConstants.machServiceName)"
    private let installedPlistPath = "/Library/LaunchDaemons/\(PrivilegedHelperConstants.daemonPlistName)"
    private var connection: NSXPCConnection?
    private var lowPowerModeTimer: AnyCancellable?
    private var pendingLowPowerMode: Bool?
    private var pendingRequestID: UUID?

    private init() {
        refreshRegistrationState()
        refreshLowPowerMode()
        startLowPowerModeStateMonitor()
    }

    var statusText: String {
        switch registrationState {
        case .enabled:
            return isLowPowerModeEnabled ? "已開啟" : "已關閉"
        case .requiresApproval:
            return "等待系統核准"
        case .notRegistered:
            return "尚未啟用 Helper"
        case .notFound:
            return "找不到 Helper"
        case .unknown:
            return "讀取中"
        }
    }

    func refreshRegistrationState() {
        let files = FileManager.default
        registrationState = files.fileExists(atPath: installedHelperPath)
            && files.fileExists(atPath: installedPlistPath) ? .enabled : .notRegistered
    }

    func registerHelper() {
        installStandaloneHelper()
    }

    func unregisterHelper() {
        lastError = nil
        needsRepair = false
        isBusy = true
        defer { isBusy = false }

        invalidateConnection()
        let command = "/bin/launchctl bootout system/\(PrivilegedHelperConstants.machServiceName) >/dev/null 2>&1 || true; "
            + "/bin/rm -f \(shellQuote(installedHelperPath)) \(shellQuote(installedPlistPath))"
        if let error = runWithAdministratorPrivileges(command) {
            lastError = "移除 Privileged Helper 失敗：\(error)"
        }
        refreshRegistrationState()
    }

    /// 覆寫安裝目前 App bundle 內的 Helper；只會在安裝／更新時要求一次管理員密碼。
    func repairHelper() {
        invalidateConnection()
        installStandaloneHelper()
    }

    private func installStandaloneHelper() {
        lastError = nil
        needsRepair = false
        isBusy = true
        defer { isBusy = false }

        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/MyNetBattPrivilegedHelper")
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            registrationState = .notFound
            needsRepair = true
            lastError = "App 內找不到 MyNetBattPrivilegedHelper，請重新建置 App。"
            return
        }

        do {
            let plist: [String: Any] = [
                "Label": PrivilegedHelperConstants.machServiceName,
                "ProgramArguments": [installedHelperPath],
                "MachServices": [PrivilegedHelperConstants.machServiceName: true],
                "ProcessType": "Interactive"
            ]
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            let temporaryPlist = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(PrivilegedHelperConstants.machServiceName)-\(UUID().uuidString).plist")
            try plistData.write(to: temporaryPlist, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryPlist) }

            let label = PrivilegedHelperConstants.machServiceName
            let command = [
                "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
                "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
                "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(bundledHelper.path)) \(shellQuote(installedHelperPath))",
                "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(temporaryPlist.path)) \(shellQuote(installedPlistPath))",
                "/bin/launchctl bootstrap system \(shellQuote(installedPlistPath))"
            ].joined(separator: "; ")

            if let error = runWithAdministratorPrivileges(command) {
                throw NSError(
                    domain: "MyNetBatt.HelperInstaller",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: error]
                )
            }
            refreshRegistrationState()
            lastError = nil
            needsRepair = false
            refreshLowPowerMode()
        } catch {
            refreshRegistrationState()
            needsRepair = true
            lastError = "安裝 Privileged Helper 失敗：\(error.localizedDescription)"
        }
    }

    private func runWithAdministratorPrivileges(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var errorInfo: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        return (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "管理員授權已取消或安裝失敗。"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// UI 狀態直接採用 ProcessInfo，和狀態列小視窗使用同一個 macOS 狀態來源。
    /// Helper 只負責需要 root 權限的寫入。
    func refreshLowPowerMode() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func setLowPowerMode(_ enabled: Bool) {
        lastError = nil
        needsRepair = false
        refreshRegistrationState()

        guard registrationState == .enabled else {
            needsRepair = registrationState == .notFound
            lastError = registrationState == .notFound
                ? "App 內找不到 Helper，請重新建置 App。"
                : "請先安裝 Helper；只需輸入一次管理員密碼，之後切換低耗電模式不需再授權。"
            refreshLowPowerMode()
            return
        }

        guard let proxy = remoteProxy() else { return }
        isBusy = true
        pendingLowPowerMode = enabled
        let requestID = UUID()
        pendingRequestID = requestID

        proxy.setLowPowerMode(enabled) { [weak self] success, errorText in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingRequestID == requestID else { return }
                self.isBusy = false
                self.pendingLowPowerMode = nil
                self.pendingRequestID = nil

                if success {
                    self.isLowPowerModeEnabled = enabled
                    self.lastError = nil
                    self.needsRepair = false

                    try? await Task.sleep(for: .milliseconds(500))
                    self.refreshLowPowerMode()
                } else {
                    self.needsRepair = true
                    self.lastError = errorText ?? "低耗電模式切換失敗。請修復 Helper 後再試一次。"
                    self.refreshLowPowerMode()
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.pendingRequestID == requestID else { return }
            self.pendingRequestID = nil
            self.pendingLowPowerMode = nil
            self.invalidateConnection()
            self.isBusy = false
            self.needsRepair = true
            self.lastError = "Privileged Helper 沒有回應。請修復 Helper 後再試一次。"
            self.refreshLowPowerMode()
        }
    }

    private func startLowPowerModeStateMonitor() {
        lowPowerModeTimer?.cancel()
        lowPowerModeTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshLowPowerMode()
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
                Task { @MainActor in
                    self?.invalidateConnection()
                }
            }
            newConnection.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.invalidateConnection()
                }
            }
            newConnection.resume()
            self.connection = newConnection
            connection = newConnection
        }

        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.needsRepair = true
                let requestedMode = self.pendingLowPowerMode
                self.pendingLowPowerMode = nil
                self.pendingRequestID = nil
                self.invalidateConnection()
                let action = requestedMode == nil ? "" : "低耗電模式尚未切換。"
                self.lastError = "無法連線到 Privileged Helper：\(error.localizedDescription)\n\(action)請按一次「修復 Helper」重新註冊目前 App 內的 Helper。"
                self.refreshLowPowerMode()
            }
        } as? MyNetBattPrivilegedHelperProtocol
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }
}
