//! Preferences, stored as JSON in the user's config folder. Never contains image data.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hotkeys {
    pub capture_region: String,
    pub capture_window: String,
    pub capture_screen: String,
    pub extract_text: String,
    pub open_editor: String,
    pub copy_last_capture: String,
}

impl Default for Hotkeys {
    fn default() -> Self {
        Self {
            capture_region: "Ctrl+Shift+4".into(),
            capture_window: "Ctrl+Shift+5".into(),
            capture_screen: "Ctrl+Shift+3".into(),
            extract_text: "Ctrl+Shift+T".into(),
            open_editor: "Ctrl+Shift+E".into(),
            copy_last_capture: "Ctrl+Shift+C".into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Put every capture on the clipboard right away.
    pub quick_copy: bool,
    /// Also open the editor after capturing (always true when quick_copy is off).
    pub open_editor_after_capture: bool,
    pub show_copy_confirmation: bool,
    /// Forget the in-memory capture after this many minutes (0 = keep until quit).
    pub forget_capture_after_minutes: u32,
    pub annotation_color: String,
    pub line_width: f32,
    pub text_size: f32,
    pub hotkeys: Hotkeys,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            quick_copy: true,
            open_editor_after_capture: false,
            show_copy_confirmation: true,
            forget_capture_after_minutes: 15,
            annotation_color: "#FF3B30".into(),
            line_width: 4.0,
            text_size: 28.0,
            hotkeys: Hotkeys::default(),
        }
    }
}

impl Settings {
    pub fn path() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("SnapPaste").join("settings.json"))
    }

    /// Loads settings, writing the defaults on first run so the file is easy to find and edit.
    pub fn load() -> Self {
        let Some(path) = Self::path() else { return Self::default() };
        match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => {
                let settings = Self::default();
                settings.save();
                settings
            }
        }
    }

    pub fn save(&self) {
        let Some(path) = Self::path() else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, text);
        }
    }

    pub fn opens_editor(&self) -> bool {
        !self.quick_copy || self.open_editor_after_capture
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let s: Settings = serde_json::from_str(r#"{"quick_copy": false, "hotkeys": {"capture_region": "Ctrl+Alt+R"}}"#).unwrap();
        assert!(!s.quick_copy);
        assert!(s.opens_editor());
        assert_eq!(s.hotkeys.capture_region, "Ctrl+Alt+R");
        assert_eq!(s.hotkeys.capture_window, "Ctrl+Shift+5");
        assert_eq!(s.forget_capture_after_minutes, 15);
    }

    #[test]
    fn default_hotkeys_parse_and_are_unique() {
        use std::str::FromStr;
        let h = Hotkeys::default();
        let all = [&h.capture_region, &h.capture_window, &h.capture_screen, &h.extract_text, &h.open_editor, &h.copy_last_capture];
        let mut ids = std::collections::HashSet::new();
        for k in all {
            let hk = global_hotkey::hotkey::HotKey::from_str(k).expect(k);
            assert!(ids.insert(hk.id()), "duplicate {k}");
        }
    }
}
