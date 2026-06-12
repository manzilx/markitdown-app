use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrPageResult {
    pub ocr_text: String,
    pub blocks: Vec<OcrBlockOut>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrBlockOut {
    pub id: String,
    pub text: String,
    pub confidence: f32,
    pub bbox_normalized: Option<[f64; 4]>,
    pub original_text: Option<String>,
    pub is_redacted: bool,
}

#[cfg(windows)]
const LOW_CONFIDENCE: f32 = 0.85;

pub fn ocr_local_png(png_base64: &str) -> Result<OcrPageResult, String> {
    #[cfg(windows)]
    {
        return windows_ocr::recognize(png_base64);
    }
    #[cfg(not(windows))]
    {
        let _ = png_base64;
        Err("Windows OCR is only available on Windows. Choose a sidecar engine.".into())
    }
}

pub fn ocr_via_sidecar_png(png_base64: &str, engine: &str) -> Result<OcrPageResult, String> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let bytes = STANDARD.decode(png_base64).map_err(|e| e.to_string())?;
    let base = crate::settings::get_sidecar_url()?;
    let part = reqwest::blocking::multipart::Part::bytes(bytes)
        .file_name("page.png")
        .mime_str("image/png")
        .map_err(|e| e.to_string())?;
    let form = reqwest::blocking::multipart::Form::new()
        .part("file", part)
        .text("engine", engine.to_string())
        .text("embed_images", "false");

    let url = format!("{base}/v1/convert");
    let resp = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?
        .post(url)
        .multipart(form)
        .send()
        .map_err(|e| e.to_string())?;

    if !resp.status().is_success() {
        return Err(format!("Sidecar OCR failed ({})", resp.status()));
    }

    let body: serde_json::Value = resp.json().map_err(|e| e.to_string())?;
    let markdown = body
        .get("markdown")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    Ok(OcrPageResult {
        ocr_text: markdown.clone(),
        blocks: vec![OcrBlockOut {
            id: Uuid::new_v4().to_string(),
            text: markdown,
            confidence: 1.0,
            bbox_normalized: None,
            original_text: None,
            is_redacted: false,
        }],
    })
}

#[cfg(windows)]
mod windows_ocr {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use windows::Graphics::Imaging::{BitmapDecoder, BitmapPixelFormat, SoftwareBitmap};
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};

    pub fn recognize(png_base64: &str) -> Result<OcrPageResult, String> {
        let bytes = STANDARD.decode(png_base64).map_err(|e| e.to_string())?;
        let bitmap = decode_png(&bytes)?;
        let engine = OcrEngine::TryCreateFromUserProfileLanguages()
            .map_err(|e| format!("OCR engine unavailable: {e}"))?;
        let result = engine
            .RecognizeAsync(&bitmap)
            .map_err(|e| e.to_string())?
            .get()
            .map_err(|e| e.to_string())?;

        let lines = result.Lines().map_err(|e| e.to_string())?;
        let line_count = lines.Size().map_err(|e| e.to_string())? as usize;
        let mut blocks = Vec::new();
        let mut texts = Vec::new();

        for i in 0..line_count {
            let line = lines.GetAt(i as u32).map_err(|e| e.to_string())?;
            let text = line.Text().map_err(|e| e.to_string())?.to_string();
            texts.push(text.clone());

            let words = line.Words().map_err(|e| e.to_string())?;
            let word_count = words.Size().map_err(|e| e.to_string())? as usize;
            if word_count == 0 {
                continue;
            }

            let mut min_x = f64::MAX;
            let mut min_y = f64::MAX;
            let mut max_x = 0.0f64;
            let mut max_y = 0.0f64;
            let mut conf_sum = 0.0f32;
            let mut conf_n = 0u32;

            for w in 0..word_count {
                let word = words.GetAt(w as u32).map_err(|e| e.to_string())?;
                let rect = word.BoundingRect().map_err(|e| e.to_string())?;
                min_x = min_x.min(rect.X as f64);
                min_y = min_y.min(rect.Y as f64);
                max_x = max_x.max((rect.X + rect.Width) as f64);
                max_y = max_y.max((rect.Y + rect.Height) as f64);
                if let Ok(text_len) = word.Text().map(|t| t.len()) {
                    let conf = if text_len > 0 { 0.92 } else { 0.5 };
                    conf_sum += conf;
                    conf_n += 1;
                }
            }

            let width = bitmap.PixelWidth().map_err(|e| e.to_string())? as f64;
            let height = bitmap.PixelHeight().map_err(|e| e.to_string())? as f64;
            let bbox_height = max_y - min_y;
            let bbox = [
                min_x / width,
                1.0 - ((min_y + bbox_height) / height),
                (max_x - min_x) / width,
                bbox_height / height,
            ];
            let confidence = if conf_n > 0 {
                conf_sum / conf_n as f32
            } else {
                LOW_CONFIDENCE
            };

            blocks.push(OcrBlockOut {
                id: Uuid::new_v4().to_string(),
                text,
                confidence,
                bbox_normalized: Some(bbox),
                original_text: None,
                is_redacted: false,
            });
        }

        Ok(OcrPageResult {
            ocr_text: texts.join("\n"),
            blocks,
        })
    }

    fn decode_png(bytes: &[u8]) -> Result<SoftwareBitmap, String> {
        let stream = InMemoryRandomAccessStream::new().map_err(|e| e.to_string())?;
        {
            let writer = DataWriter::CreateOverStream(&stream).map_err(|e| e.to_string())?;
            writer.WriteBytes(bytes).map_err(|e| e.to_string())?;
            writer.StoreAsync().map_err(|e| e.to_string())?.get().map_err(|e| e.to_string())?;
            writer.FlushAsync().map_err(|e| e.to_string())?.get().map_err(|e| e.to_string())?;
        }
        stream.Seek(0).map_err(|e| e.to_string())?;
        let decoder = BitmapDecoder::CreateAsync(&stream)
            .map_err(|e| e.to_string())?
            .get()
            .map_err(|e| e.to_string())?;
        decoder
            .GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8, BitmapPixelFormat::Bgra8)
            .map_err(|e| e.to_string())?
            .get()
            .map_err(|e| e.to_string())
    }
}
