import AppKit
import Carbon.HIToolbox

/// UserDefaults-backed prefs. The Settings window binds the same keys with @AppStorage, so defaults live in both
/// places: keep `Settings.defaults` and the SettingsView initial values in step.
enum Settings {
    private static let d = UserDefaults.standard
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    // After-capture actions (default: popup on, everything else off).
    static var afterPopup: Bool { get { bool("afterPopup", true) } set { d.set(newValue, forKey: "afterPopup") } }
    static var afterCopy: Bool { get { bool("afterCopy", false) } set { d.set(newValue, forKey: "afterCopy") } }
    static var afterSave: Bool { get { bool("afterSave", false) } set { d.set(newValue, forKey: "afterSave") } }
    static var afterPin: Bool { get { bool("afterPin", false) } set { d.set(newValue, forKey: "afterPin") } }
    static var afterAnnotate: Bool { get { bool("afterAnnotate", false) } set { d.set(newValue, forKey: "afterAnnotate") } }

    // General
    static var playSounds: Bool { bool("playSounds", true) }

    // Pinned screenshot style (all on by default).
    static var pinShadow: Bool { get { bool("pinShadow", true) } set { d.set(newValue, forKey: "pinShadow") } }
    static var pinRounded: Bool { get { bool("pinRounded", true) } set { d.set(newValue, forKey: "pinRounded") } }
    static var pinBorder: Bool { get { bool("pinBorder", true) } set { d.set(newValue, forKey: "pinBorder") } }

    // Popup.
    static var popupOnLeft: Bool { bool("popupOnLeft", false) }
    static var closeAfterDragging: Bool { bool("closeAfterDragging", true) }
    static var autoClose: Bool { bool("autoClose", false) }
    static var autoCloseSeconds: Double { d.object(forKey: "autoCloseSeconds") as? Double ?? 30 }
    static var autoCloseSaves: Bool { bool("autoCloseSaves", false) }

    // Screenshots
    static var timerSeconds: Int { d.object(forKey: "timerSeconds") as? Int ?? 5 }
    static var showCursor: Bool { bool("showCursor", false) }

    // Annotate
    static var drawShadow: Bool { bool("drawShadow", true) }
    static var smoothDrawing: Bool { bool("smoothDrawing", true) }

    // Advanced
    static var ocrLineBreaks: Bool { bool("ocrLineBreaks", true) }
    /// Days of capture history to keep; 0 = forever.
    static var keepHistoryDays: Int { d.object(forKey: "keepHistoryDays") as? Int ?? 30 }

    static var exportDirectory: URL {
        get {
            if let path = d.string(forKey: "exportDirectory"), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { d.set(newValue.path, forKey: "exportDirectory") }
    }

    /// Last area selection, global top-left points.
    static var lastArea: CGRect? {
        get { d.string(forKey: "lastArea").map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { d.set(newValue.map { NSStringFromRect($0) }, forKey: "lastArea") }
    }

    static func shortcut(_ action: HotkeyAction) -> Shortcut? {
        guard let s = d.string(forKey: "shortcut." + action.rawValue) else { return action.defaultShortcut }
        return Shortcut(string: s) // "" = cleared
    }

    static func setShortcut(_ s: Shortcut?, for action: HotkeyAction) {
        d.set(s?.string ?? "", forKey: "shortcut." + action.rawValue)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}

extension Notification.Name { static let shortcutsChanged = Notification.Name("CSXShortcutsChanged") }

/// Every global shortcut. Defaults use ⌃⇧ so they don't collide with macOS's own ⇧⌘ screenshot keys.
enum HotkeyAction: String, CaseIterable {
    case captureBar = "allInOne", area, previousArea, fullscreen, window, scrolling, selfTimer, captureText, restoreLast, history

    var title: String {
        switch self {
        case .captureBar: "Capture Bar"
        case .history: "Capture History"
        case .scrolling: "Scrolling Capture"
        case .area: "Capture Area"
        case .previousArea: "Capture Previous Area"
        case .fullscreen: "Capture Fullscreen"
        case .window: "Capture Window"
        case .selfTimer: "Self-Timer"
        case .captureText: "Capture Text (OCR)"
        case .restoreLast: "Restore Last Capture"
        }
    }

    var defaultShortcut: Shortcut? {
        let cs = UInt32(controlKey | shiftKey)
        switch self {
        case .captureBar: return Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonMods: cs)
        case .history, .scrolling: return nil
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_4), carbonMods: cs)
        case .previousArea: return Shortcut(keyCode: UInt32(kVK_ANSI_6), carbonMods: cs)
        case .fullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), carbonMods: cs)
        case .window: return Shortcut(keyCode: UInt32(kVK_ANSI_5), carbonMods: cs)
        case .selfTimer: return Shortcut(keyCode: UInt32(kVK_ANSI_7), carbonMods: cs)
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_1), carbonMods: cs)
        case .restoreLast: return nil
        }
    }
}

/// A key + Carbon modifier mask, stored as "keyCode:mods".
struct Shortcut: Equatable {
    var keyCode: UInt32
    var carbonMods: UInt32

    init(keyCode: UInt32, carbonMods: UInt32) { self.keyCode = keyCode; self.carbonMods = carbonMods }

    init?(string: String) {
        let parts = string.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], carbonMods: parts[1])
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil } // a global shortcut needs ⌃, ⌥ or ⌘
        self.init(keyCode: UInt32(event.keyCode), carbonMods: m)
    }

    var string: String { "\(keyCode):\(carbonMods)" }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonMods & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonMods & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonMods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonMods & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// The key as typed on this keyboard layout (for menus and the Settings field).
    var keyString: String {
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let n = named[Int(keyCode)] { return n }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(keyCode)"
    }

    /// "⌃⇧4" in Apple's modifier order.
    var display: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonMods & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonMods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyString
    }
}

/// Every capture is kept here so popups can be dragged as files, revealed, and restored after closing.
enum History {
    static let dir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let app = support.appendingPathComponent("Glint", isDirectory: true)
        let url = app.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func save(_ image: CGImage) throws -> URL {
        let url = try Output.save(image, to: dir)
        prune()
        return url
    }

    /// "Keep history": drop captures older than the setting (never the newest 10, which Restore and popups may use).
    static func prune(now: Date = Date()) {
        let days = Settings.keepHistoryDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for old in all().dropFirst(10) where date(old) < cutoff { try? FileManager.default.removeItem(at: old) }
    }

    private static func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }

    /// Newest first.
    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "png" }.sorted { date($0) > date($1) }
    }
}
