//! Helpers shared by the egui windows (picker, editor, text window, toast).

use crate::annotate::Rgba;
use crate::ipc::{self, Message};
use egui::{Color32, FontFamily, FontId};
use image::RgbaImage;
use std::io::Write;
use std::sync::Arc;

pub const ACCENT: Color32 = Color32::from_rgb(0x0A, 0x84, 0xFF);

pub static ICON_PNG: &[u8] = include_bytes!("../assets/icon-256.png");

pub fn install_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert("annotation".into(), Arc::new(egui::FontData::from_static(crate::font::FONT_BYTES)));
    fonts.families.insert(FontFamily::Name("annotation".into()), vec!["annotation".into()]);
    // DejaVu covers symbols the default UI font lacks (arrows, ✔, ⚠, ×), so it serves as fallback.
    for family in [FontFamily::Proportional, FontFamily::Monospace] {
        fonts.families.entry(family).or_default().push("annotation".into());
    }
    ctx.set_fonts(fonts);
}

pub fn annotation_font(size: f32) -> FontId {
    FontId::new(size.max(1.0), FontFamily::Name("annotation".into()))
}

pub fn color32(c: Rgba) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r, c.g, c.b, c.a)
}

pub fn icon_rgba() -> (Vec<u8>, u32, u32) {
    let img = image::load_from_memory(ICON_PNG).expect("bundled icon").to_rgba8();
    let (w, h) = img.dimensions();
    (img.into_raw(), w, h)
}

pub fn icon_data() -> egui::IconData {
    let (rgba, width, height) = icon_rgba();
    egui::IconData { rgba, width, height }
}

/// Uploads an image as a texture, downscaling only for display if it exceeds the GPU limit.
pub fn texture(ctx: &egui::Context, name: &str, image: &RgbaImage) -> egui::TextureHandle {
    ctx.load_texture(name, color_image(ctx, image), egui::TextureOptions::LINEAR)
}

pub fn color_image(ctx: &egui::Context, image: &RgbaImage) -> egui::ColorImage {
    let max_side = ctx.input(|i| i.max_texture_side).max(1024) as u32;
    let (w, h) = image.dimensions();
    if w <= max_side && h <= max_side {
        return egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], image.as_raw());
    }
    let scale = max_side as f32 / w.max(h) as f32;
    let (sw, sh) = (((w as f32 * scale) as u32).max(1), ((h as f32 * scale) as u32).max(1));
    let small = image::imageops::resize(image, sw, sh, image::imageops::FilterType::Triangle);
    egui::ColorImage::from_rgba_unmultiplied([sw as usize, sh as usize], small.as_raw())
}

#[cfg(test)]
thread_local! {
    pub static SENT: std::cell::RefCell<Vec<Message>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Sends a message to the background process (our stdout is its pipe).
pub fn send(message: &Message) {
    #[cfg(test)]
    {
        let copy = match message {
            Message::CopyImage(i) => Message::CopyImage(i.clone()),
            Message::CopyText(t) => Message::CopyText(t.clone()),
            Message::Closed(i) => Message::Closed(i.clone()),
            Message::Region { x, y, w, h } => Message::Region { x: *x, y: *y, w: *w, h: *h },
            Message::Window(i) => Message::Window(*i),
            Message::Cancel => Message::Cancel,
        };
        SENT.with(|s| s.borrow_mut().push(copy));
        return;
    }
    #[allow(unreachable_code)]
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = ipc::write_message(&mut lock, message);
    let _ = lock.flush();
}

pub fn read_stdin_image() -> Result<RgbaImage, String> {
    let stdin = std::io::stdin();
    let mut lock = stdin.lock();
    ipc::read_image(&mut lock).map_err(|e| format!("couldn't read image: {e}"))
}

pub fn native_options(viewport: egui::ViewportBuilder) -> eframe::NativeOptions {
    eframe::NativeOptions { viewport: viewport.with_icon(icon_data()), ..Default::default() }
}

pub fn run_app<A: eframe::App + 'static>(title: &str, viewport: egui::ViewportBuilder, app: impl FnOnce(&egui::Context) -> A + 'static) -> Result<(), String> {
    eframe::run_native(
        title,
        native_options(viewport),
        Box::new(move |cc| {
            install_fonts(&cc.egui_ctx);
            Ok(Box::new(app(&cc.egui_ctx)))
        }),
    )
    .map_err(|e| e.to_string())
}
