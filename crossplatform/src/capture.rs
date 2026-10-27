//! Screen and window capture via xcap. Each capture is a single still image held in memory.

use image::RgbaImage;
use serde::{Deserialize, Serialize};

/// A window the picker can offer, with its rectangle in the monitor screenshot's pixels.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WindowInfo {
    pub id: u32,
    pub label: String,
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

pub struct MonitorShot {
    pub monitor: xcap::Monitor,
    pub image: RgbaImage,
}

impl MonitorShot {
    /// Monitor geometry in logical points: (x, y, width, height).
    pub fn logical_frame(&self) -> (f32, f32, f32, f32) {
        let scale = self.monitor.scale_factor().unwrap_or(1.0).max(0.5);
        let x = self.monitor.x().unwrap_or(0) as f32 / scale;
        let y = self.monitor.y().unwrap_or(0) as f32 / scale;
        let w = self.monitor.width().unwrap_or(1280) as f32 / scale;
        let h = self.monitor.height().unwrap_or(720) as f32 / scale;
        (x, y, w, h)
    }
}

fn cursor_position() -> Option<(i32, i32)> {
    match mouse_position::mouse_position::Mouse::get_mouse_position() {
        mouse_position::mouse_position::Mouse::Position { x, y } => Some((x, y)),
        mouse_position::mouse_position::Mouse::Error => None,
    }
}

/// The monitor under the mouse pointer (falls back to the primary monitor).
pub fn monitor_under_cursor() -> Result<xcap::Monitor, String> {
    if let Some((x, y)) = cursor_position() {
        if let Ok(monitor) = xcap::Monitor::from_point(x, y) {
            return Ok(monitor);
        }
    }
    let monitors = xcap::Monitor::all().map_err(|e| e.to_string())?;
    monitors
        .iter()
        .find(|m| m.is_primary().unwrap_or(false))
        .or(monitors.first())
        .cloned()
        .ok_or_else(|| "No display found.".to_string())
}

pub fn capture_monitor_under_cursor() -> Result<MonitorShot, String> {
    let monitor = monitor_under_cursor()?;
    let image = monitor.capture_image().map_err(|e| format!("Couldn't capture the screen: {e}"))?;
    Ok(MonitorShot { monitor, image })
}

/// Visible windows on `shot`'s monitor, front-most first, excluding SnapPaste itself.
pub fn windows_on(shot: &MonitorShot) -> Vec<WindowInfo> {
    let Ok(windows) = xcap::Window::all() else { return Vec::new() };
    let own_pid = std::process::id();
    let mon_x = shot.monitor.x().unwrap_or(0);
    let mon_y = shot.monitor.y().unwrap_or(0);
    let mon_w = shot.monitor.width().unwrap_or(1).max(1);
    // xcap reports window rects in the same units as the monitor; map them onto screenshot pixels.
    let scale = shot.image.width() as f32 / mon_w as f32;
    let mut found: Vec<(i32, WindowInfo)> = windows
        .iter()
        .filter_map(|w| {
            if w.is_minimized().unwrap_or(true) || w.pid().ok()? == own_pid {
                return None;
            }
            let (ww, wh) = (w.width().ok()?, w.height().ok()?);
            if ww < 40 || wh < 24 {
                return None;
            }
            let title = w.title().unwrap_or_default();
            let app = w.app_name().unwrap_or_default();
            if title.is_empty() && app.is_empty() {
                return None;
            }
            let x = ((w.x().ok()? - mon_x) as f32 * scale) as i32;
            let y = ((w.y().ok()? - mon_y) as f32 * scale) as i32;
            let (pw, ph) = ((ww as f32 * scale) as u32, (wh as f32 * scale) as u32);
            let visible = x < shot.image.width() as i32 && y < shot.image.height() as i32 && x + pw as i32 > 0 && y + ph as i32 > 0;
            if !visible {
                return None;
            }
            let label = if title.is_empty() || title == app { app } else if app.is_empty() { title } else { format!("{app} — {title}") };
            Some((w.z().unwrap_or(0), WindowInfo { id: w.id().ok()?, label, x, y, w: pw, h: ph }))
        })
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, w)| w).collect()
}

/// Captures one window by itself; falls back to cutting it out of the frozen screenshot.
pub fn capture_window(info: &WindowInfo, shot: &MonitorShot) -> Option<RgbaImage> {
    let direct = xcap::Window::all()
        .ok()
        .and_then(|all| all.into_iter().find(|w| w.id().ok() == Some(info.id)))
        .and_then(|w| w.capture_image().ok())
        .filter(|img| img.width() > 0 && img.height() > 0 && !is_blank(img));
    direct.or_else(|| {
        let rect = crate::annotate::RectF { x: info.x as f32, y: info.y as f32, w: info.w as f32, h: info.h as f32 };
        crate::render::crop(&shot.image, rect)
    })
}

fn is_blank(image: &RgbaImage) -> bool {
    image.pixels().step_by(97).all(|p| p[3] == 0 || (p[0] == 0 && p[1] == 0 && p[2] == 0))
}
