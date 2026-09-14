import Foundation
import ServiceManagement
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

    private let service = SMAppService.daemon(plistName: PrivilegedHelperConstants.daemonPlistName)
    private var connection: NSXPCConnection?
    private var lowPowerModeTimer: AnyCancellable?

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
        needsRepair = false
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
        needsRepair = false
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

    /// 重新註冊目前這一份 App bundle 內的 Helper。
    /// 這可修正從另一個下載目錄／舊 DerivedData 執行後，SMAppService 仍指向舊 Helper 的情況。
    func repairHelper() {
        lastError = nil
        needsRepair = false
        isBusy = true
        invalidateConnection()

        defer {
            isBusy = false
            refreshRegistrationState()
            refreshLowPowerMode()
        }

        do {
            if service.status != .notRegistered {
                try service.unregister()
            }
            try service.register()
            refreshRegistrationState()

            if registrationState == .requiresApproval {
                lastError = "Helper 已重新註冊，但 macOS 需要再次核准。請到「系統設定 → 一般 → 登入項目與延伸功能」允許 MyNetBatt 在背景執行。"
            }
        } catch {
            refreshRegistrationState()
            needsRepair = true
            lastError = "重新安裝 Privileged Helper 失敗：\(error.localizedDescription)"
        }
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
                    self.needsRepair = false

                    try? await Task.sleep(for: .milliseconds(500))
                    self.refreshLowPowerMode()
                } else {
                    self.lastError = errorText ?? "低耗電模式切換失敗。"
                    self.refreshLowPowerMode()
                }
            }
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
                self.lastError = "無法連線到 Privileged Helper：\(error.localizedDescription)\n請按「修復 Helper」重新註冊目前這一份 App 內的 Helper。"
                self.invalidateConnection()
            }
        } as? MyNetBattPrivilegedHelperProtocol
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }
}
