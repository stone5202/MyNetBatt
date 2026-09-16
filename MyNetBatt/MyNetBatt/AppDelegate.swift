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
    var settingsWindow: NSWindow!
    
    let monitor = SystemMonitor()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupPopovers()
        setupStatusBar()
        setupSettingsWindow()
        
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
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupPopovers() {
        netPopover = NSPopover()
        netPopover.behavior = .transient
        netPopover.contentSize = NSSize(width: 380, height: 540)
        netPopover.contentViewController = NSHostingController(rootView: NetworkPopoverView(monitor: monitor))

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
    
    private func setupSettingsWindow() {
        let hostingController = NSHostingController(rootView: MainWindowView(monitor: monitor))
        settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.title = "MyNetBatt 監控中心"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
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
