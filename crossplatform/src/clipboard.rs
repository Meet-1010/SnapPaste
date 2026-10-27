//! Clipboard owned by a long-lived thread. On X11/Wayland the copying process must stay alive to
//! serve pastes, so the background process holds the clipboard instead of short-lived UI windows.

use image::RgbaImage;
use std::borrow::Cow;
use std::sync::mpsc::{channel, Sender};

enum Job {
    Image(RgbaImage),
    Text(String),
}

#[derive(Clone)]
pub struct ClipboardService {
    tx: Sender<Job>,
}

impl ClipboardService {
    pub fn start() -> Self {
        let (tx, rx) = channel::<Job>();
        std::thread::Builder::new()
            .name("clipboard".into())
            .spawn(move || {
                let mut clipboard = match arboard::Clipboard::new() {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("SnapPaste: clipboard unavailable: {e}");
                        return;
                    }
                };
                for job in rx {
                    let result = match job {
                        Job::Image(img) => clipboard.set_image(arboard::ImageData {
                            width: img.width() as usize,
                            height: img.height() as usize,
                            bytes: Cow::Owned(img.into_raw()),
                        }),
                        Job::Text(text) => clipboard.set_text(text),
                    };
                    if let Err(e) = result {
                        eprintln!("SnapPaste: copy failed: {e}");
                    }
                }
            })
            .expect("spawn clipboard thread");
        Self { tx }
    }

    pub fn copy_image(&self, image: RgbaImage) {
        let _ = self.tx.send(Job::Image(image));
    }

    pub fn copy_text(&self, text: String) {
        let _ = self.tx.send(Job::Text(text));
    }
}
