mod job_store;
mod ocr;
mod settings;
mod sidecar;

use job_store::{delete_job, list_recents, load_job, save_job};
use settings::{get_default_engine, get_project_root, get_sidecar_url, set_project_root, set_sidecar_url};
use sidecar::ensure_sidecar;

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct DocumentInfo {
    page_count: u32,
    filename: String,
}

#[tauri::command]
fn read_file_bytes(path: String) -> Result<Vec<u8>, String> {
    std::fs::read(&path).map_err(|e| e.to_string())
}

#[tauri::command]
fn write_file_bytes(path: String, bytes: Vec<u8>) -> Result<(), String> {
    std::fs::write(path, bytes).map_err(|e| e.to_string())
}

#[tauri::command]
fn write_text_file(path: String, text: String) -> Result<(), String> {
    std::fs::write(path, text).map_err(|e| e.to_string())
}

#[tauri::command]
fn inspect_document(path: String) -> Result<DocumentInfo, String> {
    let filename = std::path::Path::new(&path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("document")
        .to_string();
    let lower = filename.to_lowercase();
    let page_count = if lower.ends_with(".pdf") {
        pdf_page_count(&path)?
    } else if lower.ends_with(".png")
        || lower.ends_with(".jpg")
        || lower.ends_with(".jpeg")
        || lower.ends_with(".tif")
        || lower.ends_with(".tiff")
    {
        1
    } else {
        return Err("Unsupported file type".into());
    };
    Ok(DocumentInfo {
        page_count,
        filename,
    })
}

fn pdf_page_count(path: &str) -> Result<u32, String> {
    let data = std::fs::read(path).map_err(|e| e.to_string())?;
    let mut count = 0usize;
    let needle = b"/Type";
    for idx in data
        .windows(needle.len())
        .enumerate()
        .filter_map(|(idx, w)| (w == needle).then_some(idx))
    {
        let mut cursor = idx + needle.len();
        while cursor < data.len() && data[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if data.get(cursor..cursor + 5) == Some(b"/Page")
            && data
                .get(cursor + 5)
                .map_or(true, |b| !is_pdf_name_char(*b))
        {
            count += 1;
        }
    }
    if count == 0 {
        count = 1;
    }
    Ok(count.min(10000) as u32)
}

fn is_pdf_name_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.')
}

#[tauri::command]
fn ocr_page_image(png_base64: String, engine: String) -> Result<ocr::OcrPageResult, String> {
    if engine != "windows_ocr" {
        return ocr::ocr_via_sidecar_png(&png_base64, &engine);
    }
    ocr::ocr_local_png(&png_base64)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            read_file_bytes,
            write_file_bytes,
            write_text_file,
            inspect_document,
            ocr_page_image,
            get_sidecar_url,
            set_sidecar_url,
            get_project_root,
            set_project_root,
            get_default_engine,
            ensure_sidecar,
            job_list_recents,
            job_load,
            job_save,
            job_delete,
        ])
        .run(tauri::generate_context!())
        .expect("error while running OCR Review");
}

#[tauri::command]
fn job_list_recents() -> Result<Vec<job_store::RecentJob>, String> {
    list_recents()
}

#[tauri::command]
fn job_load(id: String) -> Result<Option<job_store::OCRDocument>, String> {
    load_job(&id)
}

#[tauri::command]
fn job_save(document: job_store::OCRDocument) -> Result<(), String> {
    save_job(&document)
}

#[tauri::command]
fn job_delete(id: String) -> Result<(), String> {
    delete_job(&id)
}
