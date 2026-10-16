import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var busy = false
    private var actionItems: [HotkeyAction: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Icon.image("menubar", size: 18, color: .black)
        icon?.isTemplate = true // macOS tints it to match the menu bar, like every other status item
        icon?.accessibilityDescription = "Glint"
        statusItem.button?.image = icon

        let menu = NSMenu()
        for action in [HotkeyAction.captureBar, .area, .previousArea, .fullscreen, .window, .scrolling, .selfTimer, .captureText] {
            let item = ActionItem(action.title, mods: []) { [weak self] in self?.perform(action) }
            actionItems[action] = item
            menu.addItem(item)
            if action == .selfTimer { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let restore = ActionItem(HotkeyAction.restoreLast.title, mods: []) { [weak self] in self?.perform(.restoreLast) }
        actionItems[.restoreLast] = restore
        menu.addItem(restore)
        let history = ActionItem("Capture History…", mods: []) { [weak self] in self?.perform(.history) }
        actionItems[.history] = history
        menu.addItem(history)
        menu.addItem(ActionItem("Close All Overlays", mods: []) { PopupManager.shared.closeAll() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…", key: ",") { SettingsWindow.show() })
        menu.addItem(NSMenuItem(title: "Quit Glint", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        registerHotkeys()
        NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotkeys()
        }
        History.prune()
        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Demo.run(editor: CommandLine.arguments.contains("--demo-editor")) }
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    /// (Re)registers every global shortcut from Settings and mirrors them in the menu.
    private func registerHotkeys() {
        Hotkeys.shared.unregisterAll()
        for action in HotkeyAction.allCases {
            let s = Settings.shortcut(action)
            if let s { Hotkeys.shared.register(keyCode: s.keyCode, modifiers: s.carbonMods) { [weak self] in self?.perform(action) } }
            actionItems[action]?.keyEquivalent = s?.keyString.lowercased() ?? ""
            actionItems[action]?.keyEquivalentModifierMask = s?.modifierFlags ?? []
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .area: interactive(.area)
        case .window: interactive(.window)
        case .selfTimer: interactive(.selfTimer)
        case .fullscreen: run("fullscreen") { try await Capturer.captureDisplayUnderCursor() }
        case .previousArea:
            guard let rect = Settings.lastArea else { return interactive(.area) } // nothing remembered yet
            run("previous area") { try await Capturer.capture(globalRect: rect) }
        case .captureText: captureText()
        case .restoreLast: PopupManager.shared.restoreLast()
        case .history: HistoryPanel.toggle()
        case .captureBar: CaptureBar.show { [weak self] in self?.handleCaptureBar($0) }
        case .scrolling: CaptureBar.show(scrolling: true) { [weak self] in self?.handleCaptureBar($0) }
        }
    }

    private func handleCaptureBar(_ choice: CaptureBar.Choice) {
        switch choice {
        case .area(let r): run("capture bar area") { try await Capturer.capture(globalRect: r) }
        case .fullscreen(let r): run("capture bar fullscreen") { try await Capturer.capture(globalRect: r) }
        case .window: interactive(.window)
        case .scrolling(let r):
            guard !busy else { return }
            busy = true
            ScrollingSession.start(r) { [weak self] image in self?.busy = false; self?.finish(image, label: "scrolling") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watchScrolling() }
        case .timer(let r):
            let n = Settings.timerSeconds
            Toast.show("Capturing in \(n) seconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(n)) { [weak self] in
                self?.run("capture bar timer") { try await Capturer.capture(globalRect: r) }
            }
        case .text(let r):
            Task { @MainActor in
                do { OCR.copyText(from: try await Capturer.capture(globalRect: r)) } catch { log("capture bar text failed: \(error)") }
            }
        }
    }

    private func interactive(_ mode: Capturer.Mode) {
        run("\(mode)") {
            guard let result = await Capturer.interactive(mode) else { return nil }
            if mode == .area, let rect = result.rect { Settings.lastArea = rect }
            return result.image
        }
    }

    /// OCR: Apple's selector, then Vision; only the text is kept (no popup, no history file).
    private func captureText() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard let result = await Capturer.interactive(.area) else { return log("capture text cancelled") }
            OCR.copyText(from: result.image)
        }
    }

    /// Releases the capture lock if a scrolling session ends without an image (cancelled).
    private func watchScrolling() {
        if ScrollingSession.isRunning { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watchScrolling() } }
        else { busy = false }
    }

    /// One capture at a time; nil from `capture` means the user cancelled.
    private func run(_ label: String, _ capture: @escaping () async throws -> CGImage?) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let image = try await capture() else { return log("\(label) cancelled") }
                finish(image, label: label)
            } catch {
                log("\(label) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    /// After-capture actions (General → After capture). Every capture is also kept in History.
    private func finish(_ image: CGImage, label: String) {
        if Settings.playSounds { Output.playShutter() }
        let file: URL
        do { file = try History.save(image) } catch { return log("history save failed: \(error)") }
        let card = Settings.afterPopup ? PopupManager.shared.show(image, url: file) : nil
        if Settings.afterCopy { Output.copy(image, file: file) }
        if Settings.afterPin { PinWindow.open(image, url: file, from: nil) }
        if Settings.afterSave {
            do { log("saved \(try Output.save(image).path)") } catch { log("save failed: \(error)") }
        }
        if Settings.afterAnnotate { Editor.open(image: image, url: file, card: card) }
        log("captured \(label) \(image.width)x\(image.height) popup=\(Settings.afterPopup) copy=\(Settings.afterCopy) save=\(Settings.afterSave)")
    }
}
