import SwiftUI
import AppKit

// MARK: - 資料夾大小與大型檔案

/// 掃描使用者的常用資料夾（以及自行加入的資料夾），算出各資料夾大小並列出最大的檔案。
/// 只讀取檔案大小，不讀檔案內容；第一次掃描「桌面」「文件」「下載項目」時系統會詢問是否允許。
@MainActor
@Observable
final class StorageScanner {
    static let shared = StorageScanner()

    /// 一個資料夾的掃描結果是否完整。
    nonisolated enum ScanStatus: Equatable, Sendable {
        case complete
        /// 有這麼多個項目讀不到（權限不足或讀取錯誤），大小只算得到讀得到的部分。
        case partial(Int)
        /// 整個資料夾都讀不到，通常是沒有取得存取權限。
        case denied
    }

    nonisolated struct FolderResult: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        var bytes: Int64
        var status: ScanStatus = .complete
        var name: String { FileManager.default.displayName(atPath: path) }
    }

    nonisolated struct LargeItem: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        let bytes: Int64
        let modified: Date?
        let isPackage: Bool
        var name: String { FileManager.default.displayName(atPath: path) }
        var folder: String { (path as NSString).deletingLastPathComponent }
    }

    /// 預設掃描的資料夾；路徑不存在的會略過。
    static let defaultFolders: [String] = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
        .map { NSHomeDirectory() + "/" + $0 }

    /// 大型檔案的門檻與最多列出幾筆。
    nonisolated static let largeItemThreshold: Int64 = 100_000_000
    nonisolated static let largeItemLimit = 40

    var folders: [String] = UserDefaults.standard.stringArray(forKey: "storageScanFolders") ?? StorageScanner.defaultFolders {
        didSet { UserDefaults.standard.set(folders, forKey: "storageScanFolders") }
    }
    var folderResults: [FolderResult] = []
    var largeItems: [LargeItem] = []
    var isScanning = false
    /// 已經看過的檔案數，掃描時顯示進度。
    var scannedCount = 0
    var currentFolder = ""
    var lastScan: Date?
    private var scanTask: Task<Void, Never>?

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "加入")
        panel.message = String(localized: "選擇要計算大小的資料夾。MyNetBatt 只讀取檔案大小，不會讀取檔案內容。")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        let kept = Self.keepCurrent(results: folderResults, items: largeItems, folders: folders)
        folderResults = kept.results
        largeItems = kept.items
    }

    /// 有資料夾讀不到時，「大型檔案」不能說成「沒有」。
    var hasIncompleteResults: Bool { folderResults.contains { $0.status != .complete } }

    func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func resetFolders() {
        folders = Self.defaultFolders
    }

    func cancel() {
        scanTask?.cancel()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scannedCount = 0
        let targets = folders.filter { FileManager.default.fileExists(atPath: $0) }
        scanTask = Task.detached(priority: .utility) {
            var results: [FolderResult] = []
            var large: [LargeItem] = []
            for folder in targets {
                if Task.isCancelled { break }
                let name = FileManager.default.displayName(atPath: folder)
                await MainActor.run { StorageScanner.shared.currentFolder = name }
                let outcome = Self.scanFolder(folder) { count in
                    Task { @MainActor in StorageScanner.shared.scannedCount += count }
                }
                results.append(FolderResult(path: folder, bytes: outcome.bytes, status: outcome.status))
                large.append(contentsOf: outcome.items)
            }
            let cancelled = Task.isCancelled
            let finalResults = results, finalItems = large
            await MainActor.run {
                let scanner = StorageScanner.shared
                if !cancelled {
                    // 掃描期間被移除的資料夾不要再放回結果裡。
                    let kept = Self.keepCurrent(results: finalResults, items: finalItems, folders: scanner.folders)
                    scanner.folderResults = kept.results.sorted { $0.bytes > $1.bytes }
                    scanner.largeItems = kept.items
                    scanner.lastScan = Date()
                }
                scanner.isScanning = false
                scanner.currentFolder = ""
            }
        }
    }

    nonisolated struct ScanOutcome: Sendable {
        var bytes: Int64
        var items: [LargeItem]
        var status: ScanStatus
    }

    /// 回傳資料夾總大小（含隱藏檔）、其中的大型項目與讀取狀態。
    /// App、照片圖庫這類「套件」視為一個項目，大小為其中所有檔案的總和；大型項目清單不列隱藏檔。
    nonisolated static func scanFolder(_ path: String, progress: (Int) -> Void) -> ScanOutcome {
        let root = URL(fileURLWithPath: path)
        // 連資料夾本身都列不出內容，通常是沒有存取權限（例如在系統設定拒絕了「文件」）。
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return ScanOutcome(bytes: 0, items: [], status: .denied)
        }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isPackageKey, .contentModificationDateKey]
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in unreadable += 1; return true }
        ) else { return ScanOutcome(bytes: 0, items: [], status: .denied) }

        var total: Int64 = 0
        var items: [LargeItem] = []
        var package: (path: String, bytes: Int64, modified: Date?, hidden: Bool)?
        var pending = 0
        let rootPath = root.standardizedFileURL.path

        func closePackage() {
            if let open = package, open.bytes >= largeItemThreshold, !open.hidden {
                items.append(LargeItem(path: open.path, bytes: open.bytes, modified: open.modified, isPackage: true))
            }
            package = nil
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let itemPath = url.path
            if let open = package, !itemPath.hasPrefix(open.path + "/") { closePackage() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { unreadable += 1; continue }
            if values.isPackage == true, package == nil {
                package = (itemPath, 0, values.contentModificationDate, isHidden(itemPath, under: rootPath))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            total += size
            if package != nil {
                package?.bytes += size
            } else if size >= largeItemThreshold, !isHidden(itemPath, under: rootPath) {
                items.append(LargeItem(path: itemPath, bytes: size, modified: values.contentModificationDate, isPackage: false))
            }
            pending += 1
            if pending >= 2000 { progress(pending); pending = 0 }
        }
        closePackage()
        if pending > 0 { progress(pending) }
        return ScanOutcome(bytes: total, items: items, status: unreadable > 0 ? .partial(unreadable) : .complete)
    }

    /// 路徑在掃描根目錄之下的任何一層是隱藏的（名稱以「.」開頭）。
    nonisolated static func isHidden(_ path: String, under root: String) -> Bool {
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// 只保留目前清單裡的資料夾結果，以及位於這些資料夾之內的大型項目；同時掃描父、子資料夾時同一個檔案只列一次。
    nonisolated static func keepCurrent(results: [FolderResult], items: [LargeItem], folders: [String]) -> (results: [FolderResult], items: [LargeItem]) {
        let current = Set(folders)
        let keptResults = results.filter { current.contains($0.path) }
        var seen = Set<String>()
        let keptItems = items
            .filter { item in folders.contains { item.path.hasPrefix($0 + "/") } }
            .sorted { $0.bytes > $1.bytes }
            .filter { seen.insert($0.path).inserted }
        return (keptResults, Array(keptItems.prefix(largeItemLimit)))
    }

    /// 移到垃圾桶後，所有包含這個檔案的資料夾（父、子資料夾都在清單裡時兩個都算過）都要扣掉。
    nonisolated static func subtracting(_ item: LargeItem, from results: [FolderResult]) -> [FolderResult] {
        results.map { result in
            guard item.path.hasPrefix(result.path + "/") else { return result }
            var updated = result
            updated.bytes = max(0, result.bytes - item.bytes)
            return updated
        }
    }

    func revealInFinder(_ item: LargeItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// 移到垃圾桶（可以從垃圾桶復原）；回傳錯誤訊息。
    func moveToTrash(_ item: LargeItem) async -> String? {
        do {
            _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)])
            largeItems.removeAll { $0.id == item.id }
            folderResults = Self.subtracting(item, from: folderResults)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
