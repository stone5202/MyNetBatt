import SwiftUI

// MARK: - 儲存空間頁
struct StorageDetailView: View {
    @Bindable var monitor: SystemMonitor
    @Bindable private var scanner = StorageScanner.shared

    var body: some View {
        PageScroll {
            PageHeader(
                title: "儲存空間",
                subtitle: String(localized: "Macintosh HD 可用 \(monitor.diskFreeStr)（共 \(monitor.diskTotalStr)）"),
                symbol: MainTab.storage.symbol, color: MainTab.storage.color
            )
            StorageVolumesCard(monitor: monitor)
            FolderSizesPanel(monitor: monitor, scanner: scanner)
            LargeFilesPanel(monitor: monitor, scanner: scanner)
        }
    }
}

/// 資料夾大小：可加入、移除資料夾，掃描時顯示進度。
private struct FolderSizesPanel: View {
    @Bindable var monitor: SystemMonitor
    @Bindable var scanner: StorageScanner

    var body: some View {
        Panel(title: "資料夾大小", symbol: "folder.fill", color: .blue, accessory: {
            HStack(spacing: 8) {
                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                    Text("掃描「\(scanner.currentFolder)」… \(scanner.scannedCount) 個檔案")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("停止") { scanner.cancel() }.controlSize(.small)
                } else {
                    if let last = scanner.lastScan {
                        Text("更新於 \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("加入資料夾…") { scanner.addFolder() }
                        Button("恢復預設資料夾") { scanner.resetFolders() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        scanner.scan()
                    } label: {
                        Label(scanner.lastScan == nil ? "開始掃描" : "重新掃描", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }) {
            let results = Dictionary(scanner.folderResults.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let peak = Double(max(scanner.folderResults.map(\.bytes).max() ?? 1, 1))
            VStack(spacing: 0) {
                ForEach(scanner.folders, id: \.self) { path in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(FileManager.default.displayName(atPath: path)).lineLimit(1)
                                Spacer()
                                if let result = results[path] {
                                    switch result.status {
                                    case .denied:
                                        Button {
                                            scanner.openFilesAndFoldersSettings()
                                        } label: {
                                            Label("沒有存取權限", systemImage: "lock.fill")
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                        .help("到「系統設定 › 隱私權與安全性 › 檔案與檔案夾」允許 MyNetBatt 存取，再重新掃描")
                                    case .partial(let count):
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .help(String(localized: "有 \(count) 個項目讀不到，大小只包含讀得到的部分"))
                                        Text(monitor.formatStorageBytesForUI(result.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                                    case .complete:
                                        Text(monitor.formatStorageBytesForUI(result.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                                    }
                                } else {
                                    Text(FileManager.default.fileExists(atPath: path) ? "--" : String(localized: "找不到資料夾"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            MeterBar(value: Double(results[path]?.bytes ?? 0), total: peak, color: .blue, height: 5)
                        }
                        Menu {
                            Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("從清單移除", role: .destructive) { scanner.removeFolder(path) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.vertical, 8)
                    if path != scanner.folders.last { Divider() }
                }
            }
            if scanner.lastScan != nil {
                Text("大小包含隱藏檔；大型檔案清單不列出隱藏檔。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if scanner.lastScan == nil, !scanner.isScanning {
                Text("按「開始掃描」計算各資料夾的大小並找出大型檔案。第一次掃描「桌面」「文件」「下載項目」時，系統會詢問是否允許 MyNetBatt 存取；MyNetBatt 只讀取檔案大小，不讀取內容。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 最大的檔案：可在 Finder 中顯示或移到垃圾桶。
private struct LargeFilesPanel: View {
    @Bindable var monitor: SystemMonitor
    @Bindable var scanner: StorageScanner
    @State private var pendingTrash: StorageScanner.LargeItem?
    @State private var errorMessage: String?
    @State private var showsAll = false

    var body: some View {
        Panel(title: "大型檔案", symbol: "doc.fill", color: .orange, accessory: {
            Text("100 MB 以上").font(.caption).foregroundStyle(.secondary)
        }) {
            if scanner.largeItems.isEmpty {
                if scanner.lastScan == nil {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "尚未掃描", message: "掃描資料夾後，這裡會列出佔用最多空間的檔案。")
                } else if scanner.hasIncompleteResults {
                    // 有資料夾讀不到時，不能斷定沒有大型檔案。
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "讀得到的部分沒有 100 MB 以上的檔案", message: "有資料夾無法完整讀取，請在「資料夾大小」查看標示並允許存取後重新掃描。")
                } else {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "沒有 100 MB 以上的檔案")
                }
            } else {
                let items = showsAll ? scanner.largeItems : Array(scanner.largeItems.prefix(8))
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        LargeFileRow(monitor: monitor, item: item, onReveal: { scanner.revealInFinder(item) }, onTrash: { pendingTrash = item })
                        if item.id != items.last?.id { Divider() }
                    }
                }
                if scanner.largeItems.count > 8 {
                    Button(showsAll ? "收合" : "顯示全部 \(scanner.largeItems.count) 個") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .confirmationDialog(
            "要把「\(pendingTrash?.name ?? "")」移到垃圾桶嗎？",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })
        ) {
            Button("移到垃圾桶", role: .destructive) {
                guard let item = pendingTrash else { return }
                pendingTrash = nil
                Task { errorMessage = await scanner.moveToTrash(item) }
            }
            Button("取消", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("可以從垃圾桶復原；清空垃圾桶後才會真正釋放空間。")
        }
        .alert("無法移到垃圾桶", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct LargeFileRow: View {
    @Bindable var monitor: SystemMonitor
    let item: StorageScanner.LargeItem
    let onReveal: () -> Void
    let onTrash: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 10)
            if let modified = item.modified {
                Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(monitor.formatStorageBytesForUI(item.bytes))
                .font(.callout.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 78, alignment: .trailing)
            HStack(spacing: 2) {
                Button(action: onReveal) { Image(systemName: "magnifyingglass") }
                    .help("在 Finder 中顯示")
                Button(action: onTrash) { Image(systemName: "trash") }
                    .help("移到垃圾桶")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在 Finder 中顯示", action: onReveal)
            Button("拷貝路徑") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button("移到垃圾桶", role: .destructive, action: onTrash)
        }
    }
}
