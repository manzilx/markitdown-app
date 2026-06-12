import { useEffect, useState } from "react";
import {
  ensureSidecar,
  fetchEngines,
  getProjectRoot,
  getSidecarUrl,
  setProjectRoot,
  setSidecarUrl,
  sidecarHealth,
} from "../services/sidecar";
import type { SidecarEngine } from "../models/ocr";

interface Props {
  open: boolean;
  engine: string;
  onEngineChange: (engine: string) => void;
  onClose: () => void;
}

export default function SettingsModal({ open, engine, onEngineChange, onClose }: Props) {
  const [url, setUrl] = useState("http://127.0.0.1:8001");
  const [root, setRoot] = useState("");
  const [healthy, setHealthy] = useState(false);
  const [engines, setEngines] = useState<SidecarEngine[]>([]);
  const [status, setStatus] = useState("");

  useEffect(() => {
    if (!open) return;
    void (async () => {
      setUrl(await getSidecarUrl());
      setRoot(await getProjectRoot());
      setHealthy(await sidecarHealth());
      try {
        const list = await fetchEngines();
        setEngines(list);
      } catch {
        setEngines([]);
      }
    })();
  }, [open]);

  if (!open) return null;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>Settings</h2>
        <label>
          OCR engine
          <select value={engine} onChange={(e) => onEngineChange(e.target.value)}>
            <option value="windows_ocr">Windows OCR (on-device)</option>
            {engines
              .filter((e) => e.supportsOcr)
              .map((e) => (
                <option key={e.id} value={e.id} disabled={!e.available}>
                  {e.label}
                  {e.available ? "" : ` (${e.reason ?? "unavailable"})`}
                </option>
              ))}
          </select>
        </label>
        <label>
          Sidecar URL
          <input value={url} onChange={(e) => setUrl(e.target.value)} />
        </label>
        <label>
          Project root (for auto-start)
          <input value={root} onChange={(e) => setRoot(e.target.value)} />
        </label>
        <p className="muted">Sidecar: {healthy ? "Running" : "Not reachable"}</p>
        {status && <p>{status}</p>}
        <div className="modal-actions">
          <button
            type="button"
            onClick={async () => {
              await setSidecarUrl(url);
              await setProjectRoot(root);
              setStatus("Saved");
              setHealthy(await sidecarHealth());
            }}
          >
            Save
          </button>
          <button
            type="button"
            onClick={async () => {
              setStatus("Starting sidecar...");
              try {
                await ensureSidecar();
                setHealthy(true);
                setStatus("Sidecar running");
              } catch (e) {
                setStatus(e instanceof Error ? e.message : "Failed");
              }
            }}
          >
            Restart Sidecar
          </button>
          <button type="button" className="ghost" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
