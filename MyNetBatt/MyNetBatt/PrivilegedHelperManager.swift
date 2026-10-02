import Foundation
import Combine
import ServiceManagement
import os

/// 可用 `log show --predicate 'subsystem == "com.stone5202.MyNetBatt"'` 查看 Helper 註冊與連線狀況。
private let helperLog = Logger(subsystem: "com.stone5202.MyNetBatt", category: "PrivilegedHelper")

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

    enum HelperError: LocalizedError {
        case proxyUnavailable
        case timeout
        case versionMismatch(running: String, expected: String)

        var errorDescription: String? {
            switch self {
            case .proxyUnavailable:
                return "無法建立 Privileged Helper 連線。"
            case .timeout:
                return "Privileged Helper 沒有回應。"
            case let .versionMismatch(running, expected):
                return "執行中的 Helper 版本（\(running)）與 App 內附版本（\(expected)）不一致。"
            }
        }
    }

    @Published private(set) var registrationState: RegistrationState = .unknown
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var needsRepair = false
    /// 舊版（3.2 以前）以 AppleScript 安裝到 /Library 的 Helper，需要移除一次才能改用 SMAppService。
    @Published private(set) var hasLegacyInstall = false

    private let daemon = SMAppService.daemon(plistName: PrivilegedHelperConstants.daemonPlistName)
    private let legacyHelperPath = "/Library/PrivilegedHelperTools/\(PrivilegedHelperConstants.legacyLabel)"
    private let legacyPlistPath = "/Library/LaunchDaemons/\(PrivilegedHelperConstants.legacyLabel).plist"
    private var connection: NSXPCConnection?
    private var powerStateObserver: AnyCancellable?
    private var verifiedHelperVersion = false

    private init() {
        refreshRegistrationState()
        refreshLowPowerMode()
        // 以系統通知取代每秒輪詢，狀態來源只有 ProcessInfo。
        powerStateObserver = NotificationCenter.default
            .publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLowPowerMode() }
    }

    var statusText: String {
        if hasLegacyInstall { return "需要更新 Helper" }
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
        hasLegacyInstall = files.fileExists(atPath: legacyHelperPath) || files.fileExists(atPath: legacyPlistPath)

        switch daemon.status {
        case .enabled: registrationState = .enabled
        case .requiresApproval: registrationState = .requiresApproval
        case .notRegistered: registrationState = .notRegistered
        case .notFound:
            // 從未註冊過的 daemon 也會回報 notFound；只要 plist 確實在 App 內，就視為「尚未啟用」。
            registrationState = bundledDaemonPlistExists ? .notRegistered : .notFound
        @unknown default: registrationState = .unknown
        }
    }

    private var bundledDaemonPlistExists: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedHelperConstants.daemonPlistName)")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 安裝或更新 Helper：必要時先移除舊版，再向 SMAppService 註冊。
    func registerHelper() {
        guard !isBusy else { return }
        lastError = nil
        needsRepair = false
        isBusy = true
        invalidateConnection()

        Task {
            defer {
                isBusy = false
                refreshLowPowerMode()
            }
            await performRegistration()
        }
    }

    private func performRegistration() async {
        defer { refreshRegistrationState() }

        if hasLegacyInstall {
            helperLog.notice("Removing legacy helper install")
            if let error = await removeLegacyInstall() {
                helperLog.error("Legacy removal failed: \(error, privacy: .public)")
                needsRepair = true
                lastError = "移除舊版 Privileged Helper 失敗：\(error)"
                return
            }
        }

        // 開發期間曾以舊 label 註冊過 SMAppService；盡量取消，避免系統設定裡留下失效的背景項目。
        let staleDaemon = SMAppService.daemon(plistName: "\(PrivilegedHelperConstants.legacyLabel).plist")
        if staleDaemon.status != .notRegistered && staleDaemon.status != .notFound {
            do {
                try await staleDaemon.unregister()
                helperLog.notice("Unregistered stale daemon with legacy label")
            } catch {
                helperLog.error("Stale daemon unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            try daemon.register()
            helperLog.notice("Registered helper, status \(self.daemon.status.rawValue, privacy: .public)")
        } catch {
            helperLog.error("Register failed: \(error.localizedDescription, privacy: .public)")
            refreshRegistrationState()
            if registrationState != .requiresApproval {
                needsRepair = true
                lastError = "註冊 Privileged Helper 失敗：\(error.localizedDescription)"
                return
            }
        }

        refreshRegistrationState()
        if registrationState == .requiresApproval {
            lastError = "請在「系統設定 › 一般 › 登入項目與延伸功能」允許 MyNetBatt 在背景執行，之後切換低耗電模式不需輸入密碼。"
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// 先取消再重新註冊，讓 launchd 依目前 App bundle 內的 plist 與 Helper 重建工作
    /// （launchd 會保留首次註冊時產生的 launch constraint，只換 App 不會更新）。
    private func reregister() async {
        invalidateConnection()
        if daemon.status == .enabled || daemon.status == .requiresApproval {
            do {
                try await daemon.unregister()
                helperLog.notice("Unregistered helper for re-registration")
            } catch {
                helperLog.error("Unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await performRegistration()
    }

    func unregisterHelper() {
        guard !isBusy else { return }
        lastError = nil
        needsRepair = false
        isBusy = true
        invalidateConnection()

        Task {
            defer {
                isBusy = false
                refreshRegistrationState()
            }
            if hasLegacyInstall, let error = await removeLegacyInstall() {
                lastError = "移除舊版 Privileged Helper 失敗：\(error)"
            }
            do {
                try await daemon.unregister()
            } catch {
                lastError = "移除 Privileged Helper 失敗：\(error.localizedDescription)"
            }
        }
    }

    /// 重新註冊目前 App bundle 內的 Helper。
    func repairHelper() {
        guard !isBusy else { return }
        if registrationState == .requiresApproval && !hasLegacyInstall {
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        lastError = nil
        needsRepair = false
        isBusy = true
        helperLog.notice("Repair requested, status \(self.daemon.status.rawValue, privacy: .public)")
        Task {
            defer {
                isBusy = false
                refreshLowPowerMode()
            }
            await reregister()
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// UI 狀態直接採用 ProcessInfo，和狀態列小視窗使用同一個 macOS 狀態來源。
    /// Helper 只負責需要 root 權限的寫入。
    func refreshLowPowerMode() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard !isBusy else { return }
        lastError = nil
        needsRepair = false
        refreshRegistrationState()

        guard !hasLegacyInstall else {
            needsRepair = true
            lastError = "Helper 的安裝方式已更新，請按「更新 Helper」移除舊版（需輸入一次管理員密碼）。"
            return
        }
        guard registrationState == .enabled else {
            switch registrationState {
            case .requiresApproval:
                lastError = "Helper 尚未獲准執行，請在「系統設定 › 一般 › 登入項目與延伸功能」允許 MyNetBatt。"
            case .notFound:
                needsRepair = true
                lastError = "App 內找不到 Helper，請重新建置 App。"
            default:
                lastError = "請先啟用 Helper；核准一次後，切換低耗電模式不需再授權。"
            }
            refreshLowPowerMode()
            return
        }

        isBusy = true
        Task {
            defer {
                isBusy = false
                refreshLowPowerMode()
            }
            do {
                do {
                    try await ensureCurrentHelperVersion()
                } catch {
                    // Helper 已註冊卻無法啟動（例如 launchd 保留了過期的註冊資料）：自動重新註冊後再試一次。
                    helperLog.error("Helper unreachable, re-registering: \(error.localizedDescription, privacy: .public)")
                    await reregister()
                    guard registrationState == .enabled else { return }
                    try await ensureCurrentHelperVersion()
                }
                let (success, errorText) = try await send { proxy, done in
                    proxy.setLowPowerMode(enabled) { done(($0, $1)) }
                }
                helperLog.notice("setLowPowerMode(\(enabled, privacy: .public)) -> \(success, privacy: .public)")
                if success {
                    // 先採用 Helper 已確認的結果，系統通知會再同步一次。
                    isLowPowerModeEnabled = enabled
                } else {
                    needsRepair = true
                    lastError = errorText ?? "低耗電模式切換失敗。請修復 Helper 後再試一次。"
                }
            } catch {
                helperLog.error("Low power mode request failed: \(error.localizedDescription, privacy: .public)")
                invalidateConnection()
                needsRepair = true
                lastError = "無法使用 Privileged Helper：\(error.localizedDescription)\n請按「修復 Helper」重新註冊目前 App 內的 Helper。"
            }
        }
    }

    // MARK: - Helper 版本

    /// App 內附 Helper 的 CFBundleVersion（Helper 的 Info.plist 內嵌在執行檔中）。
    private var bundledHelperVersion: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(PrivilegedHelperConstants.helperExecutableName)") as CFURL
        return (CFBundleCopyInfoDictionaryForURL(url) as? [String: Any])?["CFBundleVersion"] as? String
    }

    /// App 更新後，launchd 可能仍在執行舊版 Helper；版本不符時請它結束，下一次連線就會啟動新版。
    private func ensureCurrentHelperVersion() async throws {
        guard !verifiedHelperVersion, let expected = bundledHelperVersion else { return }

        // getVersion 很輕量，Helper 能啟動時一秒內就會回覆；用較短逾時讓失敗時能更快自動修復。
        let running = try await send(timeout: 5) { proxy, done in proxy.getVersion { done($0) } }
        helperLog.notice("Helper version running \(running, privacy: .public), bundled \(expected, privacy: .public)")
        if running != expected {
            _ = try? await send(timeout: 3) { proxy, done in proxy.exitForUpdate { done(true) } }
            invalidateConnection()
            try await Task.sleep(for: .milliseconds(500))

            let relaunched = try await send(timeout: 5) { proxy, done in proxy.getVersion { done($0) } }
            guard relaunched == expected else {
                throw HelperError.versionMismatch(running: relaunched, expected: expected)
            }
        }
        verifiedHelperVersion = true
    }

    // MARK: - XPC

    /// 送出一個 XPC 請求並等待回覆。回覆、連線錯誤或逾時三者只會採用最先發生的一個。
    /// 首次連線需由 launchd 按需啟動 Helper，再執行數次 pmset，因此逾時設得較寬裕。
    private func send<T: Sendable>(
        timeout: TimeInterval = 15,
        _ body: @escaping (MyNetBattPrivilegedHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: error)
            }) as? MyNetBattPrivilegedHelperProtocol else {
                once.resume(throwing: HelperError.proxyUnavailable)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: HelperError.timeout)
            }
            body(proxy) { once.resume(returning: $0) }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: PrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: MyNetBattPrivilegedHelperProtocol.self)
        newConnection.setCodeSigningRequirement(PrivilegedHelperConstants.helperSigningRequirement)
        // Helper 閒置會自行結束，連線中斷屬正常情況；下次請求時重新建立即可。
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.invalidateConnection() }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidateConnection() }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
        verifiedHelperVersion = false
    }

    // MARK: - 舊版 Helper

    /// 移除 3.2 以前以 AppleScript 安裝的 launchd daemon。在背景執行 osascript，等待密碼時不會卡住 UI。
    private func removeLegacyInstall() async -> String? {
        let label = PrivilegedHelperConstants.legacyLabel
        let command = "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true; "
            + "/bin/rm -f \(shellQuote(legacyHelperPath)) \(shellQuote(legacyPlistPath))"
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"

        let error = await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? "管理員授權已取消或移除失敗。" : message
        }.value

        refreshRegistrationState()
        return error
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 確保 continuation 只被 resume 一次（XPC 回覆、錯誤處理與逾時可能同時發生）。
nonisolated private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
