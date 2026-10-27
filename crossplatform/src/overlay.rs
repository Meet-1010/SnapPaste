//! Full-screen picker shown over a frozen screenshot of one monitor. Reports the chosen region
//! or window on stdout and exits. Closing it any other way means "cancelled".

use crate::capture::WindowInfo;
use crate::ipc::Message;
use crate::ui_common::{self, ACCENT};
use egui::{Align2, Color32, FontId, Pos2, Rect, Sense, Stroke, StrokeKind, Vec2};
use std::io::BufRead;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Region,
    Window,
}

struct OverlayApp {
    mode: Mode,
    texture: egui::TextureHandle,
    image_size: Vec2,
    windows: Vec<WindowInfo>,
    start: Option<Pos2>,
    current: Option<Pos2>,
    done: bool,
}

/// `args`: mode, then the monitor's logical x y width height.
pub fn run(args: &[String]) -> Result<(), String> {
    let mode = match args.first().map(String::as_str) {
        Some("window") => Mode::Window,
        _ => Mode::Region,
    };
    let frame: Vec<f32> = args.iter().skip(1).filter_map(|a| a.parse().ok()).collect();
    let (x, y, w, h) = match frame[..] {
        [x, y, w, h] => (x, y, w, h),
        _ => (0.0, 0.0, 1280.0, 720.0),
    };

    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    let windows = if mode == Mode::Window {
        let mut line = String::new();
        input.read_line(&mut line).map_err(|e| e.to_string())?;
        serde_json::from_str(line.trim_start_matches("WINDOWS").trim()).unwrap_or_default()
    } else {
        Vec::new()
    };
    let image = crate::ipc::read_image(&mut input).map_err(|e| e.to_string())?;
    drop(input);

    let viewport = egui::ViewportBuilder::default()
        .with_title("SnapPaste")
        .with_decorations(false)
        .with_position([x, y])
        .with_inner_size([w, h])
        .with_fullscreen(true)
        .with_always_on_top()
        .with_taskbar(false)
        .with_resizable(false)
        .with_active(true);
    ui_common::run_app("SnapPaste Picker", viewport, move |ctx| OverlayApp::new(ctx, mode, &image, windows))
}

impl OverlayApp {
    fn new(ctx: &egui::Context, mode: Mode, image: &image::RgbaImage, windows: Vec<WindowInfo>) -> Self {
        OverlayApp {
            mode,
            texture: ui_common::texture(ctx, "frozen-screen", image),
            image_size: Vec2::new(image.width() as f32, image.height() as f32),
            windows,
            start: None,
            current: None,
            done: false,
        }
    }

    fn finish(&mut self, ctx: &egui::Context, message: Message) {
        if self.done {
            return;
        }
        self.done = true;
        ui_common::send(&message);
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    fn label(painter: &egui::Painter, bounds: Rect, anchor: Pos2, text: &str) {
        let font = FontId::proportional(13.0);
        let galley = painter.layout_no_wrap(text.to_string(), font, Color32::WHITE);
        let size = galley.size() + Vec2::new(14.0, 8.0);
        let mut min = anchor;
        min.x = min.x.clamp(bounds.left() + 4.0, (bounds.right() - size.x - 4.0).max(bounds.left()));
        min.y = min.y.clamp(bounds.top() + 4.0, (bounds.bottom() - size.y - 4.0).max(bounds.top()));
        let rect = Rect::from_min_size(min, size);
        painter.rect_filled(rect, 5.0, Color32::from_black_alpha(190));
        painter.galley(rect.min + Vec2::new(7.0, 4.0), galley, Color32::WHITE);
    }
}

impl eframe::App for OverlayApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let screen = ui.max_rect();
        let response = ui.allocate_rect(screen, Sense::click_and_drag());
        let painter = ui.painter_at(screen);
        let uv = Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0));
        painter.image(self.texture.id(), screen, uv, Color32::WHITE);

        // Image pixels per screen point.
        let scale = self.image_size.x / screen.width().max(1.0);
        let to_image = |p: Pos2| ((p - screen.min) * scale).to_pos2();
        let to_screen = |x: f32, y: f32| screen.min + Vec2::new(x, y) / scale;
        let pointer = ctx.input(|i| i.pointer.hover_pos());

        let (escape, enter, right_click) = ctx.input(|i| {
            (i.key_pressed(egui::Key::Escape), i.key_pressed(egui::Key::Enter), i.pointer.secondary_clicked())
        });
        if escape || right_click {
            self.finish(&ctx, Message::Cancel);
            return;
        }

        match self.mode {
            Mode::Region => {
                let (pressed, down, released, shift) = ctx.input(|i| {
                    (i.pointer.primary_pressed(), i.pointer.primary_down(), i.pointer.primary_released(), i.modifiers.shift)
                });
                if pressed && response.hovered() {
                    self.start = pointer;
                    self.current = pointer;
                }
                if down && self.start.is_some() {
                    if let (Some(start), Some(mut p)) = (self.start, pointer) {
                        p = screen.clamp(p);
                        if shift {
                            let side = (p.x - start.x).abs().max((p.y - start.y).abs());
                            p = screen.clamp(Pos2::new(start.x + side.copysign(p.x - start.x), start.y + side.copysign(p.y - start.y)));
                        }
                        self.current = Some(p);
                    }
                }
                let selection = match (self.start, self.current) {
                    (Some(a), Some(b)) => Some(Rect::from_two_pos(a, b)),
                    _ => None,
                };
                if released {
                    if let Some(sel) = selection {
                        let (a, b) = (to_image(sel.min), to_image(sel.max));
                        let (x, y) = (a.x.floor().max(0.0), a.y.floor().max(0.0));
                        let (w, h) = ((b.x.ceil().min(self.image_size.x) - x), (b.y.ceil().min(self.image_size.y) - y));
                        if w >= 3.0 && h >= 3.0 {
                            self.finish(&ctx, Message::Region { x: x as u32, y: y as u32, w: w as u32, h: h as u32 });
                            return;
                        }
                    }
                    self.start = None;
                    self.current = None;
                }
                if enter && selection.is_none() {
                    let (w, h) = (self.image_size.x as u32, self.image_size.y as u32);
                    self.finish(&ctx, Message::Region { x: 0, y: 0, w, h });
                    return;
                }

                let dim = Color32::from_black_alpha(80);
                match selection {
                    Some(sel) if sel.width() > 0.0 && sel.height() > 0.0 => {
                        painter.rect_filled(Rect::from_min_max(screen.min, Pos2::new(screen.max.x, sel.min.y)), 0.0, dim);
                        painter.rect_filled(Rect::from_min_max(Pos2::new(screen.min.x, sel.max.y), screen.max), 0.0, dim);
                        painter.rect_filled(Rect::from_min_max(Pos2::new(screen.min.x, sel.min.y), Pos2::new(sel.min.x, sel.max.y)), 0.0, dim);
                        painter.rect_filled(Rect::from_min_max(Pos2::new(sel.max.x, sel.min.y), Pos2::new(screen.max.x, sel.max.y)), 0.0, dim);
                        painter.rect_stroke(sel, 0.0, Stroke::new(1.0, Color32::WHITE), StrokeKind::Outside);
                        let (w, h) = ((sel.width() * scale).round(), (sel.height() * scale).round());
                        Self::label(&painter, screen, sel.right_bottom() + Vec2::new(-80.0, 8.0), &format!("{w} × {h}"));
                    }
                    _ => {
                        painter.rect_filled(screen, 0.0, dim);
                        if let Some(p) = pointer {
                            let guide = Stroke::new(1.0, Color32::from_white_alpha(90));
                            painter.line_segment([Pos2::new(screen.left(), p.y), Pos2::new(screen.right(), p.y)], guide);
                            painter.line_segment([Pos2::new(p.x, screen.top()), Pos2::new(p.x, screen.bottom())], guide);
                            Self::label(&painter, screen, p + Vec2::new(16.0, 18.0), "Drag to capture · Enter: full screen · Esc: cancel");
                        }
                    }
                }
            }
            Mode::Window => {
                let hovered = pointer.and_then(|p| {
                    let ip = to_image(p);
                    self.windows.iter().position(|w| {
                        ip.x >= w.x as f32 && ip.y >= w.y as f32 && ip.x <= (w.x + w.w as i32) as f32 && ip.y <= (w.y + w.h as i32) as f32
                    })
                });
                painter.rect_filled(screen, 0.0, Color32::from_black_alpha(40));
                if let Some(index) = hovered {
                    let w = &self.windows[index];
                    let rect = Rect::from_min_max(to_screen(w.x as f32, w.y as f32), to_screen((w.x + w.w as i32) as f32, (w.y + w.h as i32) as f32));
                    painter.rect_filled(rect, 6.0, ACCENT.gamma_multiply(0.22));
                    painter.rect_stroke(rect, 6.0, Stroke::new(2.0, ACCENT), StrokeKind::Inside);
                    Self::label(&painter, screen, rect.min + Vec2::new(8.0, 8.0), &format!("{}  {} × {}", w.label, w.w, w.h));
                    if response.clicked() || enter {
                        self.finish(&ctx, Message::Window(index));
                        return;
                    }
                } else {
                    let text = if self.windows.is_empty() { "No windows to capture · Esc: cancel" } else { "Click a window to capture it · Esc: cancel" };
                    painter.text(screen.center_top() + Vec2::new(0.0, 48.0), Align2::CENTER_TOP, text, FontId::proportional(15.0), Color32::WHITE);
                }
            }
        }
        ctx.set_cursor_icon(egui::CursorIcon::Crosshair);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui_kittest::Harness;

    fn harness(mode: Mode, windows: Vec<WindowInfo>) -> Harness<'static, OverlayApp> {
        ui_common::SENT.with(|s| s.borrow_mut().clear());
        let image = image::RgbaImage::from_pixel(800, 600, image::Rgba([40, 90, 160, 255]));
        let mut h = Harness::builder().with_size([800.0, 600.0]).with_pixels_per_point(1.0).build_eframe(move |cc| {
            ui_common::install_fonts(&cc.egui_ctx);
            OverlayApp::new(&cc.egui_ctx, mode, &image, windows)
        });
        h.run_steps(2);
        h
    }

    fn sent() -> Vec<Message> {
        ui_common::SENT.with(|s| std::mem::take(&mut *s.borrow_mut()))
    }

    fn drag(h: &mut Harness<'static, OverlayApp>, a: Pos2, b: Pos2) {
        h.drag_at(a);
        h.run_steps(1);
        h.hover_at(a + (b - a) / 2.0);
        h.run_steps(1);
        h.hover_at(b);
        h.run_steps(1);
        h.drop_at(b);
        h.run_steps(2);
    }

    #[test]
    fn region_selection_reports_image_pixels() {
        let mut h = harness(Mode::Region, vec![]);
        drag(&mut h, Pos2::new(100.0, 100.0), Pos2::new(300.0, 250.0));
        assert_eq!(sent(), vec![Message::Region { x: 100, y: 100, w: 200, h: 150 }]);
    }

    #[test]
    fn tiny_selection_is_ignored_and_escape_cancels() {
        let mut h = harness(Mode::Region, vec![]);
        drag(&mut h, Pos2::new(100.0, 100.0), Pos2::new(101.0, 101.0));
        assert!(sent().is_empty());
        h.key_press(egui::Key::Escape);
        h.run_steps(2);
        assert_eq!(sent(), vec![Message::Cancel]);
    }

    #[test]
    fn clicking_a_highlighted_window_picks_it() {
        let windows = vec![
            WindowInfo { id: 7, label: "Front".into(), x: 50, y: 50, w: 200, h: 100 },
            WindowInfo { id: 8, label: "Back".into(), x: 0, y: 0, w: 800, h: 600 },
        ];
        let mut h = harness(Mode::Window, windows);
        let p = Pos2::new(400.0, 400.0);
        h.hover_at(p);
        h.run_steps(1);
        h.drag_at(p);
        h.run_steps(1);
        h.drop_at(p);
        h.run_steps(2);
        assert_eq!(sent(), vec![Message::Window(1)]);
    }
}
