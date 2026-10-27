//! Operating-system glue: event loops, single instance, CLI commands, launch at login, opening links.

use crate::daemon::{Cmd, Event};
use crate::settings::Settings;
use std::sync::mpsc::Sender;

fn auto_launch() -> Result<auto_launch::AutoLaunch, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    auto_launch::AutoLaunchBuilder::new()
        .set_app_name("SnapPaste")
        .set_app_path(&exe.to_string_lossy())
        .build()
        .map_err(|e| e.to_string())
}

pub fn launch_at_login_enabled() -> bool {
    auto_launch().and_then(|a| a.is_enabled().map_err(|e| e.to_string())).unwrap_or(false)
}

pub fn toggle_launch_at_login() -> Result<(), String> {
    let launcher = auto_launch()?;
    if launcher.is_enabled().map_err(|e| e.to_string())? {
        launcher.disable().map_err(|e| e.to_string())
    } else {
        launcher.enable().map_err(|e| e.to_string())
    }
}

/// Opens a file or URL with the system's default handler.
pub fn open_path(target: &str) {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let wide: Vec<u16> = std::ffi::OsStr::new(target).encode_wide().chain(Some(0)).collect();
        let verb: Vec<u16> = "open".encode_utf16().chain(Some(0)).collect();
        unsafe {
            windows_sys::Win32::UI::Shell::ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                wide.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
            );
        }
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open").arg(target).spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open").arg(target).spawn();
    }
}

/// Lets the window we're about to open come to the front (Windows restricts focus stealing).
pub fn allow_child_focus() {
    #[cfg(windows)]
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow(windows_sys::Win32::UI::WindowsAndMessaging::ASFW_ANY);
    }
}

// MARK: - Single instance and CLI commands

#[cfg(unix)]
fn socket_path() -> std::path::PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(std::path::PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
    dir.join(format!("snappaste-{user}.sock"))
}

#[cfg(unix)]
pub fn ensure_single_instance() -> Result<(), String> {
    if std::os::unix::net::UnixStream::connect(socket_path()).is_ok() {
        return Err("SnapPaste is already running (look for its icon in the system tray).".into());
    }
    let _ = std::fs::remove_file(socket_path());
    Ok(())
}

#[cfg(windows)]
pub fn ensure_single_instance() -> Result<(), String> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    let name: Vec<u16> = "Local\\SnapPaste.SingleInstance".encode_utf16().chain(Some(0)).collect();
    // The handle is intentionally never closed: it marks this process as the running instance.
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    if handle.is_null() || unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return Err("SnapPaste is already running (look for its icon in the system tray).".into());
    }
    Ok(())
}

/// Accepts commands like `snappaste region` from the command line (useful for desktop shortcuts
/// on Wayland, where apps can't register global hotkeys themselves).
#[cfg(unix)]
pub fn listen_for_cli(tx: Sender<Event>) {
    use std::io::BufRead;
    let Ok(listener) = std::os::unix::net::UnixListener::bind(socket_path()) else { return };
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut line = String::new();
            if std::io::BufReader::new(stream).read_line(&mut line).is_ok() {
                if let Some(cmd) = Cmd::from_name(line.trim()) {
                    let _ = tx.send(Event::Command(cmd));
                }
            }
        }
    });
}

#[cfg(windows)]
pub fn listen_for_cli(_tx: Sender<Event>) {}

#[cfg(unix)]
pub fn send_cli(command: &str) -> Result<(), String> {
    use std::io::Write;
    let mut stream = std::os::unix::net::UnixStream::connect(socket_path())
        .map_err(|_| "SnapPaste isn't running. Start it first, then run this command again.".to_string())?;
    writeln!(stream, "{command}").map_err(|e| e.to_string())
}

#[cfg(windows)]
pub fn send_cli(_command: &str) -> Result<(), String> {
    Err("On Windows, use the keyboard shortcuts or the tray icon.".into())
}

// MARK: - Event loops

#[cfg(windows)]
pub fn run_event_loop(settings: &Settings, tx: Sender<Event>) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{DispatchMessageW, GetMessageW, TranslateMessage, MSG};
    let (_hotkeys, errors) = crate::tray::register_hotkeys(settings, tx.clone());
    let _tray = crate::tray::build_tray(settings, &errors, tx)?;
    unsafe {
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn run_event_loop(settings: &Settings, tx: Sender<Event>) -> Result<(), String> {
    gtk::init().map_err(|e| format!("couldn't start GTK: {e}"))?;
    let (_hotkeys, errors) = crate::tray::register_hotkeys(settings, tx.clone());
    let _tray = crate::tray::build_tray(settings, &errors, tx)?;
    gtk::main();
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn run_event_loop(_settings: &Settings, _tx: Sender<Event>) -> Result<(), String> {
    Err("Use the native macOS app.".into())
}
