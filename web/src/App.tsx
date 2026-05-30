import { useCallback, useEffect, useRef, useState } from "react";
import Markdown from "react-markdown";
import type { ConvertResponse, EngineInfo, EnginesResponse } from "./types";

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function App() {
  const [engines, setEngines] = useState<EngineInfo[]>([]);
  const [selectedEngine, setSelectedEngine] = useState("builtin");
  const [embedImages, setEmbedImages] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ConvertResponse | null>(null);
  const [tab, setTab] = useState<"preview" | "raw">("preview");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    fetch("/v1/engines")
      .then((r) => {
        if (!r.ok) throw new Error("Failed to load engines");
        return r.json() as Promise<EnginesResponse>;
      })
      .then((data) => {
        setEngines(data.engines);
        setSelectedEngine(data.default_engine);
      })
      .catch(() =>
        setError(
          "Cannot reach the API. Start it in another terminal: cd ~/markitdown-app && make api"
        )
      );
  }, []);

  const pickFile = useCallback((next: File | null) => {
    setFile(next);
    setResult(null);
    setError(null);
  }, []);

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragActive(false);
      const dropped = e.dataTransfer.files[0];
      if (dropped) pickFile(dropped);
    },
    [pickFile]
  );

  const convert = async () => {
    if (!file) return;
    setLoading(true);
    setError(null);
    setResult(null);

    const form = new FormData();
    form.append("file", file);
    form.append("engine", selectedEngine);
    form.append("embed_images", String(embedImages));

    try {
      const resp = await fetch("/v1/convert", { method: "POST", body: form });
      const body = await resp.json().catch(() => ({}));
      if (!resp.ok) {
        throw new Error(body.detail || `Conversion failed (${resp.status})`);
      }
      setResult(body as ConvertResponse);
      setTab("preview");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Conversion failed");
    } finally {
      setLoading(false);
    }
  };

  const copyMarkdown = async () => {
    if (!result?.markdown) return;
    await navigator.clipboard.writeText(result.markdown);
  };

  const downloadMarkdown = () => {
    if (!result?.markdown) return;
    const base = result.filename.replace(/\.[^.]+$/, "") || "document";
    const blob = new Blob([result.markdown], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${base}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="app">
      <header>
        <h1>MarkItDown</h1>
        <p className="subtitle">
          Convert PDF, Word, Excel, PowerPoint, and more to Markdown.
        </p>
      </header>

      {error && <div className="error-banner">{error}</div>}

      <section className="panel">
        <div
          className={`dropzone ${dragActive ? "active" : ""} ${file ? "has-file" : ""}`}
          onDragOver={(e) => {
            e.preventDefault();
            setDragActive(true);
          }}
          onDragLeave={() => setDragActive(false)}
          onDrop={onDrop}
          onClick={() => inputRef.current?.click()}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") inputRef.current?.click();
          }}
        >
          <p>Drop a file here or click to browse</p>
          {file && (
            <div className="file-meta">
              {file.name} · {formatBytes(file.size)}
            </div>
          )}
          <input
            ref={inputRef}
            type="file"
            hidden
            onChange={(e) => pickFile(e.target.files?.[0] ?? null)}
          />
        </div>
      </section>

      <section className="panel">
        <h2 style={{ margin: "0 0 0.75rem", fontSize: "1rem" }}>Conversion engine</h2>
        <div className="engine-list">
          {engines.map((engine) => {
            const disabled = !engine.available;
            return (
              <label
                key={engine.id}
                className={`engine-option ${selectedEngine === engine.id ? "selected" : ""} ${disabled ? "disabled" : ""}`}
                title={disabled ? engine.reason ?? undefined : undefined}
              >
                <input
                  type="radio"
                  name="engine"
                  value={engine.id}
                  checked={selectedEngine === engine.id}
                  disabled={disabled}
                  onChange={() => setSelectedEngine(engine.id)}
                />
                <div>
                  <div className="engine-label">{engine.label}</div>
                  <div className="engine-desc">{engine.description}</div>
                  {engine.badge && (
                    <span className="engine-badge">{engine.badge}</span>
                  )}
                  {disabled && engine.reason && (
                    <div className="engine-reason">{engine.reason}</div>
                  )}
                </div>
              </label>
            );
          })}
        </div>

        {selectedEngine === "pymupdf4llm" && (
          <div className="options-row">
            <label>
              <input
                type="checkbox"
                checked={embedImages}
                onChange={(e) => setEmbedImages(e.target.checked)}
              />
              Embed images in Markdown (base64)
            </label>
          </div>
        )}

        <div className="actions">
          <button
            className="primary"
            disabled={!file || loading}
            onClick={convert}
          >
            {loading ? "Converting…" : "Convert to Markdown"}
          </button>
        </div>
        {loading && <p className="loading">Processing — this may take a moment for large PDFs.</p>}
      </section>

      <section className="panel">
        <div className="tabs">
          <button
            type="button"
            className={`tab ${tab === "preview" ? "active" : ""}`}
            onClick={() => setTab("preview")}
            disabled={!result}
          >
            Preview
          </button>
          <button
            type="button"
            className={`tab ${tab === "raw" ? "active" : ""}`}
            onClick={() => setTab("raw")}
            disabled={!result}
          >
            Raw
          </button>
        </div>

        {!result ? (
          <div className="empty-state">Converted Markdown will appear here.</div>
        ) : (
          <>
            <div className="actions" style={{ marginTop: 0, marginBottom: "0.75rem" }}>
              <button type="button" onClick={copyMarkdown}>
                Copy
              </button>
              <button type="button" onClick={downloadMarkdown}>
                Download .md
              </button>
            </div>
            <div className="result-body">
              {tab === "preview" ? (
                <div className="markdown-preview">
                  <Markdown>{result.markdown}</Markdown>
                </div>
              ) : (
                <pre>{result.markdown}</pre>
              )}
            </div>
          </>
        )}
      </section>
    </div>
  );
}
