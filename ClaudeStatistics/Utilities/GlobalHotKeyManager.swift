import AppKit
import Carbon
import Foundation

enum GlobalHotKeyAction: Int, CaseIterable, Identifiable {
    case panel = 1
    case island = 2

    var id: Int { rawValue }

    var enabledKey: String {
        switch self {
        case .panel: return "globalHotKeyEnabled"
        case .island: return "globalHotKeyIslandEnabled"
        }
    }

    var keyCodeKey: String {
        switch self {
        case .panel: return "globalHotKeyKeyCode"
        case .island: return "globalHotKeyIslandKeyCode"
        }
    }

    var modifiersKey: String {
        switch self {
        case .panel: return "globalHotKeyModifiers"
        case .island: return "globalHotKeyIslandModifiers"
        }
    }

    var defaultKeyCode: Int {
        switch self {
        case .panel: return Int(kVK_ANSI_S)
        case .island: return Int(kVK_ANSI_I)
        }
    }

    var defaultModifiers: Int {
        Int(controlKey | cmdKey)
    }

    var titleKey: String {
        switch self {
        case .panel: return "settings.shortcut.menuBarPanel"
        case .island: return "settings.shortcut.island"
        }
    }

    var iconName: String {
        switch self {
        case .panel: return "menubar.rectangle"
        case .island: return "capsule.tophalf.filled"
        }
    }
}

struct GlobalHotKeyShortcut: Equatable {
    static let enabledKey = "globalHotKeyEnabled"
    static let keyCodeKey = "globalHotKeyKeyCode"
    static let modifiersKey = "globalHotKeyModifiers"
    static let islandEnabledKey = GlobalHotKeyAction.island.enabledKey
    static let islandKeyCodeKey = GlobalHotKeyAction.island.keyCodeKey
    static let islandModifiersKey = GlobalHotKeyAction.island.modifiersKey

    static let defaultKeyCode = Int(kVK_ANSI_S)
    static let defaultModifiers = Int(controlKey | cmdKey)
    static let defaultIslandKeyCode = Int(kVK_ANSI_I)

    let keyCode: Int
    let modifiers: Int

    static var current: GlobalHotKeyShortcut? {
        current(for: .panel)
    }

    static func current(for action: GlobalHotKeyAction) -> GlobalHotKeyShortcut? {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: action.enabledKey) == nil {
            defaults.set(true, forKey: action.enabledKey)
        }
        guard defaults.bool(forKey: action.enabledKey) else { return nil }

        let storedKeyCode = defaults.object(forKey: action.keyCodeKey) as? Int
        let storedModifiers = defaults.object(forKey: action.modifiersKey) as? Int
        return GlobalHotKeyShortcut(
            keyCode: storedKeyCode ?? action.defaultKeyCode,
            modifiers: storedModifiers ?? action.defaultModifiers
        )
    }

    var displayText: String {
        Self.displayText(keyCode: keyCode, modifiers: modifiers)
    }

    static func displayText(keyCode: Int, modifiers: Int) -> String {
        var parts: [String] = []
        if modifiers & Int(controlKey) != 0 { parts.append("⌃") }
        if modifiers & Int(optionKey) != 0 { parts.append("⌥") }
        if modifiers & Int(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & Int(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= Int(controlKey) }
        if flags.contains(.option) { modifiers |= Int(optionKey) }
        if flags.contains(.shift) { modifiers |= Int(shiftKey) }
        if flags.contains(.command) { modifiers |= Int(cmdKey) }
        return modifiers
    }

    private static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return "#\(keyCode)"
        }
    }
}

final class GlobalHotKeyManager {
    private var hotKeyRefs: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private let actions: [GlobalHotKeyAction: @MainActor () -> Void]
    private let signature = OSType(UInt32(ascii: "CSHK"))

    init(actions: [GlobalHotKeyAction: @MainActor () -> Void]) {
        self.actions = actions
        installEventHandler()
        registerCurrentShortcut()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerCurrentShortcut()
        }
    }

    deinit {
        unregisterHotKeys()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func registerCurrentShortcut() {
        unregisterHotKeys()

        for action in GlobalHotKeyAction.allCases {
            guard actions[action] != nil,
                  let shortcut = GlobalHotKeyShortcut.current(for: action) else { continue }

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(action.rawValue))
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                UInt32(shortcut.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr {
                hotKeyRefs[action] = ref
            } else {
                DiagnosticLogger.shared.warning(
                    "Global hotkey registration failed for \(shortcut.displayText) action=\(action) (status=\(status))"
                )
            }
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            GlobalHotKeyManager.handleHotKeyEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            DiagnosticLogger.shared.warning("Global hotkey event handler install failed (status=\(status))")
        }
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard let action = GlobalHotKeyAction(rawValue: Int(hotKeyID.id)) else {
            return noErr
        }
        Task { @MainActor in
            manager.actions[action]?()
        }
        return noErr
    }
}

private extension UInt32 {
    init(ascii text: String) {
        self = text.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}
