//! Tray menu and global shortcuts. Both only notify the controller; no work happens here.

use crate::daemon::{Cmd, Event};
use crate::settings::Settings;
use global_hotkey::hotkey::HotKey;
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::mpsc::Sender;
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

fn label(title: &str, shortcut: &str) -> String {
    if shortcut.trim().is_empty() {
        title.to_string()
    } else if cfg!(windows) {
        format!("{title}\t{shortcut}")
    } else {
        format!("{title}    ({shortcut})")
    }
}

pub fn build_tray(settings: &Settings, hotkey_errors: &[String], tx: Sender<Event>) -> Result<TrayIcon, String> {
    let hk = &settings.hotkeys;
    let menu = Menu::new();
    let item = |id: &str, title: String| MenuItem::with_id(id, title, true, None);
    let mut items: Vec<Box<dyn tray_icon::menu::IsMenuItem>> = vec![
        Box::new(item("region", label("Capture Region", &hk.capture_region))),
        Box::new(item("window", label("Capture Window", &hk.capture_window))),
        Box::new(item("screen", label("Capture Entire Screen", &hk.capture_screen))),
        Box::new(item("text", label("Extract Text…", &hk.extract_text))),
        Box::new(PredefinedMenuItem::separator()),
        Box::new(item("edit", label("Edit Last Capture", &hk.open_editor))),
        Box::new(item("copy", label("Copy Last Capture", &hk.copy_last_capture))),
        Box::new(item("forget", "Forget Last Capture".into())),
        Box::new(PredefinedMenuItem::separator()),
        Box::new(CheckMenuItem::with_id("quick_copy", "Quick Copy (copy right after capture)", true, settings.quick_copy, None)),
        Box::new(CheckMenuItem::with_id("open_editor", "Open Editor After Capture", true, settings.open_editor_after_capture, None)),
        Box::new(CheckMenuItem::with_id("login", "Launch at Login", true, crate::platform::launch_at_login_enabled(), None)),
        Box::new(item("settings", "Edit Settings & Shortcuts…".into())),
        Box::new(item("restart", "Restart SnapPaste (apply settings)".into())),
    ];
    if !hotkey_errors.is_empty() {
        items.push(Box::new(PredefinedMenuItem::separator()));
        items.push(Box::new(MenuItem::new(format!("⚠ Shortcut unavailable: {}", hotkey_errors.join(", ")), false, None)));
    }
    items.push(Box::new(PredefinedMenuItem::separator()));
    items.push(Box::new(item("website", "SnapPaste Website".into())));
    items.push(Box::new(item("quit", "Quit SnapPaste".into())));
    let refs: Vec<&dyn tray_icon::menu::IsMenuItem> = items.iter().map(|b| b.as_ref()).collect();
    menu.append_items(&refs).map_err(|e| e.to_string())?;

    MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
        if let Some(cmd) = Cmd::from_name(event.id.0.as_str()) {
            let _ = tx.send(Event::Command(cmd));
        }
    }));

    let (rgba, w, h) = {
        let img = image::load_from_memory(include_bytes!("../assets/icon-64.png")).map_err(|e| e.to_string())?.to_rgba8();
        let (w, h) = img.dimensions();
        (img.into_raw(), w, h)
    };
    TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(true)
        .with_tooltip("SnapPaste — clipboard-first screenshots")
        .with_icon(Icon::from_rgba(rgba, w, h).map_err(|e| e.to_string())?)
        .build()
        .map_err(|e| e.to_string())
}

/// Registers the configured shortcuts. Returns the manager (keep it alive) and any failures.
pub fn register_hotkeys(settings: &Settings, tx: Sender<Event>) -> (Option<GlobalHotKeyManager>, Vec<String>) {
    let manager = match GlobalHotKeyManager::new() {
        Ok(m) => m,
        Err(e) => return (None, vec![format!("global shortcuts aren't available here ({e})")]),
    };
    let hk = &settings.hotkeys;
    let mut map = HashMap::new();
    let mut errors = Vec::new();
    for (spec, cmd) in [
        (&hk.capture_region, Cmd::Region),
        (&hk.capture_window, Cmd::Window),
        (&hk.capture_screen, Cmd::Screen),
        (&hk.extract_text, Cmd::ExtractText),
        (&hk.open_editor, Cmd::EditLast),
        (&hk.copy_last_capture, Cmd::CopyLast),
    ] {
        if spec.trim().is_empty() {
            continue;
        }
        match HotKey::from_str(spec) {
            Ok(hotkey) => match manager.register(hotkey) {
                Ok(()) => {
                    map.insert(hotkey.id(), cmd);
                }
                Err(_) => errors.push(spec.clone()),
            },
            Err(_) => errors.push(format!("{spec} (not understood)")),
        }
    }
    GlobalHotKeyEvent::set_event_handler(Some(move |event: GlobalHotKeyEvent| {
        if event.state() == HotKeyState::Pressed {
            if let Some(cmd) = map.get(&event.id()) {
                let _ = tx.send(Event::Command(*cmd));
            }
        }
    }));
    (Some(manager), errors)
}
