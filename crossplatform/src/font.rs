//! The annotation font (DejaVu Sans Bold) and text layout shared by preview and export.

use ab_glyph::{Font, FontRef, PxScale, ScaleFont};
use std::sync::OnceLock;

pub static FONT_BYTES: &[u8] = include_bytes!("../assets/DejaVuSans-Bold.ttf");

pub fn font() -> &'static FontRef<'static> {
    static FONT: OnceLock<FontRef<'static>> = OnceLock::new();
    FONT.get_or_init(|| FontRef::try_from_slice(FONT_BYTES).expect("bundled font is valid"))
}

/// A glyph positioned in text-box coordinates (top-left origin, y down).
pub struct PlacedGlyph {
    pub glyph: ab_glyph::Glyph,
}

pub struct TextLayout {
    pub glyphs: Vec<PlacedGlyph>,
    pub width: f32,
    pub height: f32,
}

/// Lays out `text` (multi-line on '\n') at `size` pixels.
pub fn layout(text: &str, size: f32) -> TextLayout {
    let font = font().as_scaled(PxScale::from(size.max(1.0)));
    let line_height = font.ascent() - font.descent() + font.line_gap();
    let mut glyphs = Vec::new();
    let mut width: f32 = 0.0;
    let lines: Vec<&str> = if text.is_empty() { vec![""] } else { text.split('\n').collect() };
    for (row, line) in lines.iter().enumerate() {
        let baseline = font.ascent() + row as f32 * line_height;
        let mut x = 0.0;
        let mut previous: Option<ab_glyph::GlyphId> = None;
        for ch in line.chars() {
            let id = font.glyph_id(ch);
            if let Some(prev) = previous {
                x += font.kern(prev, id);
            }
            glyphs.push(PlacedGlyph { glyph: id.with_scale_and_position(font.scale(), ab_glyph::point(x, baseline)) });
            x += font.h_advance(id);
            previous = Some(id);
        }
        width = width.max(x);
    }
    TextLayout { glyphs, width: width.ceil() + 2.0, height: (lines.len() as f32 * line_height).ceil() + 2.0 }
}

pub fn measure(text: &str, size: f32) -> (f32, f32) {
    let l = layout(text, size);
    (l.width.max(size * 0.5), l.height)
}
