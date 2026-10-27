//! The annotation editor. Receives the capture on stdin, sends copies back to the background
//! process (which owns the clipboard), and reports its final state when it closes.

use crate::annotate::{arrow_geometry, Annotation, Pt, RectF, Rgba, Shape, PALETTE};
use crate::history::{EditorState, History};
use crate::ipc::Message;
use crate::ui_common::{self, color32, ACCENT};
use egui::{Align, Align2, Color32, Key, Layout, Pos2, Rect, Sense, Stroke, StrokeKind, Vec2};
use image::RgbaImage;
use std::collections::HashSet;
use std::sync::{mpsc, Arc};
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tool {
    Select,
    Crop,
    Pen,
    Highlighter,
    Rect,
    Ellipse,
    Line,
    Arrow,
    Text,
    Eraser,
}

impl Tool {
    const ALL: [Tool; 10] = [
        Tool::Select, Tool::Crop, Tool::Pen, Tool::Highlighter, Tool::Rect,
        Tool::Ellipse, Tool::Line, Tool::Arrow, Tool::Text, Tool::Eraser,
    ];

    fn label(self) -> &'static str {
        match self {
            Tool::Select => "Select",
            Tool::Crop => "Crop",
            Tool::Pen => "Pen",
            Tool::Highlighter => "Highlight",
            Tool::Rect => "Rectangle",
            Tool::Ellipse => "Ellipse",
            Tool::Line => "Line",
            Tool::Arrow => "Arrow",
            Tool::Text => "Text",
            Tool::Eraser => "Eraser",
        }
    }

    fn key(self) -> Key {
        match self {
            Tool::Select => Key::V,
            Tool::Crop => Key::C,
            Tool::Pen => Key::P,
            Tool::Highlighter => Key::H,
            Tool::Rect => Key::R,
            Tool::Ellipse => Key::O,
            Tool::Line => Key::L,
            Tool::Arrow => Key::A,
            Tool::Text => Key::T,
            Tool::Eraser => Key::E,
        }
    }

    fn draws(self) -> bool {
        !matches!(self, Tool::Select | Tool::Crop | Tool::Eraser)
    }
}

enum Drag {
    None,
    Drawing { annotation: Annotation, start: Pt },
    Moving { original: Annotation, start: Pt, current: Annotation },
    Cropping { start: Pt },
    MovingCrop { original: RectF, start: Pt },
    Erasing(HashSet<u64>),
    Panning { start: Pos2, pan: Vec2 },
}

struct TextEditing {
    origin: Pt,
    text: String,
    size: f32,
    color: Rgba,
    existing: Option<u64>,
    focused_once: bool,
}

enum Ocr {
    Idle,
    Running(mpsc::Receiver<Result<String, String>>),
    Done(String),
    Failed(String),
}

struct ResizeDialog {
    width: u32,
    height: u32,
    keep_aspect: bool,
}

pub struct EditorApp {
    state: EditorState,
    original: EditorState,
    history: History<EditorState>,
    texture: Option<egui::TextureHandle>,
    texture_hidden: Option<HashSet<u64>>,
    dirty: bool,
    tool: Tool,
    last_drawing_tool: Tool,
    color: Rgba,
    width: f32,
    highlight_color: Rgba,
    highlight_width: f32,
    highlight_opacity: f32,
    text_size: f32,
    selected: Option<u64>,
    drag: Drag,
    hidden: HashSet<u64>,
    crop: Option<RectF>,
    zoom: Option<f32>,
    pan: Vec2,
    text: Option<TextEditing>,
    resize: Option<ResizeDialog>,
    confirm_reset: bool,
    ocr: Ocr,
    next_id: u64,
    status: Option<(String, f64)>,
    closing: bool,
    last_view: Option<View>,
}

/// `args`: color hex, line width, text size.
pub fn run(args: &[String]) -> Result<(), String> {
    let image = ui_common::read_stdin_image()?;
    run_with_image(image, args)
}

pub fn run_with_image(image: RgbaImage, args: &[String]) -> Result<(), String> {
    let color = args.first().and_then(|c| Rgba::parse_hex(c)).unwrap_or(PALETTE[0].1);
    let width: f32 = args.get(1).and_then(|v| v.parse().ok()).unwrap_or(4.0);
    let text_size: f32 = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(28.0);
    let (w, h) = image.dimensions();
    let viewport = egui::ViewportBuilder::default()
        .with_title(format!("SnapPaste Editor — {w} × {h} px"))
        .with_inner_size([(w as f32 * 0.8 + 40.0).clamp(860.0, 1400.0), (h as f32 * 0.8 + 170.0).clamp(540.0, 900.0)])
        .with_min_inner_size([760.0, 440.0])
        .with_active(true);
    ui_common::run_app("SnapPaste Editor", viewport, move |_| EditorApp::new(image, color, width, text_size))
}

impl EditorApp {
    fn new(image: RgbaImage, color: Rgba, width: f32, text_size: f32) -> Self {
        let state = EditorState { image: Arc::new(image), annotations: Vec::new() };
        EditorApp {
            original: state.clone(),
            state,
            history: History::new(100),
            texture: None,
            texture_hidden: None,
            dirty: true,
            tool: Tool::Arrow,
            last_drawing_tool: Tool::Arrow,
            color,
            width,
            highlight_color: PALETTE[2].1,
            highlight_width: (width * 4.0).max(16.0),
            highlight_opacity: 0.35,
            text_size,
            selected: None,
            drag: Drag::None,
            hidden: HashSet::new(),
            crop: None,
            zoom: None,
            pan: Vec2::ZERO,
            text: None,
            resize: None,
            confirm_reset: false,
            ocr: Ocr::Idle,
            next_id: 1,
            status: None,
            closing: false,
            last_view: None,
        }
    }
}

// MARK: - Document operations

impl EditorApp {
    fn perform(&mut self, name: &str, key: Option<&str>, change: impl FnOnce(&mut EditorState)) -> bool {
        let mut next = self.state.clone();
        change(&mut next);
        if next == self.state {
            return false;
        }
        let previous = std::mem::replace(&mut self.state, next);
        self.history.record(previous, name, key);
        self.dirty = true;
        true
    }

    fn annotation(&self, id: u64) -> Option<&Annotation> {
        self.state.annotations.iter().find(|a| a.id == id)
    }

    fn add(&mut self, mut annotation: Annotation, name: &str) {
        annotation.id = self.next_id;
        self.next_id += 1;
        let id = annotation.id;
        self.perform(name, None, |s| s.annotations.push(annotation));
        if self.annotation(id).is_some_and(|a| a.is_text()) {
            self.selected = Some(id);
        }
    }

    fn update(&mut self, annotation: Annotation, name: &str, key: Option<&str>) {
        self.perform(name, key, |s| {
            if let Some(slot) = s.annotations.iter_mut().find(|a| a.id == annotation.id) {
                *slot = annotation;
            }
        });
    }

    fn remove(&mut self, ids: &HashSet<u64>, name: &str) {
        if ids.is_empty() {
            return;
        }
        self.perform(name, None, |s| s.annotations.retain(|a| !ids.contains(&a.id)));
        if self.selected.is_some_and(|id| ids.contains(&id)) {
            self.selected = None;
        }
    }

    fn undo(&mut self) {
        self.commit_text();
        if let Some(previous) = self.history.undo(self.state.clone()) {
            self.state = previous;
            self.after_history_change();
        }
    }

    fn redo(&mut self) {
        self.commit_text();
        if let Some(next) = self.history.redo(self.state.clone()) {
            self.state = next;
            self.after_history_change();
        }
    }

    fn after_history_change(&mut self) {
        self.dirty = true;
        self.drag = Drag::None;
        self.hidden.clear();
        if self.selected.is_some_and(|id| self.annotation(id).is_none()) {
            self.selected = None;
        }
    }

    fn image_size(&self) -> (u32, u32) {
        self.state.image.dimensions()
    }

    fn apply_crop(&mut self) {
        let Some(rect) = self.crop else { return };
        let (w, h) = self.image_size();
        let r = rect.snapped(w, h);
        if r.w < 1.0 || r.h < 1.0 || (r.x == 0.0 && r.y == 0.0 && r.w as u32 == w && r.h as u32 == h) {
            return;
        }
        let Some(cropped) = crate::render::crop(&self.state.image, r) else { return };
        let bounds = RectF { x: 0.0, y: 0.0, w: r.w, h: r.h };
        self.perform("Crop", None, |s| {
            s.image = Arc::new(cropped);
            s.annotations = s.annotations.iter().map(|a| a.translated(-r.x, -r.y)).filter(|a| a.bounds().intersects(&bounds)).collect();
        });
        self.crop = None;
        self.zoom = None;
        self.pan = Vec2::ZERO;
        self.tool = self.last_drawing_tool;
    }

    fn apply_resize(&mut self, w: u32, h: u32) -> Result<(), String> {
        crate::annotate::validate_size(w, h)?;
        let (ow, oh) = self.image_size();
        if (w, h) == (ow, oh) {
            return Ok(());
        }
        let resized = crate::render::resize(&self.state.image, w, h).ok_or("Couldn't resize the image.")?;
        let (sx, sy) = (w as f32 / ow as f32, h as f32 / oh as f32);
        self.perform("Resize", None, |s| {
            s.image = Arc::new(resized);
            s.annotations = s.annotations.iter().map(|a| a.scaled(sx, sy)).collect();
        });
        self.zoom = None;
        self.pan = Vec2::ZERO;
        Ok(())
    }

    fn reset(&mut self) {
        self.commit_text();
        let original = self.original.clone();
        self.perform("Reset", None, |s| *s = original);
        self.selected = None;
        self.crop = None;
        self.zoom = None;
    }

    fn has_edits(&self) -> bool {
        self.state != self.original
    }

    fn rendered(&self) -> RgbaImage {
        crate::render::render(&self.state.image, &self.state.annotations)
    }

    fn copy(&mut self, ctx: &egui::Context) {
        self.commit_text();
        ui_common::send(&Message::CopyImage(self.rendered()));
        let (w, h) = self.image_size();
        self.status = Some((format!("Copied {w} × {h} px to the clipboard"), ctx.input(|i| i.time)));
    }

    fn close(&mut self, ctx: &egui::Context, copy_first: bool) {
        self.commit_text();
        if copy_first {
            ui_common::send(&Message::CopyImage(self.rendered()));
            ui_common::send(&Message::Closed(None));
        } else {
            self.send_closed();
        }
        self.closing = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    /// Keeps edits with the in-memory capture (so "Edit Last Capture" resumes them) without
    /// touching the clipboard.
    fn send_closed(&mut self) {
        let image = if self.has_edits() { Some(self.rendered()) } else { None };
        ui_common::send(&Message::Closed(image));
    }

    fn start_ocr(&mut self) {
        self.commit_text();
        let image = (*self.state.image).clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(crate::ocr::recognize(&image));
        });
        self.ocr = Ocr::Running(rx);
    }

    // MARK: Style changes act on the selection when there is one.

    fn selected_annotation(&self) -> Option<Annotation> {
        self.selected.and_then(|id| self.annotation(id).cloned())
    }

    fn edits_highlighter(&self) -> bool {
        match self.selected_annotation() {
            Some(a) => matches!(a.shape, Shape::Highlighter(_)),
            None => self.tool == Tool::Highlighter,
        }
    }

    fn edits_text(&self) -> bool {
        match self.selected_annotation() {
            Some(a) => a.is_text(),
            None => self.tool == Tool::Text || self.text.is_some(),
        }
    }

    fn set_color(&mut self, color: Rgba) {
        if self.edits_highlighter() {
            self.highlight_color = color;
        } else {
            self.color = color;
        }
        if let Some(t) = self.text.as_mut() {
            t.color = color;
        }
        if let Some(mut a) = self.selected_annotation() {
            let alpha = if matches!(a.shape, Shape::Highlighter(_)) { a.color.a } else { 255 };
            a.color = color.with_alpha(alpha);
            self.update(a, "Change Color", None);
        }
    }

    fn adopt_style(&mut self, a: &Annotation) {
        match &a.shape {
            Shape::Highlighter(_) => {
                self.highlight_color = a.color.with_alpha(255);
                self.highlight_width = a.width;
                self.highlight_opacity = a.color.a as f32 / 255.0;
            }
            Shape::Text { size, .. } => {
                self.color = a.color;
                self.text_size = *size;
            }
            _ => {
                self.color = a.color;
                self.width = a.width;
            }
        }
    }

    fn select(&mut self, id: Option<u64>) {
        self.selected = id;
        if let Some(a) = id.and_then(|id| self.annotation(id).cloned()) {
            self.adopt_style(&a);
        }
    }

    fn set_tool(&mut self, tool: Tool) {
        if tool == self.tool {
            return;
        }
        self.commit_text();
        if self.tool.draws() {
            self.last_drawing_tool = self.tool;
        }
        if self.tool == Tool::Crop {
            self.crop = None;
        }
        if !matches!(tool, Tool::Select | Tool::Text) {
            self.selected = None;
        }
        self.drag = Drag::None;
        self.tool = tool;
    }

    // MARK: Text

    fn begin_text(&mut self, origin: Pt, existing: Option<&Annotation>) {
        self.commit_text();
        match existing {
            Some(a) => {
                if let Shape::Text { origin, text, size } = &a.shape {
                    self.hidden.insert(a.id);
                    self.text = Some(TextEditing { origin: *origin, text: text.clone(), size: *size, color: a.color, existing: Some(a.id), focused_once: false });
                }
            }
            None => {
                self.text = Some(TextEditing { origin, text: String::new(), size: self.text_size, color: self.color, existing: None, focused_once: false });
            }
        }
    }

    fn commit_text(&mut self) {
        let Some(t) = self.text.take() else { return };
        if let Some(id) = t.existing {
            self.hidden.remove(&id);
        }
        let blank = t.text.trim().is_empty();
        let shape = Shape::Text { origin: t.origin, text: t.text, size: t.size };
        match t.existing.and_then(|id| self.annotation(id).cloned()) {
            Some(a) if blank => self.remove(&HashSet::from([a.id]), "Delete Text"),
            Some(mut a) => {
                a.shape = shape;
                a.color = t.color;
                self.update(a, "Edit Text", None);
            }
            None if !blank => self.add(Annotation { id: 0, shape, color: t.color, width: 0.0 }, "Add Text"),
            None => {}
        }
        self.dirty = true;
    }

    fn cancel_text(&mut self) {
        if let Some(t) = self.text.take() {
            if let Some(id) = t.existing {
                self.hidden.remove(&id);
            }
        }
    }
}

// MARK: - Coordinate mapping

#[derive(Clone, Copy)]
struct View {
    image_rect: Rect,
    zoom: f32,
}

impl View {
    fn to_image(&self, p: Pos2) -> Pt {
        Pt::new((p.x - self.image_rect.min.x) / self.zoom, (p.y - self.image_rect.min.y) / self.zoom)
    }

    fn to_screen(&self, p: Pt) -> Pos2 {
        Pos2::new(self.image_rect.min.x + p.x * self.zoom, self.image_rect.min.y + p.y * self.zoom)
    }

    fn rect_to_screen(&self, r: RectF) -> Rect {
        Rect::from_min_max(self.to_screen(Pt::new(r.x, r.y)), self.to_screen(Pt::new(r.max_x(), r.max_y())))
    }
}

/// Paints an annotation with egui shapes (used for the stroke in progress and items being moved;
/// committed annotations are shown from the same renderer that produces the copied image).
fn paint_annotation(painter: &egui::Painter, view: &View, a: &Annotation) {
    let color = color32(a.color);
    let stroke = Stroke::new((a.width * view.zoom).max(1.0), color);
    match &a.shape {
        Shape::Pen(points) | Shape::Highlighter(points) => {
            let pts: Vec<Pos2> = points.iter().map(|p| view.to_screen(*p)).collect();
            if pts.len() == 1 {
                painter.circle_filled(pts[0], stroke.width / 2.0, color);
            } else {
                painter.add(egui::Shape::line(pts, stroke));
            }
        }
        Shape::Rect(r) => {
            painter.rect_stroke(view.rect_to_screen(*r), 0.0, stroke, StrokeKind::Middle);
        }
        Shape::Ellipse(r) => {
            let rect = view.rect_to_screen(*r);
            painter.add(egui::Shape::ellipse_stroke(rect.center(), rect.size() / 2.0, stroke));
        }
        Shape::Line(s, e) => {
            painter.line_segment([view.to_screen(*s), view.to_screen(*e)], stroke);
        }
        Shape::Arrow(s, e) => {
            if let Some((shaft, tip, left, right)) = arrow_geometry(*s, *e, a.width) {
                painter.line_segment([view.to_screen(*s), view.to_screen(shaft)], stroke);
                painter.add(egui::Shape::convex_polygon(
                    vec![view.to_screen(tip), view.to_screen(left), view.to_screen(right)],
                    color,
                    Stroke::NONE,
                ));
            }
        }
        Shape::Text { origin, text, size } => {
            painter.text(view.to_screen(*origin), Align2::LEFT_TOP, text, ui_common::annotation_font(size * view.zoom), color);
        }
    }
}

fn shape_for(tool: Tool, a: Pt, b: Pt) -> Shape {
    match tool {
        Tool::Rect => Shape::Rect(RectF::from_points(a, b)),
        Tool::Ellipse => Shape::Ellipse(RectF::from_points(a, b)),
        Tool::Line => Shape::Line(a, b),
        Tool::Arrow => Shape::Arrow(a, b),
        Tool::Highlighter => Shape::Highlighter(vec![a]),
        _ => Shape::Pen(vec![a]),
    }
}

/// Shift: squares/circles, or lines snapped to 45°.
fn constrain(tool: Tool, start: Pt, p: Pt) -> Pt {
    match tool {
        Tool::Rect | Tool::Ellipse => {
            let side = (p.x - start.x).abs().max((p.y - start.y).abs());
            Pt::new(start.x + side.copysign(p.x - start.x), start.y + side.copysign(p.y - start.y))
        }
        _ => {
            let (dx, dy) = (p.x - start.x, p.y - start.y);
            let len = (dx * dx + dy * dy).sqrt();
            let step = std::f32::consts::FRAC_PI_4;
            let angle = (dy.atan2(dx) / step).round() * step;
            Pt::new(start.x + angle.cos() * len, start.y + angle.sin() * len)
        }
    }
}

// MARK: - UI

impl eframe::App for EditorApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if ctx.input(|i| i.viewport().close_requested()) && !self.closing {
            self.commit_text();
            self.send_closed();
            self.closing = true;
        }
        self.poll_ocr(&ctx);
        self.handle_shortcuts(&ctx);

        egui::Panel::top("toolbar").show(ui, |ui| self.toolbar(ui));
        egui::Panel::top("options").show(ui, |ui| self.options_bar(ui));
        egui::Panel::bottom("actions").show(ui, |ui| self.bottom_bar(ui));
        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(if ctx.global_style().visuals.dark_mode { Color32::from_gray(28) } else { Color32::from_gray(222) }))
            .show(ui, |ui| self.canvas(ui));

        self.dialogs(&ctx);
    }
}

impl EditorApp {
    fn poll_ocr(&mut self, ctx: &egui::Context) {
        if let Ocr::Running(rx) = &self.ocr {
            match rx.try_recv() {
                Ok(Ok(text)) => self.ocr = Ocr::Done(text),
                Ok(Err(e)) => self.ocr = Ocr::Failed(e),
                Err(mpsc::TryRecvError::Empty) => ctx.request_repaint_after(Duration::from_millis(120)),
                Err(mpsc::TryRecvError::Disconnected) => self.ocr = Ocr::Failed("Recognition stopped unexpectedly.".into()),
            }
        }
    }

    fn handle_shortcuts(&mut self, ctx: &egui::Context) {
        if ctx.egui_wants_keyboard_input() || self.text.is_some() || self.resize.is_some() {
            return;
        }
        let (copy_event, keys) = ctx.input(|i| {
            let copy = i.events.iter().any(|e| matches!(e, egui::Event::Copy));
            (copy, (i.modifiers, i.key_pressed(Key::Z), i.key_pressed(Key::Y), i.key_pressed(Key::Enter), i.key_pressed(Key::Escape),
                    i.key_pressed(Key::Delete) || i.key_pressed(Key::Backspace), i.key_pressed(Key::Num0), i.key_pressed(Key::Num1),
                    i.key_pressed(Key::Plus) || i.key_pressed(Key::Equals), i.key_pressed(Key::Minus)))
        });
        let (mods, z, y, enter, escape, delete, zero, one, plus, minus) = keys;
        if copy_event {
            self.copy(ctx);
            return;
        }
        if mods.command {
            if z && mods.shift || y {
                self.redo();
            } else if z {
                self.undo();
            } else if enter {
                self.close(ctx, true);
            } else if zero {
                self.zoom = None;
                self.pan = Vec2::ZERO;
            } else if one {
                self.zoom = Some(1.0 / ctx.pixels_per_point());
            } else if plus {
                self.zoom = Some(self.current_zoom(ctx) * 1.25);
            } else if minus {
                self.zoom = Some(self.current_zoom(ctx) / 1.25);
            }
            return;
        }
        if delete {
            if let Some(id) = self.selected {
                self.remove(&HashSet::from([id]), "Delete");
            }
        } else if enter {
            if self.tool == Tool::Crop {
                self.apply_crop();
            } else if let Some(a) = self.selected_annotation().filter(|a| a.is_text()) {
                self.begin_text(Pt::default(), Some(&a));
            }
        } else if escape {
            if !matches!(self.drag, Drag::None) {
                self.drag = Drag::None;
                self.hidden.clear();
            } else if self.crop.is_some() {
                self.crop = None;
            } else if self.selected.is_some() {
                self.selected = None;
            } else {
                self.close(ctx, false);
            }
        } else if mods.is_none() {
            let pressed = ctx.input(|i| Tool::ALL.into_iter().find(|t| i.key_pressed(t.key())));
            if let Some(tool) = pressed {
                self.set_tool(tool);
            }
        }
    }

    fn current_zoom(&self, ctx: &egui::Context) -> f32 {
        self.zoom.unwrap_or(1.0 / ctx.pixels_per_point())
    }

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            for tool in Tool::ALL {
                let text = egui::RichText::new(tool.label()).size(13.5);
                let response = ui.add(egui::Button::selectable(self.tool == tool, text));
                if response.on_hover_text(format!("{} ({:?})", tool.label(), tool.key())).clicked() {
                    self.set_tool(tool);
                }
            }
            ui.separator();
            let undo_tip = self.history.undo_name().map(|n| format!("Undo {n} (Ctrl+Z)")).unwrap_or_else(|| "Undo (Ctrl+Z)".into());
            if ui.add_enabled(self.history.can_undo(), egui::Button::new("↶ Undo")).on_hover_text(undo_tip).clicked() {
                self.undo();
            }
            if ui.add_enabled(self.history.can_redo(), egui::Button::new("↷ Redo")).on_hover_text("Redo (Ctrl+Shift+Z)").clicked() {
                self.redo();
            }
            ui.separator();
            if ui.button("Resize…").on_hover_text("Change the image size in pixels").clicked() {
                self.commit_text();
                let (w, h) = self.image_size();
                self.resize = Some(ResizeDialog { width: w, height: h, keep_aspect: true });
            }
            let running = matches!(self.ocr, Ocr::Running(_));
            if ui.add_enabled(!running, egui::Button::new("Extract Text")).on_hover_text("Recognize text on this computer").clicked() {
                self.start_ocr();
            }
            if ui.add_enabled(self.has_edits(), egui::Button::new("Reset…")).on_hover_text("Return to the original capture").clicked() {
                self.confirm_reset = true;
            }
        });
        ui.add_space(4.0);
    }

    fn swatches(&mut self, ui: &mut egui::Ui) {
        let current = if self.edits_highlighter() { self.highlight_color } else { self.color };
        for (name, color) in PALETTE {
            let (rect, response) = ui.allocate_exact_size(Vec2::splat(20.0), Sense::click());
            let painter = ui.painter();
            if current.same_rgb(color) {
                painter.circle_stroke(rect.center(), 9.5, Stroke::new(2.0, ACCENT));
            }
            painter.circle_filled(rect.center(), 7.0, color32(color));
            painter.circle_stroke(rect.center(), 7.0, Stroke::new(1.0, Color32::from_black_alpha(60)));
            if response.on_hover_text(name).clicked() {
                self.set_color(color);
            }
        }
    }

    fn options_bar(&mut self, ui: &mut egui::Ui) {
        ui.add_space(3.0);
        ui.horizontal(|ui| {
            match self.tool {
                Tool::Crop => {
                    match self.crop {
                        Some(r) => ui.label(format!("Crop: {} × {} px", r.w as u32, r.h as u32)),
                        None => ui.weak("Drag on the image to choose the area to keep"),
                    };
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui.add_enabled(self.crop.is_some(), egui::Button::new("Apply Crop")).on_hover_text("Enter").clicked() {
                            self.apply_crop();
                        }
                        if ui.add_enabled(self.crop.is_some(), egui::Button::new("Cancel")).on_hover_text("Esc").clicked() {
                            self.crop = None;
                        }
                    });
                }
                Tool::Eraser => {
                    ui.weak("Click or drag across annotations to remove them. The screenshot itself is never erased.");
                }
                Tool::Select if self.selected.is_none() => {
                    ui.weak("Click an annotation to select it · drag to move · Delete removes · double-click text to edit");
                }
                _ => {
                    self.swatches(ui);
                    ui.separator();
                    if self.edits_text() {
                        let mut size = self.text_size;
                        let r = ui.add(egui::Slider::new(&mut size, 10.0..=200.0).suffix(" px").text("Size"));
                        if r.changed() {
                            self.text_size = size;
                            if let Some(t) = self.text.as_mut() {
                                t.size = size;
                            }
                            if let Some(mut a) = self.selected_annotation() {
                                if let Shape::Text { size: s, .. } = &mut a.shape {
                                    *s = size;
                                    let key = format!("font-{}", a.id);
                                    self.update(a, "Change Text Size", Some(&key));
                                }
                            }
                        }
                        if r.drag_stopped() {
                            self.history.break_coalescing();
                        }
                        ui.weak("Enter: done · Shift+Enter: new line · Esc: cancel");
                    } else {
                        let highlighter = self.edits_highlighter();
                        let mut width = if highlighter { self.highlight_width } else { self.width };
                        let range = if highlighter { 6.0..=80.0 } else { 1.0..=40.0 };
                        let r = ui.add(egui::Slider::new(&mut width, range).suffix(" px").text("Thickness"));
                        if r.changed() {
                            if highlighter { self.highlight_width = width } else { self.width = width }
                            if let Some(mut a) = self.selected_annotation().filter(|a| !a.is_text()) {
                                a.width = width;
                                let key = format!("width-{}", a.id);
                                self.update(a, "Change Thickness", Some(&key));
                            }
                        }
                        if r.drag_stopped() {
                            self.history.break_coalescing();
                        }
                        if highlighter {
                            let mut opacity = self.highlight_opacity * 100.0;
                            let r = ui.add(egui::Slider::new(&mut opacity, 15.0..=80.0).suffix(" %").text("Opacity"));
                            if r.changed() {
                                self.highlight_opacity = opacity / 100.0;
                                if let Some(mut a) = self.selected_annotation().filter(|a| matches!(a.shape, Shape::Highlighter(_))) {
                                    a.color = a.color.with_alpha((self.highlight_opacity * 255.0) as u8);
                                    let key = format!("opacity-{}", a.id);
                                    self.update(a, "Change Opacity", Some(&key));
                                }
                            }
                            if r.drag_stopped() {
                                self.history.break_coalescing();
                            }
                        } else if self.tool.draws() {
                            ui.weak("Hold Shift to constrain");
                        }
                    }
                    if self.selected.is_some() && self.text.is_none() {
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui.button("Delete").on_hover_text("Delete the selected annotation").clicked() {
                                if let Some(id) = self.selected {
                                    self.remove(&HashSet::from([id]), "Delete");
                                }
                            }
                        });
                    }
                }
            }
        });
        ui.add_space(3.0);
    }

    fn bottom_bar(&mut self, ui: &mut egui::Ui) {
        let ctx = ui.ctx().clone();
        ui.add_space(5.0);
        ui.horizontal(|ui| {
            let (w, h) = self.image_size();
            ui.weak(format!("{w} × {h} px"));
            ui.separator();
            if ui.button("−").on_hover_text("Zoom out (Ctrl+−)").clicked() {
                self.zoom = Some(self.current_zoom(&ctx) / 1.25);
            }
            let shown = (self.last_zoom(&ctx) * ctx.pixels_per_point() * 100.0).round();
            ui.label(format!("{shown}%"));
            if ui.button("+").on_hover_text("Zoom in (Ctrl+=)").clicked() {
                self.zoom = Some(self.current_zoom(&ctx) * 1.25);
            }
            if ui.button("Fit").on_hover_text("Zoom to fit (Ctrl+0)").clicked() {
                self.zoom = None;
                self.pan = Vec2::ZERO;
            }
            if ui.button("100%").on_hover_text("Actual pixels (Ctrl+1)").clicked() {
                self.zoom = Some(1.0 / ctx.pixels_per_point());
            }
            if let Some((message, at)) = &self.status {
                if ctx.input(|i| i.time) - at < 2.5 {
                    ui.separator();
                    ui.colored_label(ACCENT, message);
                    ctx.request_repaint_after(Duration::from_millis(500));
                }
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let primary = egui::Button::new(egui::RichText::new("Copy & Close").color(Color32::WHITE).strong()).fill(ACCENT);
                if ui.add(primary).on_hover_text("Copy the edited image and close (Ctrl+Enter)").clicked() {
                    self.close(&ctx, true);
                }
                if ui.button("Copy").on_hover_text("Copy the edited image to the clipboard (Ctrl+C)").clicked() {
                    self.copy(&ctx);
                }
                if ui.button("Cancel").on_hover_text("Close without changing the clipboard (Esc)").clicked() {
                    self.close(&ctx, false);
                }
            });
        });
        ui.add_space(5.0);
    }

    fn last_zoom(&self, ctx: &egui::Context) -> f32 {
        ctx.data(|d| d.get_temp::<f32>(egui::Id::unique("editor-zoom"))).unwrap_or(1.0)
    }

    fn refresh_texture(&mut self, ctx: &egui::Context) {
        if !self.dirty && self.texture_hidden.as_ref() == Some(&self.hidden) && self.texture.is_some() {
            return;
        }
        let visible: Vec<Annotation> = self.state.annotations.iter().filter(|a| !self.hidden.contains(&a.id)).cloned().collect();
        let composite = crate::render::render(&self.state.image, &visible);
        let image = ui_common::color_image(ctx, &composite);
        match &mut self.texture {
            Some(texture) => texture.set(image, egui::TextureOptions::LINEAR),
            None => self.texture = Some(ctx.load_texture("capture", image, egui::TextureOptions::LINEAR)),
        }
        self.texture_hidden = Some(self.hidden.clone());
        self.dirty = false;
    }

    fn canvas(&mut self, ui: &mut egui::Ui) {
        let ctx = ui.ctx().clone();
        self.refresh_texture(&ctx);
        let canvas = ui.max_rect();
        let response = ui.allocate_rect(canvas, Sense::click_and_drag());
        let (iw, ih) = self.image_size();
        let image_size = Vec2::new(iw as f32, ih as f32);

        // Zoom with Ctrl+scroll or pinch around the pointer; scroll pans when zoomed in.
        let (zoom_delta, scroll, hover) = ctx.input(|i| (i.zoom_delta(), i.smooth_scroll_delta, i.pointer.hover_pos()));
        let fit = ((canvas.width() - 48.0) / image_size.x).min((canvas.height() - 48.0) / image_size.y).min(1.0 / ctx.pixels_per_point()).max(0.02);
        if response.hovered() && zoom_delta != 1.0 {
            self.zoom = Some((self.zoom.unwrap_or(fit) * zoom_delta).clamp(0.02, 32.0));
        } else if response.hovered() && self.zoom.is_some() && scroll != Vec2::ZERO {
            self.pan += scroll;
        }
        let zoom = self.zoom.unwrap_or(fit);
        ctx.data_mut(|d| d.insert_temp(egui::Id::unique("editor-zoom"), zoom));
        let size = image_size * zoom;
        let max_pan = ((size - canvas.size()) / 2.0 + Vec2::splat(24.0)).max(Vec2::ZERO);
        self.pan = self.pan.clamp(-max_pan, max_pan);
        let image_rect = Rect::from_center_size(canvas.center() + self.pan, size);
        let view = View { image_rect, zoom };
        self.last_view = Some(view);
        let painter = ui.painter_at(canvas);

        painter.rect_filled(image_rect.translate(Vec2::new(0.0, 2.0)).expand(2.0), 2.0, Color32::from_black_alpha(40));
        if let Some(texture) = &self.texture {
            painter.image(texture.id(), image_rect, Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)), Color32::WHITE);
        }

        self.handle_pointer(&ctx, &response, &view, hover);

        // In-progress or moving annotation.
        let clipped = ui.painter_at(image_rect.intersect(canvas));
        match &self.drag {
            Drag::Drawing { annotation, .. } => paint_annotation(&clipped, &view, annotation),
            Drag::Moving { current, .. } => paint_annotation(&clipped, &view, current),
            _ => {}
        }

        // Selection outline.
        let selected = match &self.drag {
            Drag::Moving { current, .. } => Some(current.clone()),
            _ => self.selected_annotation(),
        };
        if let (Some(a), None) = (selected, &self.text) {
            let r = view.rect_to_screen(a.bounds()).expand(4.0);
            painter.add(egui::Shape::dashed_line(&[r.left_top(), r.right_top(), r.right_bottom(), r.left_bottom(), r.left_top()], Stroke::new(1.5, ACCENT), 5.0, 3.0));
        }

        if self.tool == Tool::Crop {
            match self.crop {
                Some(c) => {
                    let r = view.rect_to_screen(c);
                    let dim = Color32::from_black_alpha(130);
                    painter.rect_filled(Rect::from_min_max(image_rect.min, Pos2::new(image_rect.max.x, r.min.y)), 0.0, dim);
                    painter.rect_filled(Rect::from_min_max(Pos2::new(image_rect.min.x, r.max.y), image_rect.max), 0.0, dim);
                    painter.rect_filled(Rect::from_min_max(Pos2::new(image_rect.min.x, r.min.y), Pos2::new(r.min.x, r.max.y)), 0.0, dim);
                    painter.rect_filled(Rect::from_min_max(Pos2::new(r.max.x, r.min.y), Pos2::new(image_rect.max.x, r.max.y)), 0.0, dim);
                    painter.rect_stroke(r, 0.0, Stroke::new(1.5, Color32::WHITE), StrokeKind::Outside);
                    let label = format!("{} × {}", c.w as u32, c.h as u32);
                    let pos = if r.min.y - 22.0 > image_rect.min.y { r.center_top() - Vec2::new(0.0, 14.0) } else { r.center_bottom() + Vec2::new(0.0, 14.0) };
                    let galley = painter.layout_no_wrap(label, egui::FontId::monospace(12.0), Color32::WHITE);
                    let bg = Rect::from_center_size(pos, galley.size() + Vec2::new(12.0, 6.0));
                    painter.rect_filled(bg, 4.0, Color32::from_black_alpha(190));
                    painter.galley(bg.min + Vec2::new(6.0, 3.0), galley, Color32::WHITE);
                }
                None => {
                    painter.text(image_rect.center_top() + Vec2::new(0.0, 20.0), Align2::CENTER_TOP, "Drag to choose the area to keep",
                                 egui::FontId::proportional(14.0), Color32::WHITE);
                }
            }
        }

        if self.tool == Tool::Eraser {
            if let Some(p) = hover.filter(|p| canvas.contains(*p)) {
                painter.circle_stroke(p, 8.0, Stroke::new(2.5, Color32::WHITE));
                painter.circle_stroke(p, 8.0, Stroke::new(1.0, Color32::BLACK));
            }
        }

        self.text_field(ui, &view);

        let cursor = match self.tool {
            Tool::Select => egui::CursorIcon::Default,
            Tool::Text => egui::CursorIcon::Text,
            _ => egui::CursorIcon::Crosshair,
        };
        if response.hovered() {
            ctx.set_cursor_icon(if matches!(self.drag, Drag::Panning { .. }) { egui::CursorIcon::Grabbing } else { cursor });
        }
    }

    fn handle_pointer(&mut self, ctx: &egui::Context, response: &egui::Response, view: &View, hover: Option<Pos2>) {
        let (pressed, down, released, shift, double, space, middle) = ctx.input(|i| {
            (i.pointer.primary_pressed(), i.pointer.primary_down(), i.pointer.primary_released(), i.modifiers.shift,
             i.pointer.button_double_clicked(egui::PointerButton::Primary), i.key_down(Key::Space), i.pointer.middle_down())
        });
        let tolerance = 5.0 / view.zoom;
        let Some(pos) = hover else { return };
        let p = view.to_image(pos);
        let (iw, ih) = self.image_size();
        let clamp = |p: Pt| Pt::new(p.x.clamp(0.0, iw as f32), p.y.clamp(0.0, ih as f32));

        if (pressed || middle) && response.hovered() && matches!(self.drag, Drag::None) {
            if self.text.is_some() {
                // The text box sits above the canvas, so a press that reaches the canvas is outside it:
                // that finishes typing rather than starting a new action.
                self.commit_text();
                return;
            }
            if space || middle {
                self.drag = Drag::Panning { start: pos, pan: self.pan };
                if self.zoom.is_none() {
                    self.zoom = Some(view.zoom);
                }
                return;
            }
            let topmost = |interior: bool, text_only: bool| {
                self.state.annotations.iter().rev()
                    .find(|a| !self.hidden.contains(&a.id) && (!text_only || a.is_text()) && a.hit(p, tolerance, interior))
                    .cloned()
            };
            match self.tool {
                Tool::Select | Tool::Text => {
                    let text_only = self.tool == Tool::Text;
                    if let Some(hit) = topmost(true, text_only) {
                        self.select(Some(hit.id));
                        if double && hit.is_text() {
                            self.begin_text(Pt::default(), Some(&hit));
                        } else {
                            self.drag = Drag::Moving { original: hit.clone(), start: p, current: hit };
                        }
                    } else {
                        self.selected = None;
                        if self.tool == Tool::Text {
                            self.begin_text(clamp(p), None);
                        }
                    }
                }
                Tool::Eraser => {
                    self.drag = Drag::Erasing(HashSet::new());
                    self.erase(p, tolerance);
                }
                Tool::Crop => {
                    if let Some(c) = self.crop.filter(|c| c.contains(p)) {
                        self.drag = Drag::MovingCrop { original: c, start: p };
                    } else {
                        self.crop = None;
                        self.drag = Drag::Cropping { start: clamp(p) };
                    }
                }
                tool => {
                    self.selected = None;
                    let (color, width) = if tool == Tool::Highlighter {
                        (self.highlight_color.with_alpha((self.highlight_opacity * 255.0) as u8), self.highlight_width)
                    } else {
                        (self.color, self.width)
                    };
                    self.drag = Drag::Drawing { annotation: Annotation { id: 0, shape: shape_for(tool, p, p), color, width }, start: p };
                }
            }
            return;
        }

        if down || middle {
            let tool = self.tool;
            let zoom = view.zoom;
            match &mut self.drag {
                Drag::Drawing { annotation, start } => match &mut annotation.shape {
                    Shape::Pen(points) => {
                        if points.last().is_none_or(|l| l.dist(p) >= 0.75 / zoom) {
                            points.push(p);
                        }
                    }
                    Shape::Highlighter(points) => {
                        if shift {
                            *points = vec![*start, constrain(Tool::Line, *start, p)];
                        } else if points.last().is_none_or(|l| l.dist(p) >= 0.75 / zoom) {
                            points.push(p);
                        }
                    }
                    shape => {
                        let end = if shift { constrain(tool, *start, p) } else { p };
                        *shape = shape_for(tool, *start, end);
                    }
                },
                Drag::Moving { original, start, current } => {
                    *current = original.translated(p.x - start.x, p.y - start.y);
                    let id = original.id;
                    self.hidden.insert(id);
                }
                Drag::Cropping { start } => {
                    self.crop = Some(RectF::from_points(*start, clamp(p)).snapped(iw, ih));
                }
                Drag::MovingCrop { original, start } => {
                    let mut c = *original;
                    c.x = (c.x + (p.x - start.x).round()).clamp(0.0, iw as f32 - c.w);
                    c.y = (c.y + (p.y - start.y).round()).clamp(0.0, ih as f32 - c.h);
                    self.crop = Some(c);
                }
                Drag::Erasing(_) => self.erase(p, tolerance),
                Drag::Panning { start, pan } => {
                    self.pan = *pan + (pos - *start);
                }
                Drag::None => {}
            }
            ctx.request_repaint();
        }

        if released || (!down && !middle && !matches!(self.drag, Drag::None)) {
            let drag = std::mem::replace(&mut self.drag, Drag::None);
            match drag {
                Drag::Drawing { annotation, .. } => {
                    let min = 3.0 / view.zoom;
                    let meaningful = match &annotation.shape {
                        Shape::Pen(p) | Shape::Highlighter(p) => !p.is_empty(),
                        Shape::Rect(r) | Shape::Ellipse(r) => r.w >= min && r.h >= min,
                        Shape::Line(a, b) | Shape::Arrow(a, b) => a.dist(*b) >= min,
                        Shape::Text { .. } => true,
                    };
                    if meaningful {
                        let name = format!("Add {}", self.tool.label());
                        self.add(annotation, &name);
                    }
                }
                Drag::Moving { original, current, .. } => {
                    self.hidden.remove(&original.id);
                    if current != original {
                        self.update(current, "Move", None);
                    }
                }
                Drag::Cropping { .. } => {
                    if self.crop.is_some_and(|c| c.w < 2.0 || c.h < 2.0) {
                        self.crop = None;
                    }
                }
                Drag::Erasing(ids) => {
                    for id in &ids {
                        self.hidden.remove(id);
                    }
                    self.remove(&ids, "Erase");
                }
                Drag::MovingCrop { .. } | Drag::Panning { .. } | Drag::None => {}
            }
        }
    }

    fn erase(&mut self, p: Pt, tolerance: f32) {
        let Drag::Erasing(ids) = &mut self.drag else { return };
        for a in &self.state.annotations {
            if !ids.contains(&a.id) && a.hit(p, tolerance * 1.6, false) {
                ids.insert(a.id);
                self.hidden.insert(a.id);
            }
        }
    }

    fn text_field(&mut self, ui: &mut egui::Ui, view: &View) {
        let Some(editing) = self.text.as_mut() else { return };
        let (w, h) = crate::font::measure(&editing.text, editing.size);
        let pos = view.to_screen(editing.origin);
        let rect = Rect::from_min_size(pos - Vec2::new(4.0, 2.0), Vec2::new((w * view.zoom).max(40.0) + 24.0, h * view.zoom + 6.0));
        let commit = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Enter));
        let cancel = ui.input_mut(|i| i.consume_key(egui::Modifiers::NONE, Key::Escape));
        let font = ui_common::annotation_font(editing.size * view.zoom);
        let color = color32(editing.color);
        let response = ui.put(
            rect,
            egui::TextEdit::multiline(&mut editing.text)
                .font(font)
                .text_color(color)
                .frame(egui::Frame::new().stroke(Stroke::new(1.0, ACCENT)).inner_margin(egui::Margin::symmetric(3, 1)))
                .desired_rows(1)
                .desired_width(rect.width()),
        );
        // The click that created the box ends on the canvas, and egui moves focus away when that
        // button is released, so keep asking until the field really holds focus.
        if !editing.focused_once {
            response.request_focus();
            if response.has_focus() && !ui.input(|i| i.pointer.any_down()) {
                editing.focused_once = true;
            }
        }
        if cancel {
            self.cancel_text();
        } else if commit {
            self.commit_text();
        }
    }

    fn dialogs(&mut self, ctx: &egui::Context) {
        if self.confirm_reset {
            let mut open = true;
            egui::Window::new("Reset all edits?").collapsible(false).resizable(false).anchor(Align2::CENTER_CENTER, Vec2::ZERO).open(&mut open).show(ctx, |ui| {
                ui.label("Removes all annotations and undoes crop and resize. You can undo this.");
                ui.horizontal(|ui| {
                    if ui.button("Reset").clicked() {
                        self.reset();
                        self.confirm_reset = false;
                    }
                    if ui.button("Cancel").clicked() {
                        self.confirm_reset = false;
                    }
                });
            });
            if !open {
                self.confirm_reset = false;
            }
        }

        if self.resize.is_some() {
            let original = self.image_size();
            let mut open = true;
            let mut apply = None;
            let mut cancel = false;
            egui::Window::new("Resize Image").collapsible(false).resizable(false).anchor(Align2::CENTER_CENTER, Vec2::ZERO).open(&mut open).show(ctx, |ui| {
                let dialog = self.resize.as_mut().expect("resize dialog");
                egui::Grid::new("resize-grid").num_columns(3).show(ui, |ui| {
                    ui.label("Width");
                    if ui.add(egui::DragValue::new(&mut dialog.width).range(1..=crate::annotate::MAX_DIMENSION)).changed() && dialog.keep_aspect {
                        dialog.height = crate::annotate::height_for_width(dialog.width, original);
                    }
                    ui.weak("px");
                    ui.end_row();
                    ui.label("Height");
                    if ui.add(egui::DragValue::new(&mut dialog.height).range(1..=crate::annotate::MAX_DIMENSION)).changed() && dialog.keep_aspect {
                        dialog.width = crate::annotate::width_for_height(dialog.height, original);
                    }
                    ui.weak("px");
                    ui.end_row();
                });
                if ui.checkbox(&mut dialog.keep_aspect, "Keep aspect ratio").changed() && dialog.keep_aspect {
                    dialog.height = crate::annotate::height_for_width(dialog.width, original);
                }
                ui.horizontal(|ui| {
                    for percent in [25u32, 50, 75, 200] {
                        if ui.small_button(format!("{percent}%")).clicked() {
                            dialog.width = ((original.0 * percent) as f32 / 100.0).round().max(1.0) as u32;
                            dialog.height = ((original.1 * percent) as f32 / 100.0).round().max(1.0) as u32;
                        }
                    }
                });
                ui.label(format!("{} × {} → {} × {} px", original.0, original.1, dialog.width, dialog.height));
                let issue = crate::annotate::validate_size(dialog.width, dialog.height).err();
                if let Some(issue) = issue {
                    ui.colored_label(Color32::RED, issue);
                }
                ui.horizontal(|ui| {
                    if ui.add_enabled(issue.is_none(), egui::Button::new("Resize")).clicked() {
                        apply = Some((dialog.width, dialog.height));
                    }
                    if ui.button("Cancel").clicked() {
                        cancel = true;
                    }
                });
            });
            if let Some((w, h)) = apply {
                match self.apply_resize(w, h) {
                    Ok(()) => self.resize = None,
                    Err(e) => self.status = Some((e, ctx.input(|i| i.time))),
                }
            }
            if cancel || !open {
                self.resize = None;
            }
        }

        let mut close_ocr = false;
        let mut copy_text = None;
        match &mut self.ocr {
            Ocr::Idle => {}
            Ocr::Running(_) => {
                egui::Window::new("Extract Text").collapsible(false).show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.label("Recognizing text on this computer…");
                    });
                });
            }
            Ocr::Failed(message) => {
                let mut open = true;
                egui::Window::new("Extract Text").collapsible(false).open(&mut open).show(ctx, |ui| {
                    ui.label(format!("Couldn't recognize text: {message}"));
                });
                close_ocr = !open;
            }
            Ocr::Done(text) => {
                let mut open = true;
                egui::Window::new("Extracted Text").default_size([460.0, 300.0]).open(&mut open).show(ctx, |ui| {
                    if text.trim().is_empty() {
                        ui.label("No text found in this image.");
                    } else {
                        egui::ScrollArea::vertical().max_height(320.0).show(ui, |ui| {
                            ui.add(egui::TextEdit::multiline(text).desired_width(f32::INFINITY));
                        });
                        ui.horizontal(|ui| {
                            if ui.button("Copy Extracted Text").clicked() {
                                copy_text = Some(text.clone());
                            }
                            ui.weak("Select part of the text and press Ctrl+C to copy just that.");
                        });
                    }
                });
                close_ocr = !open;
            }
        }
        if let Some(text) = copy_text {
            ui_common::send(&Message::CopyText(text));
            self.status = Some(("Text copied to the clipboard".into(), ctx.input(|i| i.time)));
        }
        if close_ocr {
            self.ocr = Ocr::Idle;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui_kittest::kittest::Queryable;
    use egui_kittest::Harness;

    fn harness() -> Harness<'static, EditorApp> {
        ui_common::SENT.with(|s| s.borrow_mut().clear());
        let image = RgbaImage::from_pixel(800, 500, image::Rgba([255, 255, 255, 255]));
        let mut harness = Harness::builder().with_size([1200.0, 860.0]).with_pixels_per_point(1.0).build_eframe(|cc| {
            ui_common::install_fonts(&cc.egui_ctx);
            EditorApp::new(image, PALETTE[0].1, 6.0, 32.0)
        });
        harness.run_steps(3);
        harness
    }

    fn screen(h: &Harness<'static, EditorApp>, x: f32, y: f32) -> Pos2 {
        h.state().last_view.expect("canvas laid out").to_screen(Pt::new(x, y))
    }

    fn drag(h: &mut Harness<'static, EditorApp>, from: (f32, f32), to: (f32, f32)) {
        let (a, b) = (screen(h, from.0, from.1), screen(h, to.0, to.1));
        h.drag_at(a);
        h.run_steps(2);
        for i in 1..=5 {
            h.hover_at(a + (b - a) * (i as f32 / 5.0));
            h.run_steps(1);
        }
        h.drop_at(b);
        h.run_steps(3);
    }

    fn sent() -> Vec<Message> {
        ui_common::SENT.with(|s| std::mem::take(&mut *s.borrow_mut()))
    }

    #[test]
    fn draws_rectangle_and_undoes_and_redoes() {
        let mut h = harness();
        h.get_by_label("Rectangle").click();
        h.run_steps(2);
        drag(&mut h, (100.0, 100.0), (300.0, 200.0));
        let annotations = &h.state().state.annotations;
        assert_eq!(annotations.len(), 1);
        let Shape::Rect(r) = annotations[0].shape else { panic!("expected a rectangle") };
        assert!((r.x - 100.0).abs() < 3.0 && (r.w - 200.0).abs() < 4.0, "{r:?}");

        h.key_press_modifiers(egui::Modifiers::COMMAND, Key::Z);
        h.run_steps(2);
        assert!(h.state().state.annotations.is_empty());
        h.key_press_modifiers(egui::Modifiers::COMMAND | egui::Modifiers::SHIFT, Key::Z);
        h.run_steps(2);
        assert_eq!(h.state().state.annotations.len(), 1);
    }

    #[test]
    fn crop_moves_annotations_and_is_undoable() {
        let mut h = harness();
        drag(&mut h, (200.0, 200.0), (300.0, 260.0)); // default tool: arrow
        assert_eq!(h.state().state.annotations.len(), 1);
        h.key_press(Key::C);
        h.run_steps(2);
        drag(&mut h, (150.0, 150.0), (450.0, 350.0));
        assert!(h.state().crop.is_some());
        h.key_press(Key::Enter);
        h.run_steps(3);
        let (w, hh) = h.state().image_size();
        assert!((w as i32 - 300).abs() <= 2 && (hh as i32 - 200).abs() <= 2, "{w}x{hh}");
        let Shape::Arrow(a, _) = h.state().state.annotations[0].shape else { panic!() };
        assert!((a.x - 50.0).abs() < 4.0, "{a:?}");
        h.key_press_modifiers(egui::Modifiers::COMMAND, Key::Z);
        h.run_steps(2);
        assert_eq!(h.state().image_size(), (800, 500));
    }

    #[test]
    fn text_tool_adds_text() {
        let mut h = harness();
        h.key_press(Key::T);
        h.run_steps(2);
        let p = screen(&h, 120.0, 120.0);
        h.drag_at(p);
        h.run_steps(1);
        h.drop_at(p);
        h.run_steps(3);
        assert!(h.state().text.is_some());
        h.event(egui::Event::Text("Fix this".into()));
        h.run_steps(2);
        h.key_press(Key::Enter);
        h.run_steps(3);
        let annotations = &h.state().state.annotations;
        assert_eq!(annotations.len(), 1);
        assert!(matches!(&annotations[0].shape, Shape::Text { text, .. } if text == "Fix this"));
    }

    #[test]
    fn eraser_removes_annotations_not_pixels() {
        let mut h = harness();
        h.key_press(Key::L);
        h.run_steps(2);
        drag(&mut h, (100.0, 300.0), (500.0, 300.0));
        assert_eq!(h.state().state.annotations.len(), 1);
        let image_before = h.state().state.image.clone();
        h.key_press(Key::E);
        h.run_steps(2);
        drag(&mut h, (300.0, 250.0), (300.0, 350.0));
        assert!(h.state().state.annotations.is_empty());
        assert!(Arc::ptr_eq(&image_before, &h.state().state.image));
    }

    #[test]
    fn copy_sends_flattened_image_and_cancel_reports_edits() {
        let mut h = harness();
        h.get_by_label("Pen").click();
        h.run_steps(2);
        drag(&mut h, (100.0, 100.0), (400.0, 100.0));
        sent();
        h.event(egui::Event::Copy);
        h.run_steps(2);
        let messages = sent();
        let Some(Message::CopyImage(img)) = messages.first() else { panic!("expected a copy, got {}", messages.len()) };
        assert_eq!(img.dimensions(), (800, 500));
        let p = img.get_pixel(250, 100);
        assert!(p[0] > 200 && p[1] < 100, "stroke pixel {p:?}");

        h.key_press(Key::Escape);
        h.run_steps(2);
        let messages = sent();
        assert!(matches!(messages.last(), Some(Message::Closed(Some(_)))), "expected Closed with edits");
    }
}
