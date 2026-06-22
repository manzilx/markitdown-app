import { invoke } from "@tauri-apps/api/core";
import type { OCRBlock, OCRDocument, OCRPage, SidecarEngine } from "../models/ocr";
import { pageExportText, pagesForExport } from "../models/ocr";

const DEFAULT_BASE = "http://127.0.0.1:8001";

export async function getSidecarUrl(): Promise<string> {
  try {
    return await invoke<string>("get_sidecar_url");
  } catch {
    return DEFAULT_BASE;
  }
}

export async function setSidecarUrl(url: string): Promise<void> {
  await invoke("set_sidecar_url", { url });
}

export async function getProjectRoot(): Promise<string> {
  return invoke<string>("get_project_root");
}

export async function setProjectRoot(path: string): Promise<void> {
  await invoke("set_project_root", { path });
}

export async function setDefaultEngine(engine: string): Promise<void> {
  await invoke("set_default_engine", { engine });
}

export async function sidecarHealth(): Promise<boolean> {
  const base = await getSidecarUrl();
  try {
    const resp = await fetch(`${base}/health`, { signal: AbortSignal.timeout(2000) });
    return resp.ok;
  } catch {
    return false;
  }
}

export async function ensureSidecar(): Promise<void> {
  await invoke("ensure_sidecar");
  if (!(await sidecarHealth())) {
    throw new Error(
      "Export engine is not running. Open Settings > Restart Sidecar, or reinstall the app."
    );
  }
}

export async function fetchEngines(): Promise<SidecarEngine[]> {
  const base = await getSidecarUrl();
  const resp = await fetch(`${base}/v1/engines`, { signal: AbortSignal.timeout(5000) });
  if (!resp.ok) throw new Error("Failed to load engines");
  const data = (await resp.json()) as {
    engines: (Omit<SidecarEngine, "supportsOcr"> & {
      supportsOcr?: boolean;
      supports_ocr?: boolean;
    })[];
  };
  return data.engines.map((engine) => ({
    ...engine,
    supportsOcr: engine.supportsOcr ?? engine.supports_ocr ?? false,
  }));
}

export async function convertViaSidecar(
  filePath: string,
  engine: string,
  pageNumber: number
): Promise<string> {
  return convertDocumentToMarkdown(filePath, engine, false, pageNumber);
}

export async function convertDocumentToMarkdown(
  filePath: string,
  engine = "builtin",
  embedImages = false,
  pageNumber?: number
): Promise<string> {
  await ensureSidecar();
  const base = await getSidecarUrl();
  const bytes = await invoke<number[]>("read_file_bytes", { path: filePath });
  const blob = new Blob([new Uint8Array(bytes)]);
  const name = filePath.split(/[/\\]/).pop() ?? "page.png";
  const form = new FormData();
  form.append("file", blob, name);
  form.append("engine", engine);
  form.append("embed_images", embedImages ? "true" : "false");
  if (pageNumber != null) {
    form.append("page_number", String(pageNumber));
  }

  const resp = await fetch(`${base}/v1/convert`, {
    method: "POST",
    body: form,
    signal: AbortSignal.timeout(120000),
  });
  const body = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    throw new Error((body as { detail?: string }).detail ?? `Conversion failed (${resp.status})`);
  }
  return (body as { markdown: string }).markdown ?? "";
}

export async function ocrPageImage(
  pngBase64: string,
  engine: string
): Promise<{ ocrText: string; blocks: OCRBlock[] }> {
  return invoke("ocr_page_image", { pngBase64, engine });
}

async function multipartExport(
  endpoint: string,
  sourcePath: string,
  document: OCRDocument,
  extraFields: Record<string, string> = {}
): Promise<Uint8Array> {
  await ensureSidecar();
  const base = await getSidecarUrl();
  const fileBytes = await invoke<number[]>("read_file_bytes", { path: sourcePath });
  const pagesJson = JSON.stringify(pagesForExport(document));
  const boundary = `OCRReview-${crypto.randomUUID()}`;
  const parts: BlobPart[] = [];

  const append = (text: string) => parts.push(text);

  append(`--${boundary}\r\n`);
  append(
    `Content-Disposition: form-data; name="file"; filename="${document.filename}"\r\nContent-Type: application/octet-stream\r\n\r\n`
  );
  parts.push(new Uint8Array(fileBytes));
  append("\r\n");

  append(`--${boundary}\r\nContent-Disposition: form-data; name="pages_json"\r\n\r\n`);
  append(pagesJson);
  append("\r\n");

  for (const [key, value] of Object.entries(extraFields)) {
    append(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n`);
    append(value);
    append("\r\n");
  }

  append(`--${boundary}--\r\n`);

  const resp = await fetch(`${base}${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": `multipart/form-data; boundary=${boundary}` },
    body: new Blob(parts),
    signal: AbortSignal.timeout(300000),
  });
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error((err as { detail?: string }).detail ?? `Export failed (${resp.status})`);
  }
  return new Uint8Array(await resp.arrayBuffer());
}

export async function exportSearchablePdf(
  sourcePath: string,
  document: OCRDocument
): Promise<Uint8Array> {
  return multipartExport("/v1/export/searchable-pdf", sourcePath, document);
}

export async function exportDocx(document: OCRDocument): Promise<Uint8Array> {
  await ensureSidecar();
  const base = await getSidecarUrl();
  const pagesJson = JSON.stringify(pagesForExport(document));
  const boundary = `OCRReview-${crypto.randomUUID()}`;
  const parts: BlobPart[] = [];
  const append = (text: string) => parts.push(text);

  append(`--${boundary}\r\nContent-Disposition: form-data; name="pages_json"\r\n\r\n`);
  append(pagesJson);
  append("\r\n");
  append(`--${boundary}\r\nContent-Disposition: form-data; name="title"\r\n\r\n`);
  append(document.filename.replace(/\.[^.]+$/, ""));
  append("\r\n");
  append(`--${boundary}--\r\n`);

  const resp = await fetch(`${base}/v1/export/docx`, {
    method: "POST",
    headers: { "Content-Type": `multipart/form-data; boundary=${boundary}` },
    body: new Blob(parts),
    signal: AbortSignal.timeout(120000),
  });
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error((err as { detail?: string }).detail ?? `Export failed (${resp.status})`);
  }
  return new Uint8Array(await resp.arrayBuffer());
}

export async function saveBytes(path: string, bytes: Uint8Array): Promise<void> {
  await invoke("write_file_bytes", { path, bytes: Array.from(bytes) });
}

export async function exportMarkdown(document: OCRDocument, path: string): Promise<void> {
  const text = [...document.pages]
    .sort((a, b) => a.pageNumber - b.pageNumber)
    .map((p: OCRPage) => pageExportText(p))
    .join("\n\n---\n\n");
  await invoke("write_text_file", { path, text });
}

export async function exportPlainText(document: OCRDocument, path: string): Promise<void> {
  const text = [...document.pages]
    .sort((a, b) => a.pageNumber - b.pageNumber)
    .map((p: OCRPage) => pageExportText(p))
    .join("\n\n");
  await invoke("write_text_file", { path, text });
}
