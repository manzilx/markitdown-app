use crate::settings::{get_project_root, get_sidecar_url};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use tauri::AppHandle;
use tauri_plugin_shell::ShellExt;

static SIDECAR_STARTED: Mutex<bool> = Mutex::new(false);

#[tauri::command]
pub async fn ensure_sidecar(app: AppHandle) -> Result<(), String> {
    let base = get_sidecar_url()?;
    if health_ok(&base) {
        return Ok(());
    }

    let mut started = SIDECAR_STARTED.lock().map_err(|e| e.to_string())?;
    if *started && health_ok(&base) {
        return Ok(());
    }

    // Prefer bundled sidecar (shipped in the installer — no Python/uv on user PC).
    if try_spawn_bundled(&app).is_ok() {
        *started = true;
        if wait_healthy(&base, 30) {
            return Ok(());
        }
    }

    // Dev fallback: uv + project checkout.
    try_spawn_dev_sidecar()?;
    *started = true;

    if wait_healthy(&base, 20) {
        Ok(())
    } else {
        Err(
            "Export engine did not start. Reinstall the app, or restart from Settings.".into(),
        )
    }
}

fn try_spawn_bundled(app: &AppHandle) -> Result<(), String> {
    app.shell()
        .sidecar("ocr-sidecar")
        .map_err(|e| e.to_string())?
        .args(["--port", "8001"])
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn try_spawn_dev_sidecar() -> Result<(), String> {
    let root = get_project_root()?;
    if !std::path::Path::new(&root).exists() {
        return Err(format!(
            "Bundled export engine missing and project root not found: {root}"
        ));
    }

    if cfg!(windows) {
        Command::new("cmd")
            .args([
                "/C",
                &format!(
                    "cd /d \"{root}\" && uv run uvicorn markitdown_api.main:app --host 127.0.0.1 --port 8001 --app-dir api"
                ),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to start sidecar: {e}"))?;
    } else {
        Command::new("sh")
            .arg("-c")
            .arg(format!(
                "cd '{root}' && uv run uvicorn markitdown_api.main:app --host 127.0.0.1 --port 8001 --app-dir api"
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to start sidecar: {e}"))?;
    }
    Ok(())
}

fn wait_healthy(base: &str, attempts: u32) -> bool {
    for _ in 0..attempts {
        if health_ok(base) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    false
}

fn health_ok(base: &str) -> bool {
    let url = format!("{base}/health");
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .and_then(|c| c.get(url).send())
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}
