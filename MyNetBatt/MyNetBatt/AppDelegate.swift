import SwiftUI
import Network
import Foundation
import Combine
import Charts
import ServiceManagement
import Darwin

// MARK: - 系統控制核心
class AppDelegate: NSObject, NSApplicationDelegate {
    var netItem: NSStatusItem!
    var batItem: NSStatusItem!
    var netPopover: NSPopover!
    var batPopover: NSPopover!
    var settingsWindow: NSWindow?
    private var settingsWindowCloseObserver: NSObjectProtocol?
    
    let monitor = SystemMonitor()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupPopovers()
        setupStatusBar()
        
        monitor.layoutChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusBarWidths() }
            .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsWindow), name: NSNotification.Name("OpenSettings"), object: nil)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        updateStatusBarWidths()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.saveAppUsageHistory(force: true)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(self)
    }

    @objc private func systemDidWake() {
        monitor.handleSystemWake()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
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
        netPopover.contentViewController = NSHostingController(rootView: NetworkPopoverView(monitor: monitor))
        // 網路小視窗打開期間加快各 App 用量取樣。
        NotificationCenter.default.publisher(for: NSPopover.willShowNotification, object: netPopover)
            .sink { [weak self] _ in self?.monitor.setPerAppUsageVisible(true, source: "popover") }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: netPopover)
            .sink { [weak self] _ in self?.monitor.setPerAppUsageVisible(false, source: "popover") }
            .store(in: &cancellables)

        batPopover = NSPopover()
        batPopover.behavior = .transient
        batPopover.contentSize = NSSize(width: 360, height: 550)
        batPopover.contentViewController = NSHostingController(rootView: BatteryPopoverView(monitor: monitor))
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
    
    @objc func updateStatusBarWidths() {
        if let btn = netItem.button {
            var nW: CGFloat = 6
            if monitor.showNetChart { nW += 32 }
            if monitor.showNetSpeed { nW += 48 }
            if monitor.showNetChart && monitor.showNetSpeed { nW += 4 }
            let finalNetWidth = max(nW, 1)
            netItem.length = finalNetWidth
            btn.subviews.first?.frame = NSRect(x: 0, y: 0, width: finalNetWidth, height: 22)
        }
        
        if let btn = batItem.button {
            var bW: CGFloat = 8
            // 稍微增加寬度以完美容納 "100%"，避免被截斷成 ...
            if monitor.showBatText { bW += 42 }
            if monitor.showBatIcon { bW += 22 }
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
        else { if let btn = netItem.button { netPopover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) } }
    }

    @objc func toggleBatPopover(_ sender: AnyObject?) {
        if batPopover.isShown { batPopover.performClose(sender) }
        else { if let btn = batItem.button { batPopover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) } }
    }
}
