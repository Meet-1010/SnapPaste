//! Vector annotations in image-pixel space (top-left origin). They stay editable objects until the
//! image is exported, so erasing or moving them never touches the captured pixels.

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Pt {
    pub x: f32,
    pub y: f32,
}

impl Pt {
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn dist(self, o: Pt) -> f32 {
        ((self.x - o.x).powi(2) + (self.y - o.y).powi(2)).sqrt()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct RectF {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl RectF {
    pub fn from_points(a: Pt, b: Pt) -> Self {
        Self { x: a.x.min(b.x), y: a.y.min(b.y), w: (a.x - b.x).abs(), h: (a.y - b.y).abs() }
    }

    pub fn max_x(&self) -> f32 {
        self.x + self.w
    }

    pub fn max_y(&self) -> f32 {
        self.y + self.h
    }

    pub fn contains(&self, p: Pt) -> bool {
        p.x >= self.x && p.x <= self.max_x() && p.y >= self.y && p.y <= self.max_y()
    }

    pub fn inset(&self, d: f32) -> Self {
        Self { x: self.x + d, y: self.y + d, w: (self.w - 2.0 * d).max(0.0), h: (self.h - 2.0 * d).max(0.0) }
    }

    pub fn intersects(&self, o: &RectF) -> bool {
        self.x < o.max_x() && o.x < self.max_x() && self.y < o.max_y() && o.y < self.max_y()
    }

    /// Rounded to whole pixels and clamped to `width`×`height`. May be empty.
    pub fn snapped(&self, width: u32, height: u32) -> Self {
        let (w, h) = (width as f32, height as f32);
        let x0 = self.x.round().clamp(0.0, w);
        let y0 = self.y.round().clamp(0.0, h);
        let x1 = self.max_x().round().clamp(0.0, w);
        let y1 = self.max_y().round().clamp(0.0, h);
        Self { x: x0, y: y0, w: (x1 - x0).max(0.0), h: (y1 - y0).max(0.0) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub fn with_alpha(self, a: u8) -> Self {
        Self { a, ..self }
    }

    pub fn same_rgb(self, o: Rgba) -> bool {
        self.r == o.r && self.g == o.g && self.b == o.b
    }

    /// Parses `#RRGGBB`.
    pub fn parse_hex(s: &str) -> Option<Self> {
        let s = s.trim().trim_start_matches('#');
        if s.len() != 6 {
            return None;
        }
        let v = u32::from_str_radix(s, 16).ok()?;
        Some(Self::rgb((v >> 16) as u8, (v >> 8) as u8, v as u8))
    }
}

pub const PALETTE: [(&str, Rgba); 8] = [
    ("Red", Rgba::rgb(0xFF, 0x3B, 0x30)),
    ("Orange", Rgba::rgb(0xFF, 0x95, 0x00)),
    ("Yellow", Rgba::rgb(0xFF, 0xD6, 0x0A)),
    ("Green", Rgba::rgb(0x34, 0xC7, 0x59)),
    ("Blue", Rgba::rgb(0x0A, 0x84, 0xFF)),
    ("Purple", Rgba::rgb(0xBF, 0x5A, 0xF2)),
    ("Black", Rgba::rgb(0x11, 0x11, 0x11)),
    ("White", Rgba::rgb(0xFF, 0xFF, 0xFF)),
];

#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Pen(Vec<Pt>),
    Highlighter(Vec<Pt>),
    Rect(RectF),
    Ellipse(RectF),
    Line(Pt, Pt),
    Arrow(Pt, Pt),
    Text { origin: Pt, text: String, size: f32 },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Annotation {
    pub id: u64,
    pub shape: Shape,
    /// Highlighter opacity lives in the alpha channel.
    pub color: Rgba,
    /// Stroke width in image pixels (unused for text).
    pub width: f32,
}

pub fn arrow_head_length(width: f32) -> f32 {
    (width * 4.0).max(12.0)
}

/// Shaft end, tip, and the two base corners of the arrow head; None for a degenerate arrow.
pub fn arrow_geometry(start: Pt, tip: Pt, width: f32) -> Option<(Pt, Pt, Pt, Pt)> {
    let (dx, dy) = (tip.x - start.x, tip.y - start.y);
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1.0 {
        return None;
    }
    let (ux, uy) = (dx / len, dy / len);
    let head = arrow_head_length(width).min(len);
    let half = head * 0.45;
    let base = Pt::new(tip.x - ux * head, tip.y - uy * head);
    let left = Pt::new(base.x - uy * half, base.y + ux * half);
    let right = Pt::new(base.x + uy * half, base.y - ux * half);
    let shaft_end = Pt::new(tip.x - ux * head * 0.5, tip.y - uy * head * 0.5);
    Some((shaft_end, tip, left, right))
}

fn dist_to_segment(p: Pt, a: Pt, b: Pt) -> f32 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return p.dist(a);
    }
    let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
    p.dist(Pt::new(a.x + t * dx, a.y + t * dy))
}

fn dist_to_rect_border(p: Pt, r: &RectF) -> f32 {
    if r.contains(p) {
        return (p.x - r.x).min(r.max_x() - p.x).min(p.y - r.y).min(r.max_y() - p.y);
    }
    let dx = (r.x - p.x).max(0.0).max(p.x - r.max_x());
    let dy = (r.y - p.y).max(0.0).max(p.y - r.max_y());
    (dx * dx + dy * dy).sqrt()
}

fn bounding(points: &[Pt]) -> RectF {
    let Some(first) = points.first() else { return RectF::default() };
    let (mut x0, mut y0, mut x1, mut y1) = (first.x, first.y, first.x, first.y);
    for p in points {
        x0 = x0.min(p.x);
        y0 = y0.min(p.y);
        x1 = x1.max(p.x);
        y1 = y1.max(p.y);
    }
    RectF { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
}

impl Annotation {
    pub fn is_text(&self) -> bool {
        matches!(self.shape, Shape::Text { .. })
    }

    pub fn bounds(&self) -> RectF {
        let pad = self.width / 2.0 + 1.0;
        match &self.shape {
            Shape::Pen(p) | Shape::Highlighter(p) => bounding(p).inset(-pad),
            Shape::Rect(r) | Shape::Ellipse(r) => r.inset(-pad),
            Shape::Line(a, b) => bounding(&[*a, *b]).inset(-pad),
            Shape::Arrow(a, b) => bounding(&[*a, *b]).inset(-(pad + arrow_head_length(self.width))),
            Shape::Text { origin, text, size } => {
                let (w, h) = crate::font::measure(text, *size);
                RectF { x: origin.x, y: origin.y, w, h }
            }
        }
    }

    pub fn hit(&self, p: Pt, tolerance: f32, interior: bool) -> bool {
        let reach = self.width / 2.0 + tolerance;
        match &self.shape {
            Shape::Pen(pts) | Shape::Highlighter(pts) => match pts.len() {
                0 => false,
                1 => p.dist(pts[0]) <= reach,
                _ => pts.windows(2).any(|w| dist_to_segment(p, w[0], w[1]) <= reach),
            },
            Shape::Rect(r) => (interior && r.contains(p)) || dist_to_rect_border(p, r) <= reach,
            Shape::Ellipse(r) => {
                let (a, b) = (r.w / 2.0, r.h / 2.0);
                if a <= 0.0 || b <= 0.0 {
                    return dist_to_rect_border(p, r) <= reach;
                }
                let (nx, ny) = ((p.x - (r.x + a)) / a, (p.y - (r.y + b)) / b);
                let v = (nx * nx + ny * ny).sqrt();
                (interior && v <= 1.0) || (v - 1.0).abs() * a.min(b) <= reach
            }
            Shape::Line(a, b) => dist_to_segment(p, *a, *b) <= reach,
            Shape::Arrow(a, b) => {
                dist_to_segment(p, *a, *b) <= reach || p.dist(*b) <= arrow_head_length(self.width) * 0.6 + tolerance
            }
            Shape::Text { .. } => self.bounds().inset(-tolerance).contains(p),
        }
    }

    pub fn translated(&self, dx: f32, dy: f32) -> Self {
        let t = |p: &Pt| Pt::new(p.x + dx, p.y + dy);
        let r = |r: &RectF| RectF { x: r.x + dx, y: r.y + dy, ..*r };
        let shape = match &self.shape {
            Shape::Pen(p) => Shape::Pen(p.iter().map(t).collect()),
            Shape::Highlighter(p) => Shape::Highlighter(p.iter().map(t).collect()),
            Shape::Rect(x) => Shape::Rect(r(x)),
            Shape::Ellipse(x) => Shape::Ellipse(r(x)),
            Shape::Line(a, b) => Shape::Line(t(a), t(b)),
            Shape::Arrow(a, b) => Shape::Arrow(t(a), t(b)),
            Shape::Text { origin, text, size } => Shape::Text { origin: t(origin), text: text.clone(), size: *size },
        };
        Self { shape, ..self.clone() }
    }

    /// Scales about the image origin, e.g. after the image itself is resized.
    pub fn scaled(&self, sx: f32, sy: f32) -> Self {
        let s = |p: &Pt| Pt::new(p.x * sx, p.y * sy);
        let r = |r: &RectF| RectF { x: r.x * sx, y: r.y * sy, w: r.w * sx, h: r.h * sy };
        let avg = (sx + sy) / 2.0;
        let shape = match &self.shape {
            Shape::Pen(p) => Shape::Pen(p.iter().map(s).collect()),
            Shape::Highlighter(p) => Shape::Highlighter(p.iter().map(s).collect()),
            Shape::Rect(x) => Shape::Rect(r(x)),
            Shape::Ellipse(x) => Shape::Ellipse(r(x)),
            Shape::Line(a, b) => Shape::Line(s(a), s(b)),
            Shape::Arrow(a, b) => Shape::Arrow(s(a), s(b)),
            Shape::Text { origin, text, size } => Shape::Text { origin: s(origin), text: text.clone(), size: (size * avg).max(1.0) },
        };
        Self { shape, width: (self.width * avg).max(0.5), ..self.clone() }
    }
}

/// Keeps aspect ratio: new height for a given width (never below 1).
pub fn height_for_width(width: u32, original: (u32, u32)) -> u32 {
    if original.0 == 0 {
        return original.1.max(1);
    }
    ((width as f64 * original.1 as f64 / original.0 as f64).round() as u32).max(1)
}

pub fn width_for_height(height: u32, original: (u32, u32)) -> u32 {
    if original.1 == 0 {
        return original.0.max(1);
    }
    ((height as f64 * original.0 as f64 / original.1 as f64).round() as u32).max(1)
}

pub const MAX_DIMENSION: u32 = 16_384;
pub const MAX_PIXELS: u64 = 100_000_000;

pub fn validate_size(w: u32, h: u32) -> Result<(), &'static str> {
    if w == 0 || h == 0 {
        return Err("Width and height must be at least 1 pixel.");
    }
    if w > MAX_DIMENSION || h > MAX_DIMENSION {
        return Err("Width and height can't exceed 16384 pixels.");
    }
    if w as u64 * h as u64 > MAX_PIXELS {
        return Err("The image would be too large (over 100 megapixels).");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ann(shape: Shape) -> Annotation {
        Annotation { id: 1, shape, color: PALETTE[0].1, width: 4.0 }
    }

    #[test]
    fn crop_rect_is_normalized_snapped_and_clamped() {
        let r = RectF::from_points(Pt::new(150.4, 80.6), Pt::new(-20.0, 20.2)).snapped(100, 60);
        assert_eq!(r, RectF { x: 0.0, y: 20.0, w: 100.0, h: 40.0 });
    }

    #[test]
    fn aspect_ratio_math() {
        assert_eq!(height_for_width(960, (1920, 1080)), 540);
        assert_eq!(height_for_width(1000, (1920, 1080)), 563);
        assert_eq!(width_for_height(720, (1920, 1080)), 1280);
        assert_eq!(height_for_width(1, (4000, 10)), 1);
    }

    #[test]
    fn size_validation() {
        assert!(validate_size(800, 600).is_ok());
        assert!(validate_size(0, 10).is_err());
        assert!(validate_size(20_000, 10).is_err());
        assert!(validate_size(16_000, 16_000).is_err());
    }

    #[test]
    fn pen_and_rect_hit_testing() {
        let pen = ann(Shape::Pen(vec![Pt::new(0.0, 0.0), Pt::new(100.0, 0.0)]));
        assert!(pen.hit(Pt::new(50.0, 3.0), 2.0, false));
        assert!(!pen.hit(Pt::new(50.0, 10.0), 2.0, false));
        let rect = ann(Shape::Rect(RectF { x: 10.0, y: 10.0, w: 100.0, h: 100.0 }));
        assert!(rect.hit(Pt::new(11.0, 50.0), 1.0, false));
        assert!(!rect.hit(Pt::new(60.0, 60.0), 1.0, false));
        assert!(rect.hit(Pt::new(60.0, 60.0), 1.0, true));
    }

    #[test]
    fn ellipse_hit_testing() {
        let e = ann(Shape::Ellipse(RectF { x: 0.0, y: 0.0, w: 200.0, h: 100.0 }));
        assert!(e.hit(Pt::new(100.0, 1.0), 2.0, false));
        assert!(!e.hit(Pt::new(100.0, 50.0), 2.0, false));
        assert!(e.hit(Pt::new(100.0, 50.0), 2.0, true));
    }

    #[test]
    fn transforms() {
        let a = ann(Shape::Arrow(Pt::new(10.0, 10.0), Pt::new(50.0, 30.0)));
        assert_eq!(a.translated(-10.0, 5.0).shape, Shape::Arrow(Pt::new(0.0, 15.0), Pt::new(40.0, 35.0)));
        let s = a.scaled(0.5, 0.5);
        assert_eq!(s.shape, Shape::Arrow(Pt::new(5.0, 5.0), Pt::new(25.0, 15.0)));
        assert_eq!(s.width, 2.0);
    }

    #[test]
    fn text_bounds_follow_font_metrics() {
        let t = ann(Shape::Text { origin: Pt::new(100.0, 100.0), text: "Hello".into(), size: 40.0 });
        let b = t.bounds();
        assert!(b.w > 60.0 && b.h > 40.0);
        assert!(t.hit(Pt::new(120.0, 120.0), 0.0, false));
        assert!(!t.hit(Pt::new(90.0, 90.0), 0.0, false));
    }

    #[test]
    fn arrow_head() {
        let (shaft, tip, left, right) = arrow_geometry(Pt::new(0.0, 0.0), Pt::new(100.0, 0.0), 5.0).unwrap();
        assert_eq!(tip, Pt::new(100.0, 0.0));
        assert!((left.x - 80.0).abs() < 0.01 && (left.y + right.y).abs() < 0.01);
        assert!(shaft.x < 100.0);
        assert!(arrow_geometry(Pt::new(0.0, 0.0), Pt::new(0.2, 0.0), 5.0).is_none());
    }

    #[test]
    fn hex_colors() {
        assert_eq!(Rgba::parse_hex("#FF3B30"), Some(Rgba::rgb(255, 59, 48)));
        assert_eq!(Rgba::parse_hex("nope"), None);
    }
}
