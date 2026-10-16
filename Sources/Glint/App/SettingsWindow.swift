import AppKit
import ServiceManagement
import SwiftUI

/// Preferences: toolbar tabs, 670pt wide. Only settings the app actually acts on are shown.
final class SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let panes: [(String, String, AnyView)] = [
                ("General", "gearshape", AnyView(GeneralPane())),
                ("Shortcuts", "keyboard", AnyView(ShortcutsPane())),
                ("Popup", "rectangle.stack", AnyView(QuickAccessPane())),
                ("Screenshots", "camera", AnyView(ScreenshotsPane())),
                ("Annotate", "pencil.and.outline", AnyView(AnnotatePane())),
                ("Advanced", "slider.horizontal.3", AnyView(AdvancedPane())),
                ("About", "info.circle", AnyView(AboutPane())),
            ]
            for (title, icon, view) in panes {
                let host = NSHostingController(rootView: view.frame(width: 670).fixedSize())
                host.title = title // the tab controller shows the selected pane's title in the window
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .preference
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
        window!.orderFrontRegardless()
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("afterPopup") private var afterPopup = true
    @AppStorage("afterCopy") private var afterCopy = false
    @AppStorage("afterSave") private var afterSave = false
    @AppStorage("afterAnnotate") private var afterAnnotate = false
    @AppStorage("afterPin") private var afterPin = false
    @StateObject private var m = GeneralModel() // @State is a macro the Command Line Tools can't expand

    var body: some View {
        Form {
            Section {
                LabeledContent("Export location") {
                    HStack {
                        Text((m.exportPath as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { m.chooseFolder() }
                    }
                }
            }
            Section {
                Toggle("Start at login", isOn: Binding(get: { m.startAtLogin }, set: m.setLogin))
                if let e = m.loginError { Text(e).font(.caption).foregroundStyle(.red) }
                Toggle("Play sounds", isOn: $playSounds)
            }
            Section("After capture") {
                Toggle("Show the popup", isOn: $afterPopup)
                Toggle("Copy file to clipboard", isOn: $afterCopy)
                Toggle("Save", isOn: $afterSave)
                Toggle("Open Annotate tool", isOn: $afterAnnotate)
                Toggle("Pin to the screen", isOn: $afterPin)
            }
        }
        .formStyle(.grouped)
    }
}

private final class GeneralModel: ObservableObject {
    @Published var exportPath = Settings.exportDirectory.path
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = Settings.exportDirectory
        p.prompt = "Choose"
        guard p.runModal() == .OK, let url = p.url else { return }
        Settings.exportDirectory = url
        exportPath = url.path
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) { ShortcutField(action: action) }
                }
            } footer: {
                Text("Click a shortcut and type a new one. ⌫ clears it, ⎋ cancels. Use ⌃, ⌥ or ⌘ in every shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click to record; hotkeys are paused meanwhile so the current combo doesn't fire a capture.
private struct ShortcutField: View {
    let action: HotkeyAction
    @StateObject private var m = RecorderModel()

    var body: some View {
        Button { m.recording ? m.stop() : m.start(action) } label: {
            Text(m.recording ? "Type shortcut…" : (m.current?.display ?? "Record Shortcut")).frame(width: 120)
        }
            .foregroundStyle(m.recording ? Color.accentColor : (m.current == nil ? .secondary : .primary))
            .onAppear { m.current = Settings.shortcut(action) }
            .onDisappear { m.stop() }
    }
}

private final class RecorderModel: ObservableObject {
    @Published var current: Shortcut?
    @Published var recording = false
    private var monitor: Any?

    func start(_ action: HotkeyAction) {
        recording = true
        Hotkeys.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch Int(e.keyCode) {
            case 53: self.stop()                                                    // Esc
            case 51, 117: Settings.setShortcut(nil, for: action); self.current = nil; self.stop()
            default:
                guard let s = Shortcut(event: e) else { NSSound.beep(); return nil }
                Settings.setShortcut(s, for: action); self.current = s; self.stop()
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; NotificationCenter.default.post(name: .shortcutsChanged, object: nil) }
    }
}

private struct QuickAccessPane: View {
    @AppStorage("popupOnLeft") private var onLeft = false
    @AppStorage("autoClose") private var autoClose = false
    @AppStorage("autoCloseSaves") private var autoCloseSaves = false
    @AppStorage("autoCloseSeconds") private var seconds = 30.0
    @AppStorage("closeAfterDragging") private var closeAfterDragging = true

    var body: some View {
        Form {
            Picker("Position on screen", selection: $onLeft) {
                Text("Left").tag(true)
                Text("Right").tag(false)
            }
            .pickerStyle(.segmented)
            Section("Auto-close") {
                Toggle("Enable", isOn: $autoClose)
                Picker("Action", selection: $autoCloseSaves) {
                    Text("Close").tag(false)
                    Text("Save and Close").tag(true)
                }
                .disabled(!autoClose)
                Picker("Interval", selection: $seconds) {
                    ForEach([5.0, 10, 15, 30, 60, 120], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                .disabled(!autoClose)
            }
            Section {
                Toggle("Close after dragging", isOn: $closeAfterDragging)
            } footer: {
                Text("Hold ⌥ while dragging to do the opposite.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScreenshotsPane: View {
    @AppStorage("timerSeconds") private var timer = 5
    @AppStorage("showCursor") private var showCursor = false

    var body: some View {
        Form {
            Picker("Self-timer interval", selection: $timer) {
                ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
            }
            Toggle("Show cursor on screenshots", isOn: $showCursor)
        }
        .formStyle(.grouped)
    }
}

private struct AnnotatePane: View {
    @AppStorage("smoothDrawing") private var smooth = true
    @AppStorage("drawShadow") private var shadow = true

    var body: some View {
        Form {
            Toggle("Smooth drawing", isOn: $smooth)
            Toggle("Draw shadow on objects", isOn: $shadow)
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedPane: View {
    @AppStorage("pinRounded") private var rounded = true
    @AppStorage("pinShadow") private var shadow = true
    @AppStorage("pinBorder") private var border = true
    @AppStorage("ocrLineBreaks") private var lineBreaks = true
    @AppStorage("keepHistoryDays") private var keepDays = 30

    var body: some View {
        Form {
            Section("Pinned screenshots") {
                Toggle("Rounded corners", isOn: $rounded)
                Toggle("Shadow", isOn: $shadow)
                Toggle("Border", isOn: $border)
            }
            .onChange(of: rounded) { PinWindow.all.forEach { $0.pinView.applyStyle() } }
            .onChange(of: shadow) { PinWindow.all.forEach { $0.pinView.applyStyle() } }
            .onChange(of: border) { PinWindow.all.forEach { $0.pinView.applyStyle() } }
            Section("Text recognition") {
                Toggle("Keep line breaks", isOn: $lineBreaks)
            }
            Section("Capture history") {
                Picker("Keep history", selection: $keepDays) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("1 week").tag(7); Text("1 month").tag(30); Text("Forever").tag(0)
                }
                .onChange(of: keepDays) { History.prune() }
                Button("Show History Folder") { NSWorkspace.shared.open(History.dir) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: { let i = Icon.image("menubar", size: 48, color: .black)!; i.isTemplate = true; return i }())
                .foregroundStyle(.primary)
            Text("Glint").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Fast, local-only screenshots for macOS.").font(.callout).foregroundStyle(.secondary)
            Text("© 2026 Heet Patel · GNU GPL v3").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}
