//! Flattens annotations onto the capture with tiny-skia (antialiased paths) and ab_glyph (text).

use crate::annotate::{arrow_geometry, Annotation, Pt, RectF, Rgba, Shape};
use ab_glyph::Font;
use image::RgbaImage;
use tiny_skia::{FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke, Transform};

pub fn render(base: &RgbaImage, annotations: &[Annotation]) -> RgbaImage {
    if annotations.is_empty() {
        return base.clone();
    }
    let (w, h) = base.dimensions();
    let Some(mut pixmap) = Pixmap::new(w, h) else { return base.clone() };
    for (dst, src) in pixmap.data_mut().chunks_exact_mut(4).zip(base.as_raw().chunks_exact(4)) {
        let a = src[3] as u32;
        dst[0] = ((src[0] as u32 * a + 127) / 255) as u8;
        dst[1] = ((src[1] as u32 * a + 127) / 255) as u8;
        dst[2] = ((src[2] as u32 * a + 127) / 255) as u8;
        dst[3] = src[3];
    }
    for a in annotations {
        draw(&mut pixmap, a);
    }
    let mut out = RgbaImage::new(w, h);
    for (dst, src) in out.as_mut().chunks_exact_mut(4).zip(pixmap.data().chunks_exact(4)) {
        let a = src[3] as u32;
        if a == 0 {
            dst.copy_from_slice(&[0, 0, 0, 0]);
        } else {
            dst[0] = ((src[0] as u32 * 255 + a / 2) / a).min(255) as u8;
            dst[1] = ((src[1] as u32 * 255 + a / 2) / a).min(255) as u8;
            dst[2] = ((src[2] as u32 * 255 + a / 2) / a).min(255) as u8;
            dst[3] = src[3];
        }
    }
    out
}

fn paint(color: Rgba) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color_rgba8(color.r, color.g, color.b, color.a);
    paint.anti_alias = true;
    paint
}

fn stroke(width: f32, join: LineJoin) -> Stroke {
    Stroke { width: width.max(0.5), line_cap: LineCap::Round, line_join: join, ..Stroke::default() }
}

/// Smooth curve through sampled pointer positions (quadratic segments between midpoints).
fn smooth_path(points: &[Pt]) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let first = points.first()?;
    pb.move_to(first.x, first.y);
    if points.len() < 3 {
        for p in &points[1..] {
            pb.line_to(p.x, p.y);
        }
    } else {
        for i in 1..points.len() - 1 {
            let (c, n) = (points[i], points[i + 1]);
            pb.quad_to(c.x, c.y, (c.x + n.x) / 2.0, (c.y + n.y) / 2.0);
        }
        let last = points[points.len() - 1];
        pb.line_to(last.x, last.y);
    }
    pb.finish()
}

fn rect(r: &RectF) -> Option<tiny_skia::Rect> {
    tiny_skia::Rect::from_xywh(r.x, r.y, r.w.max(0.01), r.h.max(0.01))
}

pub fn draw(pixmap: &mut Pixmap, a: &Annotation) {
    let p = paint(a.color);
    let id = Transform::identity();
    match &a.shape {
        Shape::Pen(points) | Shape::Highlighter(points) => {
            if points.len() == 1 {
                if let Some(path) = PathBuilder::from_circle(points[0].x, points[0].y, a.width / 2.0) {
                    pixmap.fill_path(&path, &p, FillRule::Winding, id, None);
                }
            } else if let Some(path) = smooth_path(points) {
                pixmap.stroke_path(&path, &p, &stroke(a.width, LineJoin::Round), id, None);
            }
        }
        Shape::Rect(r) => {
            if let Some(path) = rect(r).map(PathBuilder::from_rect) {
                pixmap.stroke_path(&path, &p, &stroke(a.width, LineJoin::Miter), id, None);
            }
        }
        Shape::Ellipse(r) => {
            if let Some(path) = rect(r).and_then(PathBuilder::from_oval) {
                pixmap.stroke_path(&path, &p, &stroke(a.width, LineJoin::Round), id, None);
            }
        }
        Shape::Line(s, e) => {
            let mut pb = PathBuilder::new();
            pb.move_to(s.x, s.y);
            pb.line_to(e.x, e.y);
            if let Some(path) = pb.finish() {
                pixmap.stroke_path(&path, &p, &stroke(a.width, LineJoin::Round), id, None);
            }
        }
        Shape::Arrow(s, e) => {
            let Some((shaft, tip, left, right)) = arrow_geometry(*s, *e, a.width) else { return };
            let mut pb = PathBuilder::new();
            pb.move_to(s.x, s.y);
            pb.line_to(shaft.x, shaft.y);
            if let Some(path) = pb.finish() {
                pixmap.stroke_path(&path, &p, &stroke(a.width, LineJoin::Round), id, None);
            }
            let mut head = PathBuilder::new();
            head.move_to(tip.x, tip.y);
            head.line_to(left.x, left.y);
            head.line_to(right.x, right.y);
            head.close();
            if let Some(path) = head.finish() {
                pixmap.fill_path(&path, &p, FillRule::Winding, id, None);
                pixmap.stroke_path(&path, &p, &stroke((a.width * 0.25).max(1.0), LineJoin::Round), id, None);
            }
        }
        Shape::Text { origin, text, size } => draw_text(pixmap, *origin, text, *size, a.color),
    }
}

fn draw_text(pixmap: &mut Pixmap, origin: Pt, text: &str, size: f32, color: Rgba) {
    let layout = crate::font::layout(text, size);
    let font = crate::font::font();
    let (width, height) = (pixmap.width() as i32, pixmap.height() as i32);
    let data = pixmap.data_mut();
    for placed in layout.glyphs {
        let Some(outlined) = font.outline_glyph(placed.glyph) else { continue };
        let bounds = outlined.px_bounds();
        outlined.draw(|gx, gy, coverage| {
            let x = (origin.x + bounds.min.x).round() as i32 + gx as i32;
            let y = (origin.y + bounds.min.y).round() as i32 + gy as i32;
            if x < 0 || y < 0 || x >= width || y >= height {
                return;
            }
            let alpha = coverage.clamp(0.0, 1.0) * color.a as f32 / 255.0;
            if alpha <= 0.0 {
                return;
            }
            let i = ((y * width + x) * 4) as usize;
            let inv = 1.0 - alpha;
            // Source-over in premultiplied space.
            data[i] = (color.r as f32 * alpha + data[i] as f32 * inv).round() as u8;
            data[i + 1] = (color.g as f32 * alpha + data[i + 1] as f32 * inv).round() as u8;
            data[i + 2] = (color.b as f32 * alpha + data[i + 2] as f32 * inv).round() as u8;
            data[i + 3] = (255.0 * alpha + data[i + 3] as f32 * inv).round() as u8;
        });
    }
}

pub fn crop(image: &RgbaImage, r: RectF) -> Option<RgbaImage> {
    let s = r.snapped(image.width(), image.height());
    if s.w < 1.0 || s.h < 1.0 {
        return None;
    }
    Some(image::imageops::crop_imm(image, s.x as u32, s.y as u32, s.w as u32, s.h as u32).to_image())
}

pub fn resize(image: &RgbaImage, w: u32, h: u32) -> Option<RgbaImage> {
    crate::annotate::validate_size(w, h).ok()?;
    Some(image::imageops::resize(image, w, h, image::imageops::FilterType::Lanczos3))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotate::PALETTE;

    fn white(w: u32, h: u32) -> RgbaImage {
        RgbaImage::from_pixel(w, h, image::Rgba([255, 255, 255, 255]))
    }

    fn is_red(p: &image::Rgba<u8>) -> bool {
        p[0] > 200 && p[1] < 90 && p[2] < 90
    }

    #[test]
    fn rectangle_lands_in_top_left_space() {
        let a = Annotation { id: 1, shape: Shape::Rect(RectF { x: 10.0, y: 10.0, w: 30.0, h: 30.0 }), color: PALETTE[0].1, width: 4.0 };
        let out = render(&white(100, 100), &[a]);
        assert!(is_red(out.get_pixel(10, 25)));
        assert_eq!(out.get_pixel(25, 25)[0], 255);
        assert_eq!(out.get_pixel(10, 85)[1], 255);
    }

    #[test]
    fn highlighter_is_translucent() {
        let black = RgbaImage::from_pixel(60, 60, image::Rgba([0, 0, 0, 255]));
        let a = Annotation {
            id: 1,
            shape: Shape::Highlighter(vec![Pt::new(0.0, 30.0), Pt::new(60.0, 30.0)]),
            color: PALETTE[2].1.with_alpha(100),
            width: 20.0,
        };
        let p = *render(&black, &[a]).get_pixel(30, 30);
        assert!(p[0] > 60 && p[0] < 200);
    }

    #[test]
    fn text_produces_pixels() {
        let a = Annotation { id: 1, shape: Shape::Text { origin: Pt::new(10.0, 10.0), text: "WWW".into(), size: 40.0 }, color: PALETTE[0].1, width: 0.0 };
        let out = render(&white(200, 80), &[a]);
        let red = out.pixels().filter(|p| is_red(p)).count();
        assert!(red > 100, "red pixels: {red}");
        assert_eq!(out.get_pixel(195, 78)[1], 255);
    }

    #[test]
    fn crop_and_resize() {
        let mut img = white(100, 80);
        img.put_pixel(5, 5, image::Rgba([255, 0, 0, 255]));
        let c = crop(&img, RectF { x: 0.0, y: 0.0, w: 50.0, h: 40.0 }).unwrap();
        assert_eq!(c.dimensions(), (50, 40));
        assert!(is_red(c.get_pixel(5, 5)));
        assert!(crop(&img, RectF { x: 200.0, y: 0.0, w: 5.0, h: 5.0 }).is_none());
        assert_eq!(resize(&img, 50, 40).unwrap().dimensions(), (50, 40));
        assert!(resize(&img, 0, 40).is_none());
    }

    #[test]
    fn no_annotations_returns_identical_pixels() {
        let img = white(10, 10);
        assert_eq!(render(&img, &[]), img);
    }
}
