import Foundation
import Darwin

/// 找出某個程序屬於哪個 App，讓 Helper、XPC 服務等的流量算在所屬的 App 上。
/// 取樣在背景執行緒進行，因此以 lock 保護快取。
nonisolated final class AppOwnerResolver: @unchecked Sendable {
    static let shared = AppOwnerResolver()

    struct Owner: Sendable, Equatable {
        /// .app 的檔名（不含副檔名），不隨系統語言改變，可當作用量紀錄的 key。
        let name: String
        let bundlePath: String
    }

    private typealias ResponsiblePidFunction = @convention(c) (pid_t) -> pid_t

    private let lock = NSLock()
    private var cache: [Int: (process: String, owner: Owner?)] = [:]
    /// 系統用來判斷「這個程序由哪個 App 負責」的函式（例如 WebKit 的網路程序 → Safari）；找不到時略過。
    private let responsiblePid: ResponsiblePidFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePidFunction.self)
    }()

    /// 不屬於任何 App（系統服務、指令列工具）時回傳 nil。
    func owner(pid: Int, processName: String) -> Owner? {
        lock.lock()
        defer { lock.unlock() }
        // pid 會被重複使用，名稱不同就視為另一個程序。
        if let cached = cache[pid], cached.process == processName { return cached.owner }
        var owner = Self.bundle(containing: Self.executablePath(of: pid_t(pid)))
        if owner == nil, let responsiblePid {
            let responsible = responsiblePid(pid_t(pid))
            if responsible > 0, responsible != pid_t(pid) {
                owner = Self.bundle(containing: Self.executablePath(of: responsible))
            }
        }
        cache[pid] = (processName, owner)
        return owner
    }

    /// 只保留這一輪還存在的程序，避免快取無限增長。
    func retain(pids: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count > pids.count { cache = cache.filter { pids.contains($0.key) } }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 路徑中最外層的 .app；Helper 位在主 App 的 bundle 裡，取最外層才會歸到主 App。
    private static func bundle(containing path: String?) -> Owner? {
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let name = String(components[index].dropLast(4))
        let bundlePath = "/" + components[...index].joined(separator: "/")
        guard !name.isEmpty, isUserFacing(bundlePath) else { return nil }
        return Owner(name: name, bundlePath: bundlePath)
    }

    /// 系統框架裡以 .app 形式存在的背景服務（如 identityservicesd.app）不算 App。
    static func isUserFacing(_ bundlePath: String) -> Bool {
        !bundlePath.hasPrefix("/System/Library/PrivateFrameworks/") && !bundlePath.hasPrefix("/System/Library/Frameworks/")
    }
}
