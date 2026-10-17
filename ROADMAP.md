# Glint roadmap

Next release: **v0.3.0**, which turns screenshots into ready-to-share images. All three features build on the editor's existing background tool (`Background` in `Editor/Doc.swift`, drawn by `Render.drawBackground`). That way frames, cards, padding, shadow and the annotation tools all combine, and everything stays editable until export.

| # | Feature | Effort | Touches |
|---|---|---|---|
| 1 | Device Frames | M | `Doc.swift` (`Background.frame`, layout, render), `Editor/Frames.swift` (new), `BackgroundPanel` |
| 2 | Share Cards (reworked into social post mockups, 2026-10-17) | M | `Doc.swift` (`Background.card`), `Editor/ShareCard.swift` (new), `BackgroundPanel`, export |
| 3 | Code Cards | M–L | `Editor/CodeCard.swift` (new: window + highlighter + renderer), menu bar, Capture Bar |

Then: tag `v0.3.0`. The release workflow builds, notarises and publishes the DMG.

---

## 1. Device Frames
**What you see:** in the background panel, a new **Frame** row: None · Mac window · Browser · MacBook · iPhone · iPad. Pick one and the screenshot sits inside it. Shadow, padding and the gradient or wallpaper behind it still apply.

- `Background.frame: DeviceFrame?` with `style` and `appearance` (light/dark/auto from the screenshot's edge colour).
- **Drawn in code, not bitmaps**, so it's sharp at any size and adds no assets:
  - **Mac window:** title bar with traffic lights and optional title text.
  - **Browser:** same as Mac window, plus an address bar showing editable URL text.
  - **MacBook:** dark bezel, camera notch, aluminium base with the hinge lip.
  - **iPhone:** rounded bezel with Dynamic Island. Non-phone-shaped captures are letterboxed inside the screen.
  - **iPad:** uniform bezel.
- `DeviceFrame.insets(for: imageSize)` feeds `Doc.layout`, which grows the content box by the frame. The image's corner clipping follows the frame's screen radius.
- Annotations stay in image coordinates, so they line up whether a frame is on or off.
- **Self-test:** the layout maths for each frame (canvas size and image origin), and frame plus ratio together.
- **Check:** `--demo-editor` screenshots of each frame in light and dark.

## 2. Share Cards
**What you see:** a **Card** section in the background panel. Type a title (and an optional subtitle or @handle), choose where the text sits (above, below or beside), and pick a size: **X/Twitter 1600×900 · LinkedIn 1200×627 · Open Graph 1200×630 · Square 1080×1080 · Story 1080×1920 · README banner 1280×640**. The framed screenshot and text are laid out to fill that exact size.

- `Background.card: ShareCard?` with `title`, `subtitle`, `textPosition`, `textStyle` (Bold / Editorial serif / Mono), `textColor` (auto contrast against the fill), and `preset` (pixel size).
- Layout: the text block and the framed screenshot share the canvas with set gaps. The screenshot scales down to fit; the canvas is the preset's aspect, using the existing `ratio` logic.
- **Export:** when a preset is set, the flattened image is resampled to exactly the preset's pixels. Copy, save and drag all use it.
- **Self-test:** each preset exports at its exact pixel size, and long titles wrap without overlapping the screenshot.
- **Check:** demo screenshots for three presets × three text positions.

## 3. Code Cards
**What you see:** menu bar → **New Code Card…** (also in the Capture Bar). A window opens with a code box, a language picker (Auto, Swift, JavaScript/TypeScript, Python, Go, Rust, JSON, Shell, HTML/CSS, SQL) and a theme picker. Paste code and press **Create**. Glint renders a polished, syntax-coloured window and opens it in the editor, where frames, share cards, backgrounds and annotations all work as with any screenshot.

- **Highlighter:** a small tokenizer, with no dependencies.
  - It handles comments, strings, numbers, keywords, types (capitalised words), and function calls (a word followed by `(`).
  - It uses per-language keyword sets, and auto-detects the language from telltale tokens (`func`/`let`, `def`/`:`, `{`/`"key":`, `#!/bin/`).
- **Renderer:**
  - SF Mono at 2× scale, line numbers optional, tab width 4;
  - long lines wrap at a chosen width (60 / 80 / 100 columns);
  - optional window chrome: traffic lights plus a filename field;
  - **themes:** Glint Dark, Glint Light, Solarized, Dracula-style;
  - the output is a `CGImage` at a real pixel scale, handed to `Editor.open(image:)`, so it's an ordinary editor document from then on.
- The code box keeps its text between openings, and **⌘↩** creates. If code is on the clipboard when the window opens, it's pasted in automatically.
- **Self-test:** tokenizer cases (a string containing a comment marker, an escaped quote, a nested template literal, a keyword inside an identifier) and language auto-detection.
- **Check:** demo screenshots of the same snippet in each theme.

---

## Not planned
Smart redact, step recorder, before/after diff, smarter Capture Text (tables, QR codes, translation), searching history by text, style presets, collage, watermark stamps, and anything that ties Glint to Cubby. These were all considered and declined (2026-10-17).
