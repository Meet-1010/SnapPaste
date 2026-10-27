# SnapPaste

A lightweight macOS menu-bar screenshot tool built for pasting into AI chats.

**Capture → (optionally) edit → it's on the clipboard → ⌘V anywhere.**

SnapPaste never saves screenshots to disk. There is no history, gallery, account, network access, or telemetry. The current capture lives in memory only, and quitting the app discards it. Whatever you already copied stays on the system clipboard as usual.

**Website and downloads: <https://snappaste-omega.vercel.app>**

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 14+ (Apple silicon & Intel) | [SnapPaste-macOS.dmg](https://github.com/Meet-1010/SnapPaste/releases/latest/download/SnapPaste-macOS.dmg) | Native Swift app (this folder) |
| Windows 10/11 x64 | [SnapPaste-Windows-x64.exe](https://github.com/Meet-1010/SnapPaste/releases/latest/download/SnapPaste-Windows-x64.exe) | Beta: see [`crossplatform/`](crossplatform/README.md) |
| Linux x86_64 | [SnapPaste-Linux-x86_64.tar.gz](https://github.com/Meet-1010/SnapPaste/releases/latest/download/SnapPaste-Linux-x86_64.tar.gz) | Beta: see [`crossplatform/`](crossplatform/README.md) |

The downloaded macOS app is ad-hoc signed, not notarized. On first launch, go to **System Settings › Privacy & Security** and click **Open Anyway**.

## Requirements

- macOS 14 Sonoma or later (developed and tested on macOS 27 with Xcode 27.1, Apple silicon)
- Xcode 16 or later to build (the project uses Xcode's synchronized folders, project format 77)

## Build and run

```bash
scripts/build.sh --install   # Release build → /Applications/SnapPaste.app, then launch it
scripts/build.sh --run       # Release build, launch from build/ without installing
scripts/test.sh              # run the XCTest suite
```

Or open `SnapPaste.xcodeproj` in Xcode and press ⌘R. The tests are under Product › Test (⌘U).

The core logic is also a plain Swift package, so you can test it without Xcode's UI:

```bash
cd Packages/SnapPasteCore && swift test
```

### First launch

1. Look for the viewfinder icon in the menu bar. There is no Dock icon.
2. Press **⌃⇧4** (Capture Region). macOS asks for **Screen Recording** permission.
3. In **System Settings › Privacy & Security › Screen & System Audio Recording**, turn on SnapPaste.
4. Quit and reopen SnapPaste (the permission window has a **Quit & Reopen** button). macOS applies the change only to newly started apps.

If macOS doesn't prompt, or you dismissed the prompt, SnapPaste shows its own help window with **Request Access** and **Open System Settings** buttons. It never repeats the system prompt on its own.

## Using it

| Action | Default shortcut | Notes |
| --- | --- | --- |
| Open SnapPaste menu | ⌃⇧S | Also: click the menu-bar icon |
| Capture Region | ⌃⇧4 | Drag to select. ⇧ for a square, ↩ for the whole display, esc / right-click to cancel |
| Capture Window | ⌃⇧5 | Hover to highlight, click to capture just that window (no overlapping windows, no shadow) |
| Capture Entire Screen | ⌃⇧3 | With several displays, click the one you want |
| Copy Last Capture | ⌃⇧C | Copies the in-memory capture, including its edits |
| Open Editor | ⌃⇧E | Re-opens the last capture with its edits |
| Extract Text | ⌃⇧T | Select a region and its text is recognized. The image doesn't go to the clipboard |

The defaults use ⌃⇧ because macOS and most apps leave it free. The digits mirror the system's ⌘⇧3/4/5. Every shortcut can be changed or removed in **Settings › Shortcuts**. SnapPaste refuses combinations without ⌘ or ⌃, plain ⌘+key, duplicates, and shortcuts macOS already uses. If another app holds a combination, Settings says so.

### After a capture

- **Quick Copy on** (default): the image goes straight to the clipboard and a small "Copied" bubble appears. Paste with ⌘V.
- **Open the editor after capturing**: with Quick Copy on, the raw capture is copied *and* the editor opens. Clicking Copy replaces the clipboard with the edited version.
- **Quick Copy off**: captures always open in the editor, and nothing reaches the clipboard until you click **Copy**.

### Editor

Tools (single-key shortcuts in brackets): Select (V), Crop (C), Pen (P), Highlighter (H), Rectangle (R), Ellipse (O), Line (L), Arrow (A), Text (T), Eraser (E).

- **Crop:** drag the area to keep, drag inside it to move it, then press ↩ or **Apply Crop**.
- **Resize…:** width and height in pixels, with an aspect-ratio lock and 25/50/75/200% presets. Sizes are capped at 16,384 px per side and 100 MP in total.
- **Shapes:** hold ⇧ for squares, circles, and 45° lines and arrows.
- **Text:** click to type. ↩ finishes, ⌥↩ starts a new line, esc cancels. Drag text to move it and double-click to edit it.
- **Select:** click an annotation, then drag or use the arrow keys (⇧ for 10 px) to move it, ⌫ to delete it, or the swatches and sliders to restyle it.
- **Eraser:** removes whole annotations. It never paints over the screenshot.
- **Undo/redo:** ⌘Z / ⇧⌘Z cover everything: strokes, shapes, text, erasing, moves, style changes, crop, resize, and reset.
- **Zoom:** pinch, ⌘-scroll, ⌘= / ⌘−, ⌘0 (fit), ⌘1 (actual pixels). Scroll or hold Space and drag to pan.
- **Copy (⌘C), Copy & Close (⌘↩), Cancel (esc):** Cancel closes without touching the clipboard. Your edits stay with the capture in memory, so **Edit Last Capture** picks them up again. **Reset Edits…** returns to the original capture, and that is undoable too.

### Extract Text (OCR)

Text recognition uses Apple's Vision framework (`VNRecognizeTextRequest`, accurate mode) entirely on your Mac. It runs off the main thread, shows progress, and can be cancelled. The result appears in an editable text panel: select part of it and press ⌘C, or click **Copy Extracted Text** (⇧⌘C) to copy all of it.

By default, OCR reads the screenshot without your annotations. Turn on **Settings › Text › Include annotations** to include text you typed onto the capture. The recognition language defaults to English (US); **Automatic** and every other language Vision supports on your Mac are available. The first recognition after a reboot can take a while as macOS loads the model. After that it is typically well under a second.

## Privacy and resources

- **No files.** Captures are `CGImage`s in memory. Copying encodes a PNG in memory (ImageIO with a `CFData` destination) and writes it to `NSPasteboard`. No temporary file is involved. `ClipboardTests.testPreparingClipboardImageWritesNoFiles` checks this.
- **Clipboard format:** a lossless PNG (`public.png`). The pasteboard server converts to TIFF on demand for apps that ask for it, so no second, larger TIFF copy is stored.
- **Memory:** only the latest capture is kept. It is released when you capture again, click ✕ in the menu, choose **Forget Now** in Settings › Privacy, or quit. By default it is also released after 15 minutes without the editor open; you can change this in Settings › General.
- **No background work:** nothing is captured, scanned, recognized, or polled while SnapPaste is idle. Shortcuts are Carbon hot keys, so macOS notifies the app only when one of *its* combinations is pressed. There is no key logging, and **Accessibility permission is not required**.
- **Sandboxed with no network entitlement,** so the app cannot open network connections.
- **Settings** (toggles, colors, shortcuts, OCR language) are stored in `UserDefaults`. Screenshot pixels and recognized text never are.
- **Launch at login** uses `SMAppService` and is only turned on when you switch it on in Settings.

What has been measured, on an Apple-silicon Mac running macOS 27 with `ps` and `top`, for the idle Release build: 0.0% CPU, about 1 idle wake-up per sampling interval, and a memory footprint of about 13 MB (about 70 MB resident, including shared system frameworks). A capture adds memory of roughly its pixel count × 4 bytes until it is released. Instruments profiling has not been done.

## Architecture

```
SnapPaste.xcodeproj
SnapPaste/                         App target (AppKit + SwiftUI, Swift 6, main-actor by default)
  App/            AppDelegate, AppController (coordinates everything), hidden main menu
  MenuBar/        NSStatusItem + popover UI (keyboard navigable)
  Capture/        ScreenCaptureKit stills, selection overlays (region / window / display), coordinator
  Clipboard/      Background PNG encoding → NSPasteboard
  Editor/         Window controller, SwiftUI chrome, AppKit canvas (layer-backed, partial redraws)
  OCR/            Extract Text window and session
  Hotkeys/        Carbon hot key registration, keyboard layout names, system-shortcut lookup
  Settings/       SettingsStore (UserDefaults), shortcut recorder, Settings window
  Permissions/    Screen Recording check / help window
  Feedback/       Click-through "Copied" HUD
Packages/SnapPasteCore/            Platform logic with no UI, unit tested
  Geometry/       Crop, resize and viewport math; screen coordinate conversions
  Annotations/    Annotation model, hit testing, text layout
  Rendering/      Shared annotation drawer + image renderer (crop, resize, flatten, thumbnail)
  Editor/         EditorDocument + EditHistory (undo/redo with coalescing)
  Capture/        CaptureStore (in-memory capture), post-capture workflow, error classification
  Clipboard/      PNG encoder, clipboard writer
  OCR/            Vision recognizer (cancellable), line assembly
  Shortcuts/      Key combos, defaults, validation
```

Design notes:

- **Non-destructive editing.** The capture stays untouched. Annotations are vector objects in image-pixel space, and undo/redo stores whole editor states (cheap, because images are shared references; only crop and resize keep extra bitmaps). The same `AnnotationDrawer` draws both the on-screen canvas and the exported image, so what you see is what gets copied.
- **Smooth editing on large captures.** The screenshot is a layer's contents, so the GPU handles scaling and scrolling. Annotations, the stroke in progress, and editor chrome each have their own view, and a drag only invalidates the area around the stroke being drawn.
- **Capture.** Still images come from `SCScreenshotManager`; no stream is started. Region and full-display captures exclude SnapPaste's own windows through the content filter, so overlays and the editor never show up in a capture. Window captures use a desktop-independent window filter, so overlapping windows don't bleed in. Captures are requested in sRGB at the display's native pixel scale.
- **Focus.** Selection overlays are non-activating panels, so the app you're in stays frontmost. After Copy & Close or Cancel, focus returns to the app you came from, ready for ⌘V.

## Tests

66 XCTest cases in `Packages/SnapPasteCore/Tests` cover:

- crop math, aspect-preserving resize, and resize validation;
- view↔image coordinate mapping, zoom anchoring, and screen-coordinate conversions;
- annotation hit testing, transforms, and pixel-checked rendering (stroke placement, highlighter translucency, text);
- undo/redo, including coalescing, limits, crop and resize, reset, and erase;
- capture-store memory release, post-capture workflow, and cancellation and permission error mapping;
- clipboard PNG preparation through a private named pasteboard: quick copy uses the raw capture, edited copy includes annotations, crop and resize, and no files are written;
- OCR line assembly, real Vision recognition, an empty image, and cancellation;
- shortcut defaults, validation, persistence, and modifier conversion.

Things not covered by automated tests, because they need Screen Recording permission or a person at the keyboard: real screen and window capture, the overlays, and pasting into other apps. These were checked by hand in the running app.

## Signing, distribution, limitations

- The project signs **ad hoc** ("Sign to Run Locally": `CODE_SIGN_IDENTITY = -`, hardened runtime, App Sandbox), so no Apple Developer account is needed to build and run.
- macOS ties Screen Recording permission to the code signature. An ad-hoc signature changes with every build, so **after rebuilding you may need to re-enable SnapPaste** in Screen Recording settings (remove the old entry first if it's stale). To avoid this, set your own Apple Development team in the target's Signing settings; a free Apple ID works in Xcode.
- To give the app to other people, you need a Developer ID certificate and notarization. An ad-hoc-signed copy downloaded from elsewhere is blocked by Gatekeeper.
- Recent macOS versions periodically ask you to reconfirm Screen Recording access for apps that use ScreenCaptureKit. That prompt comes from macOS.
- Protected content (DRM video, some password fields, windows that opt out of capture) may appear black or be omitted. Minimized windows and windows on other Spaces can't be captured.
- Shortcuts that macOS itself uses (such as ⌘⇧4) are taken by the system before any app sees them, so they can't be recorded.
- A region selection is limited to the display where the drag started.
- The pasted PNG carries the capture's full pixel resolution. Retina captures are 2× the on-screen point size, which is what AI chats want. Use **Resize…** to make them smaller.
