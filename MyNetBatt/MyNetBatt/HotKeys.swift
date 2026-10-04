import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 全域快捷鍵
struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon 的修飾鍵遮罩（cmdKey、optionKey、controlKey、shiftKey）。
    var modifiers: UInt32
    var display: String
}

enum HotKeyAction: UInt32, CaseIterable {
    case toggleFloatWindow = 1
    case openMainWindow = 2

    var title: String {
        switch self {
        case .toggleFloatWindow: return "顯示／隱藏懸浮視窗"
        case .openMainWindow: return "打開監控中心"
        }
    }

    var defaultsKey: String { "hotKey.\(rawValue)" }
}

/// 以 Carbon 的 RegisterEventHotKey 註冊，不需要輔助使用權限。
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onAction: ((HotKeyAction) -> Void)?
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x4D4E_4254 // "MNBT"

    func binding(for action: HotKeyAction) -> HotKeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotKeyBinding.self, from: data)
    }

    /// 回傳是否註冊成功；組合鍵已被系統或其他 App 佔用時會失敗，且不會儲存。
    @discardableResult
    func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) -> Bool {
        unregister(action)
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            return true
        }
        guard register(binding, for: action) else {
            // 註冊失敗時恢復原本的快捷鍵。
            if let previous = self.binding(for: action) { _ = register(previous, for: action) }
            return false
        }
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
        return true
    }

    func registerAll() {
        for action in HotKeyAction.allCases {
            if let binding = binding(for: action) { _ = register(binding, for: action) }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        if let action = HotKeyAction(rawValue: id) { onAction?(action) }
    }

    private func register(_ binding: HotKeyBinding, for action: HotKeyAction) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers,
            EventHotKeyID(signature: Self.signature, id: action.rawValue),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[action] = ref
        return true
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in HotKeyManager.shared.fire(id) }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

/// 按一下開始錄製，接著按下組合鍵；Esc 取消，Delete 清除。
struct ShortcutRecorder: View {
    let action: HotKeyAction
    @State private var binding: HotKeyBinding?
    @State private var isRecording = false
    @State private var failed = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if failed {
                Text("快捷鍵不可用").font(.caption).foregroundStyle(.red)
            }
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "請按下組合鍵…" : (binding?.display ?? "按一下錄製"))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            if binding != nil, !isRecording {
                Button {
                    HotKeyManager.shared.setBinding(nil, for: action)
                    binding = nil
                    failed = false
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("清除快捷鍵")
            }
        }
        .onAppear { binding = HotKeyManager.shared.binding(for: action) }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        failed = false
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape, flags.isEmpty { stopRecording(); return }
        if keyCode == kVK_Delete, flags.isEmpty {
            HotKeyManager.shared.setBinding(nil, for: action)
            binding = nil
            stopRecording()
            return
        }
        // 至少要有 ⌘、⌥ 或 ⌃ 其中之一（功能鍵除外），避免攔截一般打字。
        let isFunctionKey = Self.functionKeyNames[keyCode] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return }

        var modifiers: UInt32 = 0
        var display = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); display += "⌘" }
        display += Self.keyName(for: event)

        let candidate = HotKeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers, display: display)
        if HotKeyManager.shared.setBinding(candidate, for: action) {
            binding = candidate
        } else {
            failed = true
        }
        stopRecording()
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"
    ]

    private static func keyName(for event: NSEvent) -> String {
        let keyCode = Int(event.keyCode)
        if let name = functionKeyNames[keyCode] ?? specialKeyNames[keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(keyCode)"
    }
}
