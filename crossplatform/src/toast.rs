//! A small click-through "Copied" bubble that never takes keyboard focus and closes itself.

use crate::ui_common::{self, ACCENT};
use egui::{Color32, Vec2};
use std::time::{Duration, Instant};

struct Toast {
    title: String,
    detail: String,
    shown: Instant,
}

/// `args`: title, detail, logical x, logical y.
pub fn run(args: &[String]) -> Result<(), String> {
    let title = args.first().cloned().unwrap_or_else(|| "Copied to clipboard".into());
    let detail = args.get(1).cloned().unwrap_or_default();
    let x: f32 = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(100.0);
    let y: f32 = args.get(3).and_then(|v| v.parse().ok()).unwrap_or(60.0);
    let viewport = egui::ViewportBuilder::default()
        .with_title("SnapPaste")
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top()
        .with_taskbar(false)
        .with_active(false)
        .with_mouse_passthrough(true)
        .with_resizable(false)
        .with_position([x, y])
        .with_inner_size([320.0, 62.0]);
    ui_common::run_app("SnapPaste Toast", viewport, move |_| Toast { title, detail, shown: Instant::now() })
}

impl eframe::App for Toast {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let elapsed = self.shown.elapsed();
        if elapsed > Duration::from_millis(1500) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }
        ctx.request_repaint_after(Duration::from_millis(100));
        let rect = ui.max_rect().shrink(2.0);
        let painter = ui.painter_at(ui.max_rect());
        let dark = ctx.global_style().visuals.dark_mode;
        let (bg, fg, sub) = if dark {
            (Color32::from_rgba_unmultiplied(40, 40, 44, 240), Color32::WHITE, Color32::from_gray(170))
        } else {
            (Color32::from_rgba_unmultiplied(250, 250, 252, 245), Color32::from_gray(20), Color32::from_gray(100))
        };
        painter.rect_filled(rect, 12.0, bg);
        let center = rect.left_center() + Vec2::new(26.0, 0.0);
        painter.circle_filled(center, 13.0, ACCENT);
        painter.text(center, egui::Align2::CENTER_CENTER, "✔", egui::FontId::proportional(14.0), Color32::WHITE);
        painter.text(rect.left_center() + Vec2::new(50.0, -9.0), egui::Align2::LEFT_CENTER, &self.title, egui::FontId::proportional(14.5), fg);
        painter.text(rect.left_center() + Vec2::new(50.0, 11.0), egui::Align2::LEFT_CENTER, &self.detail, egui::FontId::proportional(12.0), sub);
    }
}
