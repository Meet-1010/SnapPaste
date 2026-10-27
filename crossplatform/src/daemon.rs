//! The background process: tray icon, global shortcuts, capture flow, and clipboard ownership.
//! It is idle until a shortcut or menu item fires; UI windows run as short-lived child processes.

use crate::capture::{self, MonitorShot, WindowInfo};
use crate::clipboard::ClipboardService;
use crate::ipc::{self, Message};
use crate::settings::Settings;
use image::RgbaImage;
use std::io::{BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

pub const WEBSITE: &str = "https://snappaste.vercel.app";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cmd {
    Region,
    Window,
    Screen,
    ExtractText,
    EditLast,
    CopyLast,
    ForgetLast,
    ToggleQuickCopy,
    ToggleOpenEditor,
    ToggleLaunchAtLogin,
    EditSettings,
    Restart,
    OpenWebsite,
    Quit,
}

impl Cmd {
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "region" => Cmd::Region,
            "window" => Cmd::Window,
            "screen" => Cmd::Screen,
            "text" => Cmd::ExtractText,
            "edit" => Cmd::EditLast,
            "copy" => Cmd::CopyLast,
            "forget" => Cmd::ForgetLast,
            "quick_copy" => Cmd::ToggleQuickCopy,
            "open_editor" => Cmd::ToggleOpenEditor,
            "login" => Cmd::ToggleLaunchAtLogin,
            "settings" => Cmd::EditSettings,
            "restart" => Cmd::Restart,
            "website" => Cmd::OpenWebsite,
            "quit" => Cmd::Quit,
            _ => return None,
        })
    }
}

pub enum Event {
    Command(Cmd),
    CopyImage(RgbaImage),
    CopyText(String),
    EditorClosed { generation: u64, image: Option<RgbaImage> },
    Forget(u64),
}

pub fn run() -> Result<(), String> {
    if cfg!(target_os = "macos") {
        return Err("On macOS, please use the native SnapPaste app (SnapPaste.dmg) from https://snappaste.vercel.app".into());
    }
    crate::platform::ensure_single_instance()?;
    let settings = Settings::load();
    let (tx, rx) = channel::<Event>();
    let controller = Controller::new(settings.clone(), tx.clone());
    std::thread::Builder::new().name("controller".into()).spawn(move || controller.run(rx)).map_err(|e| e.to_string())?;
    crate::platform::listen_for_cli(tx.clone());
    crate::platform::run_event_loop(&settings, tx)
}

struct Controller {
    settings: Settings,
    tx: Sender<Event>,
    clipboard: ClipboardService,
    exe: PathBuf,
    last: Option<RgbaImage>,
    generation: u64,
    editor: Option<(Child, u64)>,
}

impl Controller {
    fn new(settings: Settings, tx: Sender<Event>) -> Self {
        Self {
            settings,
            tx,
            clipboard: ClipboardService::start(),
            exe: std::env::current_exe().unwrap_or_else(|_| PathBuf::from("snappaste")),
            last: None,
            generation: 0,
            editor: None,
        }
    }

    fn run(mut self, rx: Receiver<Event>) {
        for event in rx {
            match event {
                Event::Command(cmd) => self.command(cmd),
                Event::CopyImage(image) => {
                    let (w, h) = image.dimensions();
                    self.last = Some(image.clone());
                    self.clipboard.copy_image(image);
                    self.confirm("Copied to clipboard", &format!("{w} × {h} px"));
                }
                Event::CopyText(text) => {
                    let count = text.chars().count();
                    self.clipboard.copy_text(text);
                    self.confirm("Text copied", &format!("{count} characters"));
                }
                Event::EditorClosed { generation, image } => {
                    if self.editor.as_ref().is_some_and(|(_, g)| *g == generation) {
                        if let Some((mut child, _)) = self.editor.take() {
                            let _ = child.wait();
                        }
                        if let Some(image) = image {
                            self.last = Some(image);
                        }
                        self.schedule_forget();
                    }
                }
                Event::Forget(generation) => {
                    if generation == self.generation && self.editor.is_none() {
                        self.last = None;
                    }
                }
            }
        }
    }

    fn command(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::Region => self.capture_region(false),
            Cmd::ExtractText => self.capture_region(true),
            Cmd::Window => self.capture_window(),
            Cmd::Screen => match capture::capture_monitor_under_cursor() {
                Ok(shot) => self.handle_capture(shot.image),
                Err(e) => self.warn(&e),
            },
            Cmd::EditLast => match self.last.clone() {
                Some(image) => self.open_editor(image),
                None => self.confirm("Nothing captured yet", &format!("Press {} to capture a region", self.settings.hotkeys.capture_region)),
            },
            Cmd::CopyLast => match self.last.clone() {
                Some(image) => {
                    let (w, h) = image.dimensions();
                    self.clipboard.copy_image(image);
                    self.confirm("Copied to clipboard", &format!("{w} × {h} px"));
                }
                None => self.confirm("Nothing captured yet", &format!("Press {} to capture a region", self.settings.hotkeys.capture_region)),
            },
            Cmd::ForgetLast => {
                self.close_editor();
                self.last = None;
            }
            Cmd::ToggleQuickCopy => {
                self.settings.quick_copy = !self.settings.quick_copy;
                self.settings.save();
            }
            Cmd::ToggleOpenEditor => {
                self.settings.open_editor_after_capture = !self.settings.open_editor_after_capture;
                self.settings.save();
            }
            Cmd::ToggleLaunchAtLogin => {
                if let Err(e) = crate::platform::toggle_launch_at_login() {
                    self.warn(&format!("Couldn't change Launch at Login: {e}"));
                }
            }
            Cmd::EditSettings => {
                self.settings.save();
                if let Some(path) = Settings::path() {
                    crate::platform::open_path(&path.to_string_lossy());
                }
            }
            Cmd::Restart => {
                self.close_editor();
                let _ = Command::new(&self.exe).arg("--restarted").spawn();
                std::process::exit(0);
            }
            Cmd::OpenWebsite => crate::platform::open_path(WEBSITE),
            Cmd::Quit => {
                self.close_editor();
                std::process::exit(0);
            }
        }
    }

    // MARK: Capture

    fn capture_region(&mut self, for_text: bool) {
        let shot = match capture::capture_monitor_under_cursor() {
            Ok(shot) => shot,
            Err(e) => return self.warn(&e),
        };
        if let Some(Message::Region { x, y, w, h }) = self.run_picker("region", &shot, &[]) {
            let rect = crate::annotate::RectF { x: x as f32, y: y as f32, w: w as f32, h: h as f32 };
            if let Some(image) = crate::render::crop(&shot.image, rect) {
                if for_text {
                    self.open_text_window(image);
                } else {
                    self.handle_capture(image);
                }
            }
        }
    }

    fn capture_window(&mut self) {
        let shot = match capture::capture_monitor_under_cursor() {
            Ok(shot) => shot,
            Err(e) => return self.warn(&e),
        };
        let windows = capture::windows_on(&shot);
        if let Some(Message::Window(index)) = self.run_picker("window", &shot, &windows) {
            match windows.get(index).and_then(|w| capture::capture_window(w, &shot)) {
                Some(image) => self.handle_capture(image),
                None => self.warn("That window can't be captured."),
            }
        }
    }

    /// Shows the full-screen picker over a frozen screenshot and waits for the user's choice.
    fn run_picker(&self, mode: &str, shot: &MonitorShot, windows: &[WindowInfo]) -> Option<Message> {
        let (x, y, w, h) = shot.logical_frame();
        crate::platform::allow_child_focus();
        let mut child = Command::new(&self.exe)
            .args(["--overlay", mode, &x.to_string(), &y.to_string(), &w.to_string(), &h.to_string()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .ok()?;
        {
            let mut stdin = child.stdin.take()?;
            if mode == "window" {
                writeln!(stdin, "WINDOWS {}", serde_json::to_string(windows).ok()?).ok()?;
            }
            ipc::write_image(&mut stdin, &shot.image).ok()?;
        }
        let mut stdout = BufReader::new(child.stdout.take()?);
        let message = ipc::read_message(&mut stdout).ok().flatten();
        let _ = child.wait();
        message
    }

    fn handle_capture(&mut self, image: RgbaImage) {
        self.close_editor();
        self.generation += 1;
        self.last = Some(image.clone());
        if self.settings.quick_copy {
            let (w, h) = image.dimensions();
            self.clipboard.copy_image(image.clone());
            self.confirm("Copied to clipboard", &format!("{w} × {h} px"));
        }
        if self.settings.opens_editor() {
            self.open_editor(image);
        } else {
            self.schedule_forget();
        }
    }

    // MARK: Child windows

    fn spawn_ui(&self, args: &[&str], image: &RgbaImage) -> Option<Child> {
        crate::platform::allow_child_focus();
        let mut child = Command::new(&self.exe).args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().ok()?;
        let mut stdin = child.stdin.take()?;
        let image = image.clone();
        std::thread::spawn(move || {
            let _ = ipc::write_image(&mut stdin, &image);
        });
        Some(child)
    }

    /// Forwards a child's messages to the controller until it exits.
    fn forward(&self, child: &mut Child, generation: Option<u64>) {
        let Some(stdout) = child.stdout.take() else { return };
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut closed = false;
            while let Ok(Some(message)) = ipc::read_message(&mut reader) {
                let event = match message {
                    Message::CopyImage(image) => Event::CopyImage(image),
                    Message::CopyText(text) => Event::CopyText(text),
                    Message::Closed(image) => {
                        closed = true;
                        match generation {
                            Some(generation) => Event::EditorClosed { generation, image },
                            None => continue,
                        }
                    }
                    _ => continue,
                };
                let _ = tx.send(event);
            }
            if let (Some(generation), false) = (generation, closed) {
                let _ = tx.send(Event::EditorClosed { generation, image: None });
            }
        });
    }

    fn open_editor(&mut self, image: RgbaImage) {
        self.close_editor();
        let width = self.settings.line_width.to_string();
        let size = self.settings.text_size.to_string();
        let args = ["--editor", self.settings.annotation_color.as_str(), width.as_str(), size.as_str()];
        if let Some(mut child) = self.spawn_ui(&args, &image) {
            self.forward(&mut child, Some(self.generation));
            self.editor = Some((child, self.generation));
        }
    }

    fn open_text_window(&mut self, image: RgbaImage) {
        if let Some(mut child) = self.spawn_ui(&["--ocr"], &image) {
            self.forward(&mut child, None);
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
    }

    fn close_editor(&mut self) {
        if let Some((mut child, _)) = self.editor.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn schedule_forget(&self) {
        let minutes = self.settings.forget_capture_after_minutes;
        if minutes == 0 || self.last.is_none() {
            return;
        }
        let (tx, generation) = (self.tx.clone(), self.generation);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(minutes as u64 * 60));
            let _ = tx.send(Event::Forget(generation));
        });
    }

    // MARK: Feedback

    fn confirm(&self, title: &str, detail: &str) {
        if self.settings.show_copy_confirmation {
            self.toast(title, detail);
        }
    }

    fn warn(&self, message: &str) {
        eprintln!("SnapPaste: {message}");
        self.toast("SnapPaste", message);
    }

    fn toast(&self, title: &str, detail: &str) {
        let (x, y) = capture::monitor_under_cursor()
            .ok()
            .map(|m| {
                let shot_scale = m.scale_factor().unwrap_or(1.0).max(0.5);
                let mx = m.x().unwrap_or(0) as f32 / shot_scale;
                let my = m.y().unwrap_or(0) as f32 / shot_scale;
                let mw = m.width().unwrap_or(1280) as f32 / shot_scale;
                (mx + mw / 2.0 - 160.0, my + 48.0)
            })
            .unwrap_or((100.0, 60.0));
        if let Ok(mut child) = Command::new(&self.exe).args(["--toast", title, detail, &x.to_string(), &y.to_string()]).spawn() {
            std::thread::spawn(move || {
                let _ = child.wait();
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_names() {
        assert_eq!(Cmd::from_name("region"), Some(Cmd::Region));
        assert_eq!(Cmd::from_name("text"), Some(Cmd::ExtractText));
        assert_eq!(Cmd::from_name("nope"), None);
    }
}
