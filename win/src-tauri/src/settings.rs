use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

static SIDECAR_URL: Mutex<Option<String>> = Mutex::new(None);
static PROJECT_ROOT: Mutex<Option<String>> = Mutex::new(None);

fn settings_path() -> Result<PathBuf, String> {
    let base = dirs::data_local_dir().ok_or("Cannot resolve AppData")?;
    let dir = base.join("OCRReview");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("settings.json"))
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct SettingsFile {
    sidecar_url: Option<String>,
    project_root: Option<String>,
}

fn load_settings() -> SettingsFile {
    let path = settings_path().ok();
    if let Some(path) = path {
        if path.exists() {
            if let Ok(raw) = fs::read_to_string(path) {
                if let Ok(s) = serde_json::from_str(&raw) {
                    return s;
                }
            }
        }
    }
    SettingsFile::default()
}

fn save_settings(settings: &SettingsFile) -> Result<(), String> {
    let raw = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    fs::write(settings_path()?, raw).map_err(|e| e.to_string())
}

pub fn default_project_root() -> String {
    if cfg!(windows) {
        if let Ok(user) = std::env::var("USERPROFILE") {
            return format!(r"{user}\markitdown-app");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return format!("{home}/markitdown-app");
    }
    ".".into()
}

#[tauri::command]
pub fn get_sidecar_url() -> Result<String, String> {
    if let Ok(guard) = SIDECAR_URL.lock() {
        if let Some(url) = guard.as_ref() {
            return Ok(url.clone());
        }
    }
    let settings = load_settings();
    Ok(settings
        .sidecar_url
        .unwrap_or_else(|| "http://127.0.0.1:8001".into()))
}

#[tauri::command]
pub fn set_sidecar_url(url: String) -> Result<(), String> {
    if let Ok(mut guard) = SIDECAR_URL.lock() {
        *guard = Some(url.clone());
    }
    let mut settings = load_settings();
    settings.sidecar_url = Some(url);
    save_settings(&settings)
}

#[tauri::command]
pub fn get_project_root() -> Result<String, String> {
    if let Ok(guard) = PROJECT_ROOT.lock() {
        if let Some(root) = guard.as_ref() {
            return Ok(root.clone());
        }
    }
    let settings = load_settings();
    Ok(settings
        .project_root
        .unwrap_or_else(default_project_root))
}

#[tauri::command]
pub fn set_project_root(path: String) -> Result<(), String> {
    if let Ok(mut guard) = PROJECT_ROOT.lock() {
        *guard = Some(path.clone());
    }
    let mut settings = load_settings();
    settings.project_root = Some(path);
    save_settings(&settings)
}

#[tauri::command]
pub fn get_default_engine() -> Result<String, String> {
    Ok(if cfg!(windows) {
        "windows_ocr".into()
    } else {
        "builtin".into()
    })
}
