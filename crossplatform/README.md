# SnapPaste for Windows and Linux (beta)

This is the Windows and Linux version of SnapPaste. The macOS app is a separate native Swift app in the repository root. It works the same way: capture → (optionally) edit → it's on the clipboard → paste anywhere. Screenshots stay in memory and are never saved to disk.

> **Beta.** This version is built and tested automatically on Windows and Linux (unit tests plus headless UI tests of the editor and the region/window picker). It has had less hands-on use than the macOS app. Please report anything odd on GitHub Issues.

## Install

### Windows 10/11 (x64)

1. Download `SnapPaste-Windows-x64.exe`.
2. Run it. If SmartScreen says "Windows protected your PC", click **More info › Run anyway**; the app isn't code-signed yet.
3. The SnapPaste icon appears in the system tray (it may be in the ^ overflow area).

You can move the `.exe` anywhere you like, for example `%LOCALAPPDATA%\Programs\SnapPaste`. To start it with Windows, turn on **Launch at Login** in the tray menu.

### Linux (x86_64)

```bash
tar -xzf SnapPaste-Linux-x86_64.tar.gz
cd SnapPaste && ./install.sh
snappaste &
```

Runtime requirements: a desktop with a system tray (StatusNotifier/AppIndicator), plus the GTK 3, AppIndicator and xdo libraries. On Debian/Ubuntu:

```bash
sudo apt install libgtk-3-0 libayatana-appindicator3-1 libxdo3
```

**X11** supports everything, including global shortcuts. **Wayland** doesn't let apps register global shortcuts, so either use the tray menu or bind your desktop's own keyboard shortcuts to these commands:

```bash
snappaste region   # capture a region
snappaste window   # capture a window
snappaste screen   # capture the screen under the pointer
snappaste text     # extract text from a region
```

On Wayland, the screen is captured through the desktop portal, which may ask for permission the first time. To remove SnapPaste, run `./uninstall.sh`.

## Shortcuts (defaults)

| Action | Shortcut |
| --- | --- |
| Capture Region | Ctrl+Shift+4 |
| Capture Window | Ctrl+Shift+5 |
| Capture Entire Screen | Ctrl+Shift+3 |
| Extract Text | Ctrl+Shift+T |
| Edit Last Capture | Ctrl+Shift+E |
| Copy Last Capture | Ctrl+Shift+C |

Change them with **Edit Settings & Shortcuts…** in the tray menu, which opens `settings.json` (in `%APPDATA%\SnapPaste` on Windows, `~/.config/SnapPaste` on Linux). Then choose **Restart SnapPaste**. Shortcuts use names like `Ctrl+Alt+R`, `Shift+Super+S`, or `Ctrl+Shift+F1`; an empty string disables one. If another app already uses a shortcut, the tray menu shows a warning.

The editor's keys are Ctrl+Z / Ctrl+Shift+Z (undo/redo), Ctrl+C (copy), Ctrl+Enter (copy and close), Esc (cancel), and single letters for tools: V select, C crop, P pen, H highlight, R rectangle, O ellipse, L line, A arrow, T text, E eraser.

## How it works

- `snappaste` with no arguments runs in the tray. It does nothing until a shortcut or menu item fires: no polling, no background capture.
- The region and window pickers show a frozen screenshot of the monitor under the pointer. The editor and the Extract Text window are short-lived child processes of the same executable; images move between them through in-memory pipes.
- The tray process owns the clipboard. On Linux the program that copied something must keep running to serve pastes, so that is the tray process rather than a closing window.
- Text recognition uses [ocrs](https://github.com/robertknight/ocrs). Its models are compiled into the executable, so OCR works offline and nothing is uploaded.
- The only file SnapPaste writes is `settings.json` (preferences). On Linux the tray library also writes the tray icon image to a temporary folder.

## Building from source

```bash
cd crossplatform
cargo test
cargo build --release   # target/release/snappaste(.exe)
```

Linux build dependencies are listed in `.github/workflows/windows-linux.yml`. On macOS this code builds and its tests run (that's how it was developed), but use the native macOS app instead.

## Licenses

SnapPaste is MIT licensed. It bundles DejaVu Sans Bold (see `assets/DejaVu-LICENSE.txt`) and the ocrs text detection and recognition models.
