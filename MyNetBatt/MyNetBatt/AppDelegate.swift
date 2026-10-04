import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin
import UserNotifications

// MARK: - 系統控制核心
class AppDelegate: NSObject, NSApplicationDelegate {
    var netItem: NSStatusItem!
    var batItem: NSStatusItem!
    /// 只在設定打開時才建立，關閉時移除，隱藏的項目不會在背景跟著取樣結果重繪。
    private var metricItems: [MetricBarView.Metric: NSStatusItem] = [:]
    var netPopover: NSPopover!
    var batPopover: NSPopover!
    var settingsWindow: NSWindow?
    private var settingsWindowCloseObserver: NSObjectProtocol?
    
    let monitor = SystemMonitor()
    private var cancellables = Set<AnyCancellable>()
    private lazy var floatWindow = FloatWindowController(monitor: monitor)

    /// 這個程序是否為重複啟動、即將自行結束的實例。
    private var isDuplicateInstance = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 已有另一個 MyNetBatt 在執行時直接結束，避免選單列出現兩組圖示、兩邊同時取樣與寫入資料。
        if Self.hasEarlierRunningInstance() {
            isDuplicateInstance = true
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        setupPopovers()
        setupStatusBar()
        
        monitor.layoutChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusBarWidths() }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsWindow), name: NSNotification.Name("OpenSettings"), object: nil)

        UNUserNotificationCenter.current().delegate = BatteryNotifier.shared

        // 主題與懸浮視窗的設定改變時重新套用。
        monitor.appearanceChanged
            .merge(with: monitor.floatWindowChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyAppearance() }
            .store(in: &cancellables)
        applyAppearance()

        HotKeyManager.shared.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleFloatWindow: self.monitor.showFloatWindow.toggle()
            case .openMainWindow: self.openSettingsWindow()
            }
        }
        HotKeyManager.shared.registerAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // 掛載、卸除或重新命名磁碟時立即更新儲存空間清單。
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(volumesDidChange), name: name, object: nil)
        }
        
        updateStatusBarWidths()
    }

    /// 只保留最早啟動的實例；同時啟動時以 PID 決定，確保恰好留下一個。
    private static func hasEarlierRunningInstance() -> Bool {
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentKey = (current.launchDate ?? .distantFuture, current.processIdentifier)
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { other in
            guard other.processIdentifier != current.processIdentifier, !other.isTerminated else { return false }
            return (other.launchDate ?? .distantFuture, other.processIdentifier) < currentKey
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 重複的實例沒有最新資料，不要覆寫正在執行那一份的紀錄。
        guard !isDuplicateInstance else { return }
        monitor.saveAppUsageHistory(force: true)
        monitor.saveBatteryHistory(force: true)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(self)
    }

    @objc private func volumesDidChange() {
        monitor.fetchStorageInfo()
    }

    @objc private func systemDidWake() {
        monitor.handleSystemWake()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }
    
    /// 只套用在自己的視窗上，不動 NSApp.appearance，選單列項目維持跟隨系統選單列的深淺。
    private var selectedAppearance: NSAppearance? {
        switch monitor.appearanceMode {
        case 1: return NSAppearance(named: .aqua)
        case 2: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func applyAppearance() {
        let appearance = selectedAppearance
        netPopover.appearance = appearance
        batPopover.appearance = appearance
        settingsWindow?.appearance = appearance
        floatWindow.update(appearance: appearance)
    }

    @objc func openSettingsWindow() {
        if settingsWindow == nil { setupSettingsWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupPopovers() {
        netPopover = NSPopover()
        netPopover.behavior = .transient
        netPopover.contentSize = NSSize(width: 380, height: 540)
        // 網路小視窗打開期間加快各 App 用量取樣。
        NotificationCenter.default.publisher(for: NSPopover.willShowNotification, object: netPopover)
            .sink { [weak self] _ in self?.monitor.setPerAppUsageVisible(true, source: "popover") }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: netPopover)
            .sink { [weak self] _ in
                self?.monitor.setPerAppUsageVisible(false, source: "popover")
                self?.netPopover.contentViewController = nil
            }
            .store(in: &cancellables)

        batPopover = NSPopover()
        batPopover.behavior = .transient
        batPopover.contentSize = NSSize(width: 360, height: 550)
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: batPopover)
            .sink { [weak self] _ in self?.batPopover.contentViewController = nil }
            .store(in: &cancellables)
    }

    /// 小視窗的 SwiftUI 畫面只在顯示時存在：關閉後仍保留的話，會隨每次資料更新在背景重算
    /// （電池小視窗含 2880 根長條的 48 小時圖），因此每次打開才建立、關閉後釋放。
    private func show(_ popover: NSPopover, from item: NSStatusItem, content: () -> NSViewController) {
        guard let button = item.button else { return }
        if popover.contentViewController == nil { popover.contentViewController = content() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    
    private func setupStatusBar() {
        netItem = NSStatusBar.system.statusItem(withLength: 1)
        if let button = netItem.button {
            let host = NSHostingView(rootView: NetworkBarView(monitor: monitor).allowsHitTesting(false))
            host.layer?.backgroundColor = NSColor.clear.cgColor
            button.addSubview(host)
            button.action = #selector(toggleNetPopover)
        }

        batItem = NSStatusBar.system.statusItem(withLength: 1)
        if let button = batItem.button {
            let host = NSHostingView(rootView: BatteryBarView(monitor: monitor).allowsHitTesting(false))
            host.layer?.backgroundColor = NSColor.clear.cgColor
            button.addSubview(host)
            button.action = #selector(toggleBatPopover)
        }
    }
    
    private func syncMetricItem(_ metric: MetricBarView.Metric, visible: Bool) {
        if visible, metricItems[metric] == nil {
            let width = MetricBarView.width
            let item = NSStatusBar.system.statusItem(withLength: width)
            if let button = item.button {
                let host = NSHostingView(rootView: MetricBarView(monitor: monitor, metric: metric).allowsHitTesting(false))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 22)
                button.addSubview(host)
                button.target = self
                button.action = #selector(openSystemTab)
            }
            metricItems[metric] = item
        } else if !visible, let item = metricItems.removeValue(forKey: metric) {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    @objc private func openSystemTab() {
        monitor.mainWindowTab = "system"
        openSettingsWindow()
    }

    @objc func updateStatusBarWidths() {
        syncMetricItem(.disk, visible: monitor.showDiskItem)
        syncMetricItem(.memory, visible: monitor.showMemItem)
        syncMetricItem(.cpu, visible: monitor.showCpuItem)

        if let btn = netItem.button {
            var nW: CGFloat = 6
            if monitor.showNetChart { nW += 32 }
            if monitor.showNetSpeed { nW += monitor.netSpeedTextWidth }
            if monitor.showNetChart && monitor.showNetSpeed { nW += 4 }
            let finalNetWidth = max(nW, 1)
            netItem.length = finalNetWidth
            btn.subviews.first?.frame = NSRect(x: 0, y: 0, width: finalNetWidth, height: 22)
        }
        
        if let btn = batItem.button {
            var bW: CGFloat = 8
            // 稍微增加寬度以完美容納 "100%"，避免被截斷成 ...
            if monitor.showBatText { bW += 42 }
            if monitor.showBatIcon { bW += monitor.batIconLarge ? 28 : 22 }
            if monitor.showBatText && monitor.showBatIcon { bW += 4 }
            let finalBatWidth = max(bW, 1)
            batItem.length = finalBatWidth
            btn.subviews.first?.frame = NSRect(x: 0, y: 0, width: finalBatWidth, height: 22)
        }
        
        netItem.isVisible = monitor.showNetModule
        batItem.isVisible = monitor.showBatModule
    }
    
    /// 監控中心視窗只在開啟時建立、關閉時釋放：隱藏的 SwiftUI 視窗仍會隨每次資料更新重算
    /// （包含最多 2880 點的電量圖），常駐會讓 App 持續吃掉兩成以上 CPU。
    private func setupSettingsWindow() {
        let hostingController = NSHostingController(rootView: MainWindowView(monitor: monitor))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MyNetBatt 監控中心"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MyNetBattMainWindow")
        window.appearance = selectedAppearance
        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.settingsWindowCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.settingsWindowCloseObserver = nil
                self.settingsWindow = nil
            }
        }
        settingsWindow = window
    }

    @objc func toggleNetPopover(_ sender: AnyObject?) {
        if netPopover.isShown { netPopover.performClose(sender) }
        else { show(netPopover, from: netItem) { NSHostingController(rootView: NetworkPopoverView(monitor: monitor)) } }
    }

    @objc func toggleBatPopover(_ sender: AnyObject?) {
        if batPopover.isShown { batPopover.performClose(sender) }
        else { show(batPopover, from: batItem) { NSHostingController(rootView: BatteryPopoverView(monitor: monitor)) } }
    }
}
