import AppKit
import QuartzCore

/// The popup stack: 40pt from the screen edge, first card 100pt up,
/// newer cards stack upward with a 10pt gap; appear = slide 28pt in + fade with ~6pt overshoot (~240ms);
/// when a card closes the ones above spring down (~380ms).
final class PopupManager {
    static let shared = PopupManager()

    private(set) var cards: [PopupCard] = [] // bottom → top; tucked cards stay in the array but leave the stack
    private var closedURLs: [URL] = []
    private var screen: NSScreen?
    weak var hovered: PopupCard?

    private static let edge: CGFloat = 40, bottom: CGFloat = 100, gap: CGFloat = 10, slideIn: CGFloat = 28

    // MARK: show / layout

    @discardableResult
    func show(_ image: CGImage, url: URL) -> PopupCard {
        // ponytail: the stack follows the cursor's screen only when a card is added; poll on a timer if that feels stale.
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let card = PopupCard(image: image, url: url)
        cards.append(card)
        layout(except: card)

        let target = PopupCard.windowFrame(forCard: slot(stacked.count - 1))
        card.setFrame(target.offsetBy(dx: Settings.popupOnLeft ? -Self.slideIn : Self.slideIn, dy: 0), display: false)
        card.alphaValue = 0
        card.orderFrontRegardless()
        Tween.run(card, to: target, alpha: 1, duration: 0.36, curve: Tween.backOut(2.2), alphaCurve: { min(1, $0 * 1.4) })
        card.startAutoClose()
        HoverKeys.shared.install()
        return card
    }

    private var stacked: [PopupCard] { cards.filter { !$0.isTucked } }

    private func slot(_ index: Int) -> CGRect {
        let vf = (screen ?? NSScreen.main!).visibleFrame, s = PopupCard.size
        let x = Settings.popupOnLeft ? vf.minX + Self.edge : vf.maxX - Self.edge - s.width
        return CGRect(x: x, y: vf.minY + Self.bottom + CGFloat(index) * (s.height + Self.gap), width: s.width, height: s.height)
    }

    /// Springs every stacked card into its slot.
    func layout(except skip: PopupCard? = nil) {
        for (i, card) in stacked.enumerated() where card !== skip {
            let target = PopupCard.windowFrame(forCard: slot(i))
            if card.frame != target { Tween.run(card, to: target, duration: 0.5, curve: Tween.backOut(0.4)) }
        }
    }

    // MARK: swipe toward the edge to dismiss
    // The card slides out from under the cursor, so once a swipe starts the event tap routes (and swallows) the
    // rest of the gesture here; a short idle timer ends it if the tap isn't available.

    private(set) var swiping: PopupCard?
    private var swipeOffset: CGFloat = 0
    private var swipeIdle: Timer?

    func swipe(_ e: NSEvent, starting card: PopupCard? = nil) {
        guard e.momentumPhase == [] else { return }
        if e.phase == .began, let card { swiping = card; swipeOffset = 0 }
        guard let card = swiping else { return }
        if e.phase == .changed {
            swipeOffset = max(0, swipeOffset + (Settings.popupOnLeft ? 1 : -1) * e.scrollingDeltaX)
            nudge(card, by: swipeOffset)
        }
        swipeIdle?.invalidate()
        if e.phase == .ended || e.phase == .cancelled { return endSwipe() }
        swipeIdle = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.endSwipe() }
    }

    private func endSwipe() {
        swipeIdle?.invalidate()
        guard let card = swiping else { return }
        swiping = nil
        if swipeOffset > 50 { close(card, slide: true) } else { layout() }
    }

    private func nudge(_ card: PopupCard, by offset: CGFloat) {
        guard let i = stacked.firstIndex(where: { $0 === card }) else { return }
        let dx = Settings.popupOnLeft ? -offset : offset
        Tween.cancel(card)
        card.setFrame(PopupCard.windowFrame(forCard: slot(i)).offsetBy(dx: dx, dy: 0), display: true)
    }

    // MARK: close

    /// `slide`: fly off past the screen edge (copy / save / swipe); otherwise a quick fade.
    func close(_ card: PopupCard, slide: Bool = false) {
        guard let i = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: i)
        card.isClosing = true
        if hovered === card { hovered = nil }
        card.pauseAutoClose()
        card.cardView.closeQuickLook()
        closedURLs.append(card.url)
        let off = card.frame.offsetBy(dx: (Settings.popupOnLeft ? -1 : 1) * (PopupCard.size.width + Self.edge + 20), dy: 0)
        // Slide-out stays opaque early and fades as it goes.
        Tween.run(card, to: slide ? off : card.frame, alpha: 0, duration: slide ? 0.6 : 0.28, curve: { $0 * $0 },
                  alphaCurve: slide ? { $0 * $0 } : { $0 }) {
            card.orderOut(nil)
        }
        layout()
    }

    func closeAll() { cards.forEach { close($0) } }

    func restoreLast() {
        let shown = Set(cards.map(\.url))
        guard let url = (closedURLs.reversed() + History.all()).first(where: {
            !shown.contains($0) && FileManager.default.fileExists(atPath: $0.path) }),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return NSSound.beep() }
        closedURLs.removeAll { $0 == url }
        show(image, url: url)
    }

    // MARK: actions

    func copy(_ card: PopupCard) {
        Output.copy(card.image, file: card.url)
        log("popup copy \(card.url.lastPathComponent)")
        confirmThenLeave(card, save: false)
    }

    func save(_ card: PopupCard) {
        do { log("popup saved \(try Output.save(card.image).path)") } catch { log("popup save failed: \(error)") }
        confirmThenLeave(card, save: true)
    }

    /// ✓ cross-fades in, holds briefly, then the hover chrome fades as the card slides out.
    private func confirmThenLeave(_ card: PopupCard, save: Bool) {
        guard cards.contains(where: { $0 === card }), !card.isTucked, !card.isClosing else { return close(card, slide: true) }
        card.isClosing = true
        card.pauseAutoClose()
        card.cardView.confirm(save: save)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            card.cardView.hideCurtain()
            self?.close(card, slide: true)
        }
    }

    func saveAll() { cards.forEach { save($0) } }

    /// Pin springs out of the card; the card stays.
    func pin(_ card: PopupCard) { PinWindow.open(card.image, url: card.url, from: card.cardFrame) }

    func saveAs(_ card: PopupCard) {
        if Output.saveAs(card.image, name: card.url.lastPathComponent) { close(card, slide: true) }
    }

    func transform(_ card: PopupCard, rotateLeft: Bool) {
        guard let new = Output.transformed(card.image, rotateLeft: rotateLeft) else { return }
        card.replaceImage(new)
    }

    func trash(_ card: PopupCard) {
        try? FileManager.default.trashItem(at: card.url, resultingItemURL: nil)
        close(card)
        closedURLs.removeAll { $0 == card.url }
    }

    // MARK: Temporarily Hide — slide below the screen edge leaving a 30pt tab; clicking the tab brings it back.

    func tuck(_ card: PopupCard) {
        guard let vf = screen?.frame else { return }
        card.isTucked = true
        card.cardView.setTucked(true)
        card.pauseAutoClose()
        var r = card.cardFrame
        r.origin.y = vf.minY - (PopupCard.size.height - 30)
        Tween.run(card, to: PopupCard.windowFrame(forCard: r), duration: 0.3, curve: Tween.easeInOut)
        layout()
    }

    func untuck(_ card: PopupCard) {
        card.isTucked = false
        card.cardView.setTucked(false)
        layout()
        card.startAutoClose()
    }

    // MARK: hover keys (⌘C copy, ⌘S save, ⌘W close, Space Quick Look) — consumed only while a card is hovered.

    func handleKey(_ event: CGEvent) -> Bool {
        // Hit-test at key time: a card that slid under a still cursor never gets mouseEntered.
        let mouse = NSEvent.mouseLocation
        guard let card = stacked.first(where: { !$0.isClosing && NSMouseInRect(mouse, $0.cardFrame, false) }) else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        switch (code, mods) {
        case (8, .maskCommand): copy(card)                    // ⌘C
        case (1, .maskCommand): save(card)                    // ⌘S
        case (13, .maskCommand): close(card)                  // ⌘W
        case (49, []): card.cardView.toggleQuickLook()        // Space
        default: return false
        }
        return true
    }

}

/// Window frame/alpha tweens on a 120 Hz timer. NSWindow's animator ignored custom timing for these panels,
/// and the motion needs a slight overshoot.
enum Tween {
    private static var active: [ObjectIdentifier: Timer] = [:]

    static func run(_ w: NSWindow, to frame: CGRect, alpha: CGFloat? = nil, duration: Double,
                    curve: @escaping (Double) -> Double, alphaCurve: @escaping (Double) -> Double = { min(1, $0 * 1.6) },
                    done: (() -> Void)? = nil) {
        cancel(w)
        let from = w.frame, fromAlpha = w.alphaValue, start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { t in
            let p = min(1, (CACurrentMediaTime() - start) / duration), k = CGFloat(curve(p))
            w.setFrame(CGRect(x: from.minX + (frame.minX - from.minX) * k, y: from.minY + (frame.minY - from.minY) * k,
                              width: from.width + (frame.width - from.width) * k,
                              height: from.height + (frame.height - from.height) * k).integral, display: true)
            if let alpha { w.alphaValue = fromAlpha + (alpha - fromAlpha) * CGFloat(alphaCurve(p)) }
            if p >= 1 { t.invalidate(); active[ObjectIdentifier(w)] = nil; done?() }
        }
        active[ObjectIdentifier(w)] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func cancel(_ w: NSWindow) { active.removeValue(forKey: ObjectIdentifier(w))?.invalidate() }

    /// Ease-out with overshoot; `s` sets how far past the target it goes (0 = none).
    static func backOut(_ s: Double) -> (Double) -> Double { { t in let u = t - 1; return 1 + (s + 1) * u * u * u + s * u * u } }
    static let easeInOut: (Double) -> Double = { $0 < 0.5 ? 2 * $0 * $0 : 1 - pow(-2 * $0 + 2, 2) / 2 }
}

/// Session event tap: hover shortcuts without the panel taking focus, and swipe tracking (needs Accessibility).
final class HoverKeys {
    static let shared = HoverKeys()
    private var tap: CFMachPort?
    private var asked = false

    func install() {
        guard tap == nil else { return }
        let prompt = !asked
        asked = true
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary) else {
            return log("hover keys disabled: Accessibility not granted")
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.scrollWheel.rawValue),
                                callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = HoverKeys.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown, CaptureBar.handleKey(event) || ScrollingSession.handleKey(event) || PinWindow.handleKey(event) || PopupManager.shared.handleKey(event) { // overlay, then pins above cards
                return nil
            } else if type == .scrollWheel, PopupManager.shared.swiping != nil, let e = NSEvent(cgEvent: event) {
                PopupManager.shared.swipe(e)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return log("hover keys: event tap failed") }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("hover keys enabled")
    }
}
