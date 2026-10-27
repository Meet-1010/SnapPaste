//! "Extract Text" window for a captured region: recognizes text locally and lets the user copy it.

use crate::ipc::Message;
use crate::ui_common::{self, ACCENT};
use egui::{Align, Color32, Layout};
use std::sync::mpsc;
use std::time::Duration;

enum Phase {
    Running(mpsc::Receiver<Result<String, String>>),
    Done,
    Failed(String),
}

struct OcrApp {
    phase: Phase,
    text: String,
    size: (u32, u32),
    copied_at: Option<f64>,
}

pub fn run() -> Result<(), String> {
    let image = ui_common::read_stdin_image()?;
    let size = image.dimensions();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(crate::ocr::recognize(&image));
    });
    let viewport = egui::ViewportBuilder::default()
        .with_title("SnapPaste — Extract Text")
        .with_inner_size([520.0, 400.0])
        .with_min_inner_size([380.0, 260.0])
        .with_active(true);
    ui_common::run_app("SnapPaste Text", viewport, move |_| OcrApp { phase: Phase::Running(rx), text: String::new(), size, copied_at: None })
}

impl eframe::App for OcrApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if let Phase::Running(rx) = &self.phase {
            match rx.try_recv() {
                Ok(Ok(text)) => {
                    self.text = text;
                    self.phase = Phase::Done;
                }
                Ok(Err(e)) => self.phase = Phase::Failed(e),
                Err(mpsc::TryRecvError::Empty) => ctx.request_repaint_after(Duration::from_millis(120)),
                Err(mpsc::TryRecvError::Disconnected) => self.phase = Phase::Failed("Recognition stopped unexpectedly.".into()),
            }
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }

        egui::Panel::top("header").show(ui, |ui| {
            ui.add_space(6.0);
            ui.heading("Extracted Text");
            ui.weak(format!("Selected region · {} × {} px · recognized on this computer", self.size.0, self.size.1));
            ui.add_space(6.0);
        });
        egui::Panel::bottom("footer").show(ui, |ui| {
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if let Some(at) = self.copied_at {
                    if ctx.input(|i| i.time) - at < 2.5 {
                        ui.colored_label(ACCENT, "Copied to the clipboard");
                        ctx.request_repaint_after(Duration::from_millis(500));
                    }
                } else if matches!(self.phase, Phase::Done) && !self.text.is_empty() {
                    ui.weak(format!("{} characters", self.text.chars().count()));
                }
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let enabled = matches!(self.phase, Phase::Done) && !self.text.trim().is_empty();
                    let copy = egui::Button::new(egui::RichText::new("Copy Extracted Text").color(Color32::WHITE).strong()).fill(ACCENT);
                    if ui.add_enabled(enabled, copy).clicked() {
                        ui_common::send(&Message::CopyText(self.text.clone()));
                        self.copied_at = Some(ctx.input(|i| i.time));
                    }
                    if ui.button("Done").clicked() {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                });
            });
            ui.add_space(6.0);
        });
        egui::CentralPanel::default().show(ui, |ui| match &self.phase {
            Phase::Running(_) => {
                ui.centered_and_justified(|ui| {
                    ui.horizontal_centered(|ui| {
                        ui.spinner();
                        ui.label("Recognizing text…");
                    });
                });
            }
            Phase::Failed(message) => {
                ui.colored_label(Color32::RED, format!("Couldn't recognize text: {message}"));
            }
            Phase::Done if self.text.trim().is_empty() => {
                ui.centered_and_justified(|ui| ui.label("No text found in this region."));
            }
            Phase::Done => {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    ui.add(egui::TextEdit::multiline(&mut self.text).desired_width(f32::INFINITY).desired_rows(12));
                });
            }
        });
    }
}
