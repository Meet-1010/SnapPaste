//! Local text recognition with ocrs. The models are compiled into the binary, so recognition
//! works offline and screenshots never leave the computer.

use image::RgbaImage;
use ocrs::{ImageSource, OcrEngine, OcrEngineParams};
use rten::Model;

static DETECTION_MODEL: &[u8] = include_bytes!("../assets/models/text-detection.onnx");
static RECOGNITION_MODEL: &[u8] = include_bytes!("../assets/models/text-recognition.onnx");

pub fn recognize(image: &RgbaImage) -> Result<String, String> {
    let engine = OcrEngine::new(OcrEngineParams {
        detection_model: Some(Model::load_static_slice(DETECTION_MODEL).map_err(|e| e.to_string())?),
        recognition_model: Some(Model::load_static_slice(RECOGNITION_MODEL).map_err(|e| e.to_string())?),
        ..Default::default()
    })
    .map_err(|e| e.to_string())?;

    // Flatten onto white so transparent window corners don't read as dark ink.
    let rgb: Vec<u8> = image
        .pixels()
        .flat_map(|p| {
            let a = p[3] as u32;
            let blend = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
            [blend(p[0]), blend(p[1]), blend(p[2])]
        })
        .collect();
    let source = ImageSource::from_bytes(&rgb, image.dimensions()).map_err(|e| e.to_string())?;
    let input = engine.prepare_input(source).map_err(|e| e.to_string())?;
    let words = engine.detect_words(&input).map_err(|e| e.to_string())?;
    let lines = engine.find_text_lines(&input, &words);
    let texts = engine.recognize_text(&input, &lines).map_err(|e| e.to_string())?;
    let text = texts
        .iter()
        .flatten()
        .map(|line| line.to_string())
        .filter(|line| line.trim().len() > 1)
        .collect::<Vec<_>>()
        .join("\n");
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotate::{Annotation, Pt, Rgba, Shape};

    #[test]
    fn recognizes_rendered_text() {
        let base = RgbaImage::from_pixel(900, 160, image::Rgba([255, 255, 255, 255]));
        let text = Annotation {
            id: 1,
            shape: Shape::Text { origin: Pt::new(30.0, 40.0), text: "Hello SnapPaste".into(), size: 56.0 },
            color: Rgba::rgb(0, 0, 0),
            width: 0.0,
        };
        let image = crate::render::render(&base, &[text]);
        let result = recognize(&image).unwrap();
        assert!(result.contains("Hello"), "recognized: {result:?}");
    }

    #[test]
    fn blank_image_has_no_text() {
        let base = RgbaImage::from_pixel(300, 300, image::Rgba([255, 255, 255, 255]));
        assert_eq!(recognize(&base).unwrap().trim(), "");
    }
}
