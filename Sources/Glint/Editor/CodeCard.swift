import AppKit

// Code Cards: paste code, get a syntax-coloured window image, edit it like any capture (frames, cards, annotations).

enum CodeLanguage: Int, CaseIterable {
    case auto, swift, javascript, python, go, rust, json, shell, html, sql, plain

    var title: String {
        ["Auto", "Swift", "JavaScript / TypeScript", "Python", "Go", "Rust", "JSON", "Shell", "HTML / CSS", "SQL", "Plain text"][rawValue]
    }

    var lineComment: String? {
        switch self {
        case .swift, .javascript, .go, .rust: "//"
        case .python, .shell: "#"
        case .sql: "--"
        default: nil
        }
    }

    var blockComment: (String, String)? {
        switch self {
        case .swift, .javascript, .go, .rust: ("/*", "*/")
        case .html: ("<!--", "-->")
        default: nil
        }
    }

    /// Capitalised words are types (classes, structs) in these languages.
    var capitalisedTypes: Bool { [.swift, .javascript, .python, .go, .rust].contains(self) }

    var keywords: Set<String> {
        switch self {
        case .swift: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "struct", "class",
                      "enum", "protocol", "extension", "import", "init", "self", "Self", "true", "false", "nil", "private", "public", "static",
                      "final", "throws", "try", "await", "async", "some", "any", "where", "break", "continue", "defer", "do", "catch", "override"]
        case .javascript: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "of", "in", "new", "class", "extends",
                           "import", "export", "from", "default", "async", "await", "try", "catch", "throw", "true", "false", "null",
                           "undefined", "this", "typeof", "interface", "type", "switch", "case", "break", "continue"]
        case .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "with", "try", "except",
                       "finally", "raise", "lambda", "yield", "async", "await", "pass", "break", "continue", "and", "or", "not", "is",
                       "None", "True", "False", "self"]
        case .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if",
                   "else", "for", "range", "switch", "case", "default", "break", "continue", "nil", "true", "false", "select"]
        case .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "match", "if", "else", "for", "in", "while",
                     "loop", "return", "self", "Self", "true", "false", "as", "ref", "move", "async", "await", "where", "const", "static"]
        case .json: ["true", "false", "null"]
        case .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export",
                      "local", "echo", "cd", "sudo", "git", "brew", "npm", "set"]
        case .sql: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter",
                    "join", "left", "right", "inner", "outer", "on", "and", "or", "not", "null", "as", "order", "by", "group", "having",
                    "limit", "primary", "key", "references", "index", "distinct", "count", "integer", "text", "real"]
        case .html: []
        case .auto, .plain: []
        }
    }

    /// Guesses the language from telltale tokens; `.plain` when nothing stands out.
    static func detect(_ code: String) -> CodeLanguage {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines), lower = t.lowercased()
        func has(_ s: String) -> Bool { t.contains(s) }
        if (t.hasPrefix("{") || t.hasPrefix("[")) && has("\":") { return .json }
        if t.hasPrefix("#!") && (has("bash") || has("/sh") || has("zsh")) { return .shell }
        if t.hasPrefix("<") && has("</") { return .html }
        var score: [CodeLanguage: Int] = [:]
        func add(_ l: CodeLanguage, _ ok: Bool, _ w: Int = 1) { if ok { score[l, default: 0] += w } }
        add(.swift, has("func ") && (has("let ") || has("var "))); add(.swift, has("guard ") || has("import SwiftUI") || has("import Foundation"), 2)
        add(.python, has("def ") && has(":")); add(.python, has("elif ") || has("self.") || has("import numpy"), 2)
        add(.go, has("package "), 2); add(.go, has(":=")); add(.go, has("func ("), 2)
        add(.rust, has("fn ") && has("->")); add(.rust, has("let mut ") || has("impl ") || has("println!"), 2)
        add(.javascript, has("const ") || has("=>")); add(.javascript, has("console.") || has("function ") || has("export "), 2)
        add(.sql, ["select ", "insert into", "create table", "update "].contains { lower.hasPrefix($0) }, 3)
        add(.shell, t.split(separator: "\n").contains { $0.hasPrefix("$ ") || $0.hasPrefix("sudo ") || $0.hasPrefix("brew ") || $0.hasPrefix("git ") }, 2)
        return score.max { $0.value < $1.value }?.key ?? .plain
    }
}

enum TokenKind { case plain, comment, string, number, keyword, type, function }

enum CodeHighlighter {
    /// Splits code into coloured runs. One pass, no regexes: comments, strings (escapes, Python triple quotes,
    /// JS template literals with nested `${…}`), numbers, then words.
    static func tokens(_ code: String, _ language: CodeLanguage) -> [(text: String, kind: TokenKind)] {
        let lang = language == .auto ? CodeLanguage.detect(code) : language
        let c = Array(code), n = c.count
        var out: [(String, TokenKind)] = [], i = 0, plainStart = 0
        func flushPlain(_ upTo: Int) { if upTo > plainStart { out.append((String(c[plainStart..<upTo]), .plain)) } }
        func emit(_ s: Int, _ e: Int, _ k: TokenKind) { flushPlain(s); out.append((String(c[s..<e]), k)); i = e; plainStart = e }
        func starts(_ s: String, _ at: Int) -> Bool {
            let p = Array(s)
            return at + p.count <= n && Array(c[at..<at + p.count]) == p
        }
        func find(_ s: String, from: Int) -> Int? { var j = from; while j < n { if starts(s, j) { return j }; j += 1 }; return nil }
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }

        func scanString(_ s: Int, _ q: Character) -> Int {
            var j = s + 1
            while j < n {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == q { return j + 1 }
                if c[j] == "\n" { return j } // unterminated: stop at the line end
                j += 1
            }
            return n
        }
        func scanTemplate(_ s: Int) -> Int {
            var j = s + 1
            while j < n {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == "`" { return j + 1 }
                if starts("${", j) {
                    var depth = 1; j += 2
                    while j < n && depth > 0 {
                        if c[j] == "`" { j = scanTemplate(j); continue }
                        if c[j] == "{" { depth += 1 } else if c[j] == "}" { depth -= 1 }
                        j += 1
                    }
                    continue
                }
                j += 1
            }
            return n
        }

        while i < n {
            let ch = c[i]
            if let (open, close) = lang.blockComment, starts(open, i) {
                let end = find(close, from: i + open.count).map { $0 + close.count } ?? n
                emit(i, end, .comment)
            } else if let lc = lang.lineComment, starts(lc, i), !(lc == "#" && lang == .shell && i > 0 && c[i - 1] == "$") {
                emit(i, find("\n", from: i) ?? n, .comment)
            } else if lang == .python, starts("\"\"\"", i) || starts("'''", i) {
                let q = String(c[i..<i + 3])
                emit(i, find(q, from: i + 3).map { $0 + 3 } ?? n, .string)
            } else if ch == "\"" || (ch == "'" && lang != .rust && lang != .html) || (ch == "'" && lang == .rust && (i + 2 < n && (c[i + 2] == "'" || c[i + 1] == "\\"))) {
                let end = scanString(i, ch)
                var j = end; while j < n, c[j] == " " { j += 1 }
                emit(i, end, lang == .json && j < n && c[j] == ":" ? .type : .string) // JSON keys read as names
            } else if ch == "`", lang == .javascript || lang == .go || lang == .shell {
                emit(i, lang == .javascript ? scanTemplate(i) : scanString(i, "`"), .string)
            } else if ch.isNumber, i == 0 || !isWord(c[i - 1]) {
                var j = i + 1; while j < n, isWord(c[j]) || c[j] == "." { j += 1 }
                emit(i, j, .number)
            } else if ch.isLetter || ch == "_" || (ch == "$" && (lang == .shell || lang == .javascript)) {
                var j = i + 1; while j < n, isWord(c[j]) { j += 1 }
                let word = String(c[i..<j])
                var k = j; while k < n, c[k] == " " { k += 1 }
                let kind: TokenKind
                if lang.keywords.contains(lang == .sql ? word.lowercased() : word) { kind = .keyword }
                else if ch == "$" { kind = .type }
                else if lang == .html, i > 0, c[i - 1] == "<" || (c[i - 1] == "/" && i > 1 && c[i - 2] == "<") { kind = .keyword }
                else if lang == .html, k < n, c[k] == "=" { kind = .type }
                else if lang.capitalisedTypes, ch.isUppercase { kind = .type }
                else if k < n, c[k] == "(", lang != .plain { kind = .function }
                else { kind = .plain }
                if kind == .plain { i = j } else { emit(i, j, kind) }
            } else {
                i += 1
            }
        }
        flushPlain(n)
        // Merge neighbouring plain runs.
        var merged: [(text: String, kind: TokenKind)] = []
        for t in out { if let last = merged.last, last.kind == .plain, t.1 == .plain { merged[merged.count - 1].text += t.0 } else { merged.append((t.0, t.1)) } }
        return merged
    }
}

struct CodeTheme {
    var name: String
    var bg, fg, comment, string, number, keyword, type, function, gutter, chrome: Int

    func color(_ k: TokenKind) -> NSColor {
        Palette.hex([.plain: fg, .comment: comment, .string: string, .number: number, .keyword: keyword, .type: type, .function: function][k]!)
    }

    static let all: [CodeTheme] = [
        CodeTheme(name: "Glint Dark", bg: 0x1B1D2A, fg: 0xE4E6F1, comment: 0x6B7089, string: 0xA6E3A1, number: 0xFAB387, keyword: 0xC792EA,
                  type: 0x89DDFF, function: 0x82AAFF, gutter: 0x4A4E66, chrome: 0x252839),
        CodeTheme(name: "Glint Light", bg: 0xFBFBFD, fg: 0x24292F, comment: 0x8B949E, string: 0x0A7F3F, number: 0xB35900, keyword: 0xA626A4,
                  type: 0x0B6BCB, function: 0x6F42C1, gutter: 0xB8BCC4, chrome: 0xEDEEF2),
        CodeTheme(name: "Solarized", bg: 0x002B36, fg: 0x93A1A1, comment: 0x586E75, string: 0x2AA198, number: 0xD33682, keyword: 0x859900,
                  type: 0xB58900, function: 0x268BD2, gutter: 0x2F5560, chrome: 0x073642),
        CodeTheme(name: "Dracula", bg: 0x282A36, fg: 0xF8F8F2, comment: 0x6272A4, string: 0xF1FA8C, number: 0xBD93F9, keyword: 0xFF79C6,
                  type: 0x8BE9FD, function: 0x50FA7B, gutter: 0x5A5E77, chrome: 0x21222C),
    ]
}

struct CodeCardOptions: Equatable {
    var language = CodeLanguage.auto
    var theme = 0
    var lineNumbers = true
    var wrap = 80          // columns
    var chrome = true      // traffic lights + title bar
    var title = ""
}

enum CodeRenderer {
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)

    /// The code as a rounded window image at `scale` (transparent outside the corners).
    static func render(_ code: String, _ o: CodeCardOptions, scale: CGFloat = 2) -> CGImage? {
        let theme = CodeTheme.all[o.theme % CodeTheme.all.count]
        let src = code.replacingOccurrences(of: "\t", with: "    ").trimmingCharacters(in: .newlines)
        let tokens = CodeHighlighter.tokens(src, o.language)

        // Split runs into source lines, then wrap each line into rows of at most `wrap` columns.
        var lines: [[(String, TokenKind)]] = [[]]
        for (text, kind) in tokens {
            for (n, part) in text.components(separatedBy: "\n").enumerated() {
                if n > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append((part, kind)) }
            }
        }
        var rows: [(line: Int?, runs: [(String, TokenKind)])] = []
        for (ln, runs) in lines.prefix(500).enumerated() {
            var row: [(String, TokenKind)] = [], cols = 0, first = true
            for (text, kind) in runs {
                var rest = Substring(text)
                while !rest.isEmpty {
                    let take = min(rest.count, o.wrap - cols)
                    row.append((String(rest.prefix(take)), kind)); cols += take; rest = rest.dropFirst(take)
                    if cols >= o.wrap && !rest.isEmpty { rows.append((first ? ln + 1 : nil, row)); row = []; cols = 0; first = false }
                }
            }
            rows.append((first ? ln + 1 : nil, row))
        }

        let charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let lineH = ceil((font.ascender - font.descender + font.leading) * 1.55)
        let maxCols = rows.map { $0.runs.reduce(0) { $0 + $1.0.count } }.max() ?? 0
        let gutter = o.lineNumbers ? CGFloat(String(lines.count).count + 2) * charW : 0
        let pad: CGFloat = 24, bar: CGFloat = o.chrome ? 40 : 0
        let w = max(320, ceil(pad * 2 + gutter + CGFloat(maxCols) * charW))
        let h = ceil(bar + pad * 2 - 6 + CGFloat(rows.count) * lineH)

        guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: h * scale)
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let window = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(window); ctx.clip()
        ctx.setFillColor(Palette.hex(theme.bg).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if o.chrome {
            ctx.setFillColor(Palette.hex(theme.chrome).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: bar))
            for (n, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                ctx.setFillColor(Palette.hex(col).cgColor)
                ctx.fillEllipse(in: CGRect(x: 16 + CGFloat(n) * 20, y: bar / 2 - 6, width: 12, height: 12))
            }
            if !o.title.isEmpty {
                let t = NSAttributedString(string: o.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                         .foregroundColor: Palette.hex(theme.fg).withAlphaComponent(0.6)])
                let s = t.size()
                t.draw(at: CGPoint(x: (w - s.width) / 2, y: (bar - s.height) / 2))
            }
        }
        for (r, row) in rows.enumerated() {
            let y = bar + pad - 3 + CGFloat(r) * lineH + (lineH - (font.ascender - font.descender)) / 2
            if let ln = row.line, o.lineNumbers {
                let num = NSAttributedString(string: String(ln), attributes: [.font: font, .foregroundColor: Palette.hex(theme.gutter)])
                num.draw(at: CGPoint(x: pad + gutter - charW * 2 - num.size().width + charW, y: y))
            }
            let line = NSMutableAttributedString()
            for (text, kind) in row.runs {
                line.append(NSAttributedString(string: text, attributes: [.font: kind == .keyword ? bold : font, .foregroundColor: theme.color(kind)]))
            }
            line.draw(at: CGPoint(x: pad + gutter, y: y))
        }
        return ctx.makeImage()
    }
}

/// Menu bar → New Code Card…: paste code on the left, see the card on the right, ⌘↩ to open it in the editor.
final class CodeCardWindow: NSObject, NSTextViewDelegate {
    static let shared = CodeCardWindow()

    private var window: CodeWindow?
    private var text: NSTextView!
    private let preview = NSImageView()
    private let language = NSPopUpButton(), theme = NSPopUpButton(), wrap = NSPopUpButton()
    private let lineNumbers = NSButton(checkboxWithTitle: "Line numbers", target: nil, action: nil)
    private let chrome = NSButton(checkboxWithTitle: "Window bar", target: nil, action: nil)
    private let titleField = NSTextField()
    private var options = CodeCardOptions()

    func show() {
        if window == nil { build() }
        // An empty box picks up code that's already on the clipboard.
        if text.string.isEmpty, let s = NSPasteboard.general.string(forType: .string), s.contains("\n") || s.contains("{") || s.contains(";") {
            text.string = s
        }
        update()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(text)
    }

    private func build() {
        let w = CodeWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        w.title = "New Code Card"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 420)
        let scroll = NSTextView.scrollableTextView()
        text = (scroll.documentView as! NSTextView)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.textContainerInset = NSSize(width: 8, height: 10)
        text.allowsUndo = true
        text.delegate = self

        language.addItems(withTitles: CodeLanguage.allCases.map(\.title))
        theme.addItems(withTitles: CodeTheme.all.map(\.name))
        wrap.addItems(withTitles: ["Wrap at 60", "Wrap at 80", "Wrap at 100"])
        wrap.selectItem(at: 1)
        lineNumbers.state = .on
        chrome.state = .on
        titleField.placeholderString = "Title (e.g. main.swift)"
        for c in [language, theme, wrap, lineNumbers, chrome] as [NSControl] { c.target = self; c.action = #selector(optionsChanged) }
        titleField.target = self
        titleField.action = #selector(optionsChanged)
        (titleField as NSTextField).delegate = self

        let create = NSButton(title: "Create  ⌘↩", target: self, action: #selector(create))
        create.bezelStyle = .push
        create.keyEquivalent = "\r"
        create.keyEquivalentModifierMask = .command
        let controls = NSStackView(views: [language, theme, wrap, lineNumbers, chrome, titleField, create])
        controls.orientation = .horizontal
        controls.spacing = 8
        titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true

        preview.imageScaling = .scaleProportionallyDown
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] { // the card's size must never resize the window
            preview.setContentCompressionResistancePriority(.init(1), for: o)
            preview.setContentHuggingPriority(.init(1), for: o)
        }
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
        preview.layer?.cornerRadius = 10

        let root = NSView()
        for v in [scroll, preview, controls] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.42),
            preview.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        w.contentView = root
        w.center()
        window = w
    }

    /// The composer window drawn offscreen with `code` in it (for `--render-samples`).
    func snapshot(code: String) -> NSBitmapImageRep? {
        if window == nil { build() }
        text.string = code
        update()
        guard let view = window?.contentView else { return nil }
        window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @objc private func optionsChanged() {
        options.language = CodeLanguage(rawValue: language.indexOfSelectedItem) ?? .auto
        options.theme = theme.indexOfSelectedItem
        options.wrap = [60, 80, 100][wrap.indexOfSelectedItem]
        options.lineNumbers = lineNumbers.state == .on
        options.chrome = chrome.state == .on
        options.title = titleField.stringValue
        update()
    }

    func textDidChange(_ notification: Notification) { update() }

    /// ⌘↩ creates (the text view would otherwise take it as a newline).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true, NSApp.currentEvent?.keyCode == 36 else { return false }
        create()
        return true
    }

    private func update() {
        let code = text.string
        preview.image = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : CodeRenderer.render(code, options).map { NSImage(cgImage: $0, size: .zero) }
        if options.language == .auto {
            let guess = CodeLanguage.detect(code)
            language.item(at: 0)?.title = guess == .plain ? "Auto" : "Auto (\(guess.title))"
        }
    }

    @objc private func create() {
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let image = CodeRenderer.render(text.string, options) else { return NSSound.beep() }
        guard let url = try? History.save(image) else { return log("code card: history save failed") }
        window?.close()
        let card = PopupManager.shared.show(image, url: url)
        Editor.open(image: image, url: url, card: card)
    }
}

extension CodeCardWindow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { optionsChanged() }
}

/// Glint has no Edit menu (it never owns the menu bar), so this window maps the editing shortcuts itself.
final class CodeWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if mods == .command || mods == [.command, .shift] {
            let shift = mods.contains(.shift)
            let action: String? = switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where !shift: "copy:"
            case "v" where !shift: "paste:"
            case "x" where !shift: "cut:"
            case "a" where !shift: "selectAll:"
            case "z": shift ? "redo:" : "undo:"
            case "w" where !shift: "performClose:"
            default: nil
            }
            if let action, NSApp.sendAction(Selector(action), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
