// No console window on Windows; the app lives in the system tray.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod annotate;
mod capture;
mod clipboard;
mod daemon;
mod editor;
mod font;
mod history;
mod ipc;
mod ocr;
mod ocr_window;
mod overlay;
#[cfg_attr(target_os = "macos", allow(dead_code))]
mod platform;
mod render;
mod settings;
mod toast;
#[cfg_attr(target_os = "macos", allow(dead_code))]
mod tray;
mod ui_common;

const HELP: &str = "SnapPaste — clipboard-first screenshots

Usage:
  snappaste                 Start SnapPaste in the system tray
  snappaste region          Capture a region (SnapPaste must be running)
  snappaste window          Capture a window
  snappaste screen          Capture the screen under the pointer
  snappaste text            Extract text from a region
  snappaste edit            Open the last capture in the editor
  snappaste copy            Copy the last capture again
  snappaste --open FILE     Open an image in the editor
  snappaste --version

Screenshots stay in memory and go straight to the clipboard; nothing is saved to disk.";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rest = args.get(2..).unwrap_or(&[]).to_vec();
    let result = match args.get(1).map(String::as_str) {
        None => daemon::run(),
        Some("--restarted") => {
            // Let the previous instance exit and release its single-instance lock.
            std::thread::sleep(std::time::Duration::from_millis(900));
            daemon::run()
        }
        Some("--overlay") => overlay::run(&rest),
        Some("--editor") => editor::run(&rest),
        Some("--ocr") => ocr_window::run(),
        Some("--toast") => toast::run(&rest),
        Some("--open") => open_file(rest.first()),
        Some("--version" | "-V") => {
            println!("SnapPaste {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("--help" | "-h" | "help") => {
            println!("{HELP}");
            Ok(())
        }
        Some(command) if daemon::Cmd::from_name(command).is_some() => platform::send_cli(command),
        Some(other) => Err(format!("Unknown option {other:?}.\n\n{HELP}")),
    };
    if let Err(message) = result {
        eprintln!("{message}");
        std::process::exit(1);
    }
}

/// Opens an image file in the editor. Copies go to the clipboard from this process, which stays
/// alive while the editor is open.
fn open_file(path: Option<&String>) -> Result<(), String> {
    use std::io::{BufReader, Write};
    use std::process::{Command, Stdio};
    let path = path.ok_or("Usage: snappaste --open FILE")?;
    let image = image::open(path).map_err(|e| format!("couldn't open {path}: {e}"))?.to_rgba8();
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut child = Command::new(exe)
        .arg("--editor")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let writer = std::thread::spawn(move || {
        let _ = ipc::write_image(&mut stdin, &image);
        let _ = stdin.flush();
    });
    let clipboard = clipboard::ClipboardService::start();
    let mut reader = BufReader::new(child.stdout.take().ok_or("no stdout")?);
    while let Ok(Some(message)) = ipc::read_message(&mut reader) {
        match message {
            ipc::Message::CopyImage(img) => clipboard.copy_image(img),
            ipc::Message::CopyText(text) => clipboard.copy_text(text),
            ipc::Message::Closed(_) => break,
            _ => {}
        }
    }
    let _ = writer.join();
    let _ = child.wait();
    // Give the clipboard thread a moment to finish writing before exiting.
    std::thread::sleep(std::time::Duration::from_millis(300));
    Ok(())
}
