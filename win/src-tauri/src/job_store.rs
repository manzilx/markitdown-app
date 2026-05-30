use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OCRBlock {
    pub id: String,
    pub text: String,
    pub confidence: f32,
    pub bbox_normalized: Option<[f64; 4]>,
    #[serde(default)]
    pub original_text: Option<String>,
    #[serde(default)]
    pub is_redacted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OCRPage {
    pub id: String,
    pub page_number: i32,
    pub ocr_text: String,
    pub edited_text: Option<String>,
    pub blocks: Vec<OCRBlock>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OCRDocument {
    pub id: String,
    pub filename: String,
    pub source_path: String,
    pub created_at: String,
    pub pages: Vec<OCRPage>,
    pub engine: String,
    pub total_page_count: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecentJob {
    pub id: String,
    pub filename: String,
    pub source_path: String,
    pub updated_at: String,
}

fn jobs_dir() -> Result<PathBuf, String> {
    let base = dirs::data_local_dir().ok_or("Cannot resolve AppData")?;
    let dir = base.join("OCRReview").join("jobs");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn recents_path() -> Result<PathBuf, String> {
    Ok(jobs_dir()?.join("recents.json"))
}

pub fn list_recents() -> Result<Vec<RecentJob>, String> {
    let path = recents_path()?;
    if !path.exists() {
        return Ok(vec![]);
    }
    let raw = fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&raw).map_err(|e| e.to_string())
}

fn write_recents(recents: &[RecentJob]) -> Result<(), String> {
    let raw = serde_json::to_string_pretty(recents).map_err(|e| e.to_string())?;
    fs::write(recents_path()?, raw).map_err(|e| e.to_string())
}

pub fn load_job(id: &str) -> Result<Option<OCRDocument>, String> {
    let path = jobs_dir()?.join(format!("{id}.json"));
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&raw).map_err(|e| e.to_string()).map(Some)
}

pub fn save_job(document: &OCRDocument) -> Result<(), String> {
    let path = jobs_dir()?.join(format!("{}.json", document.id));
    let raw = serde_json::to_string_pretty(document).map_err(|e| e.to_string())?;
    fs::write(path, raw).map_err(|e| e.to_string())?;

    let mut recents = list_recents().unwrap_or_default();
    recents.retain(|r| r.id != document.id);
    recents.insert(
        0,
        RecentJob {
            id: document.id.clone(),
            filename: document.filename.clone(),
            source_path: document.source_path.clone(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        },
    );
    recents.truncate(20);
    write_recents(&recents)
}

pub fn delete_job(id: &str) -> Result<(), String> {
    let path = jobs_dir()?.join(format!("{id}.json"));
    if path.exists() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    let mut recents = list_recents().unwrap_or_default();
    recents.retain(|r| r.id != id);
    write_recents(&recents)
}
