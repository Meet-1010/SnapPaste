//! Messages between the background process and its UI child processes, sent over stdin/stdout
//! pipes. Images travel as raw RGBA in memory; nothing is written to disk.

use image::RgbaImage;
use std::io::{self, BufRead, Write};

#[derive(Debug, PartialEq)]
pub enum Message {
    /// Region chosen in the picker, in image pixels.
    Region { x: u32, y: u32, w: u32, h: u32 },
    /// Index into the window list given to the picker.
    Window(usize),
    Cancel,
    /// Put this image on the clipboard.
    CopyImage(RgbaImage),
    /// Put this text on the clipboard.
    CopyText(String),
    /// The editor closed; carries the edited image if anything changed.
    Closed(Option<RgbaImage>),
}

pub fn write_image(out: &mut impl Write, image: &RgbaImage) -> io::Result<()> {
    writeln!(out, "IMG {} {}", image.width(), image.height())?;
    out.write_all(image.as_raw())?;
    out.flush()
}

pub fn read_image(input: &mut impl BufRead) -> io::Result<RgbaImage> {
    let line = read_line(input)?;
    let mut parts = line.split_whitespace();
    if parts.next() != Some("IMG") {
        return Err(invalid("expected IMG header"));
    }
    let w: u32 = parse(parts.next())?;
    let h: u32 = parse(parts.next())?;
    crate::annotate::validate_size(w, h).map_err(invalid)?;
    let mut bytes = vec![0u8; w as usize * h as usize * 4];
    input.read_exact(&mut bytes)?;
    RgbaImage::from_raw(w, h, bytes).ok_or_else(|| invalid("bad image data"))
}

pub fn write_message(out: &mut impl Write, message: &Message) -> io::Result<()> {
    match message {
        Message::Region { x, y, w, h } => writeln!(out, "REGION {x} {y} {w} {h}")?,
        Message::Window(i) => writeln!(out, "WINDOW {i}")?,
        Message::Cancel => writeln!(out, "CANCEL")?,
        Message::CopyImage(img) => {
            writeln!(out, "COPY")?;
            write_image(out, img)?;
        }
        Message::CopyText(text) => {
            writeln!(out, "TEXT {}", text.len())?;
            out.write_all(text.as_bytes())?;
        }
        Message::Closed(None) => writeln!(out, "CLOSED")?,
        Message::Closed(Some(img)) => {
            writeln!(out, "CLOSED IMG")?;
            write_image(out, img)?;
        }
    }
    out.flush()
}

/// Reads the next message; `Ok(None)` at end of stream.
pub fn read_message(input: &mut impl BufRead) -> io::Result<Option<Message>> {
    let line = match read_line(input) {
        Ok(line) => line,
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut parts = line.split_whitespace();
    let message = match parts.next() {
        Some("REGION") => Message::Region {
            x: parse(parts.next())?,
            y: parse(parts.next())?,
            w: parse(parts.next())?,
            h: parse(parts.next())?,
        },
        Some("WINDOW") => Message::Window(parse(parts.next())?),
        Some("CANCEL") => Message::Cancel,
        Some("COPY") => Message::CopyImage(read_image(input)?),
        Some("TEXT") => {
            let len: usize = parse(parts.next())?;
            let mut bytes = vec![0u8; len];
            input.read_exact(&mut bytes)?;
            Message::CopyText(String::from_utf8(bytes).map_err(|_| invalid("text is not UTF-8"))?)
        }
        Some("CLOSED") => match parts.next() {
            Some("IMG") => Message::Closed(Some(read_image(input)?)),
            _ => Message::Closed(None),
        },
        other => return Err(invalid(&format!("unknown message {other:?}"))),
    };
    Ok(Some(message))
}

fn read_line(input: &mut impl BufRead) -> io::Result<String> {
    let mut line = String::new();
    if input.read_line(&mut line)? == 0 {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(line.trim_end().to_string())
}

fn parse<T: std::str::FromStr>(part: Option<&str>) -> io::Result<T> {
    part.and_then(|p| p.parse().ok()).ok_or_else(|| invalid("malformed number"))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn messages_round_trip() {
        let mut img = RgbaImage::new(3, 2);
        img.put_pixel(2, 1, image::Rgba([1, 2, 3, 4]));
        let messages = vec![
            Message::Region { x: 1, y: 2, w: 30, h: 40 },
            Message::Window(7),
            Message::Cancel,
            Message::CopyImage(img.clone()),
            Message::CopyText("héllo\nworld".into()),
            Message::Closed(None),
            Message::Closed(Some(img)),
        ];
        let mut buffer = Vec::new();
        for m in &messages {
            write_message(&mut buffer, m).unwrap();
        }
        let mut cursor = Cursor::new(buffer);
        for expected in &messages {
            assert_eq!(read_message(&mut cursor).unwrap().as_ref(), Some(expected));
        }
        assert_eq!(read_message(&mut cursor).unwrap(), None);
    }

    #[test]
    fn rejects_oversized_images() {
        let mut cursor = Cursor::new(b"IMG 20000 20000\n".to_vec());
        assert!(read_image(&mut cursor).is_err());
    }
}
