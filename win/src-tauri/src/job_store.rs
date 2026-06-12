use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

const SNAPSHOT_KEEP_COUNT: usize = 20;
const SNAPSHOT_MAX_BYTES: u64 = 100 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OCRBlock {
    pub id: String,
    pub text: String,
    pub confidence: f32,
    #[serde(alias = "bbox_normalized")]
    pub bbox_normalized: Option<[f64; 4]>,
    #[serde(default)]
    #[serde(alias = "original_text")]
    pub original_text: Option<String>,
    #[serde(default)]
    #[serde(alias = "is_redacted")]
    pub is_redacted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OCRPage {
    pub id: String,
    #[serde(alias = "page_number")]
    pub page_number: i32,
    #[serde(alias = "ocr_text")]
    pub ocr_text: String,
    #[serde(alias = "edited_text")]
    pub edited_text: Option<String>,
    pub blocks: Vec<OCRBlock>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OCRDocument {
    pub id: String,
    pub filename: String,
    #[serde(alias = "source_path")]
    pub source_path: String,
    #[serde(alias = "created_at")]
    pub created_at: String,
    pub pages: Vec<OCRPage>,
    pub engine: String,
    #[serde(alias = "total_page_count")]
    pub total_page_count: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentJob {
    pub id: String,
    pub filename: String,
    #[serde(alias = "source_path")]
    pub source_path: String,
    #[serde(alias = "updated_at")]
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

fn job_path(id: &str) -> Result<PathBuf, String> {
    Ok(jobs_dir()?.join(format!("{id}.json")))
}

fn snapshots_dir(id: &str) -> Result<PathBuf, String> {
    let dir = jobs_dir()?.join(format!("{id}.snapshots"));
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
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
    write_atomic(&recents_path()?, raw.as_bytes())
}

pub fn load_job(id: &str) -> Result<Option<OCRDocument>, String> {
    let path = job_path(id)?;
    if !path.exists() {
        return load_newest_snapshot(id);
    }
    match read_document(&path) {
        Ok(doc) => Ok(Some(doc)),
        Err(_) => load_newest_snapshot(id),
    }
}

pub fn save_job(document: &OCRDocument) -> Result<(), String> {
    let path = job_path(&document.id)?;
    let raw = serde_json::to_string_pretty(document).map_err(|e| e.to_string())?;
    write_snapshot(document, raw.as_bytes())?;
    write_atomic(&path, raw.as_bytes())?;

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
    let path = job_path(id)?;
    if path.exists() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    let snapshots = jobs_dir()?.join(format!("{id}.snapshots"));
    if snapshots.exists() {
        fs::remove_dir_all(snapshots).map_err(|e| e.to_string())?;
    }
    let mut recents = list_recents().unwrap_or_default();
    recents.retain(|r| r.id != id);
    write_recents(&recents)
}

fn read_document(path: &Path) -> Result<OCRDocument, String> {
    let raw = fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&raw).map_err(|e| e.to_string())
}

fn load_newest_snapshot(id: &str) -> Result<Option<OCRDocument>, String> {
    let dir = jobs_dir()?.join(format!("{id}.snapshots"));
    if !dir.exists() {
        return Ok(None);
    }

    let mut snapshots = fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|s| s.to_str()) == Some("json"))
        .collect::<Vec<_>>();
    snapshots.sort();
    snapshots.reverse();

    for snapshot in snapshots {
        if let Ok(doc) = read_document(&snapshot) {
            return Ok(Some(doc));
        }
    }
    Ok(None)
}

fn write_snapshot(document: &OCRDocument, bytes: &[u8]) -> Result<(), String> {
    let dir = snapshots_dir(&document.id)?;
    let name = chrono::Utc::now()
        .format("%Y%m%dT%H%M%S%.3fZ")
        .to_string();
    write_atomic(&dir.join(format!("{name}.json")), bytes)?;
    prune_snapshots(&dir)
}

fn prune_snapshots(dir: &Path) -> Result<(), String> {
    let mut files = fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .map(|entry| {
            let path = entry.path();
            let len = entry.metadata().map(|m| m.len()).unwrap_or(0);
            (path, len)
        })
        .filter(|(path, _)| path.extension().and_then(|s| s.to_str()) == Some("json"))
        .collect::<Vec<_>>();
    files.sort_by(|a, b| a.0.cmp(&b.0));

    let mut total: u64 = files.iter().map(|(_, len)| *len).sum();
    while files.len() > SNAPSHOT_KEEP_COUNT || total > SNAPSHOT_MAX_BYTES {
        if let Some((path, len)) = files.first().cloned() {
            let _ = fs::remove_file(path);
            total = total.saturating_sub(len);
            files.remove(0);
        } else {
            break;
        }
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    if path.exists() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    fs::rename(tmp, path).map_err(|e| e.to_string())
}
