import { invoke } from "@tauri-apps/api/core";
import * as pdfjs from "pdfjs-dist";
import pdfWorker from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjs.GlobalWorkerOptions.workerSrc = pdfWorker;

export type SourceKind = "pdf" | "image" | "unsupported";

export function sourceKind(path: string): SourceKind {
  const lower = path.toLowerCase();
  if (lower.endsWith(".pdf")) return "pdf";
  if (
    lower.endsWith(".png") ||
    lower.endsWith(".jpg") ||
    lower.endsWith(".jpeg") ||
    lower.endsWith(".tif") ||
    lower.endsWith(".tiff")
  ) {
    return "image";
  }
  return "unsupported";
}

export function sourceCanUseBrowserImage(path: string): boolean {
  const lower = path.toLowerCase();
  return lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg");
}

export async function readSourceBytes(path: string): Promise<Uint8Array> {
  const raw = await invoke<number[]>("read_file_bytes", { path });
  return new Uint8Array(raw);
}

export async function pdfPageCount(path: string): Promise<number> {
  const data = await readSourceBytes(path);
  const pdf = await pdfjs.getDocument({ data }).promise;
  return pdf.numPages;
}

export async function renderSourcePageToPngBase64(
  sourcePath: string,
  pageNumber: number,
  scale = 2
): Promise<string> {
  const canvas = window.document.createElement("canvas");
  return renderSourcePageToCanvas(canvas, sourcePath, pageNumber, scale);
}

export async function renderSourcePageToCanvas(
  canvas: HTMLCanvasElement,
  sourcePath: string,
  pageNumber: number,
  scale = 1.5
): Promise<string> {
  const kind = sourceKind(sourcePath);
  if (kind === "pdf") {
    return renderPdfPageToCanvas(canvas, sourcePath, pageNumber, scale);
  }
  if (kind === "image") {
    return renderImageToCanvas(canvas, sourcePath);
  }
  throw new Error("Unsupported document type");
}

async function renderPdfPageToCanvas(
  canvas: HTMLCanvasElement,
  sourcePath: string,
  pageNumber: number,
  scale: number
): Promise<string> {
  const data = await readSourceBytes(sourcePath);
  const pdf = await pdfjs.getDocument({ data }).promise;
  if (pageNumber < 1 || pageNumber > pdf.numPages) {
    throw new Error(`Page ${pageNumber} is outside this ${pdf.numPages}-page PDF`);
  }

  const page = await pdf.getPage(pageNumber);
  const viewport = page.getViewport({ scale });
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Canvas unavailable");
  canvas.width = viewport.width;
  canvas.height = viewport.height;
  await page.render({ canvasContext: ctx, viewport }).promise;
  return canvas.toDataURL("image/png").split(",")[1] ?? "";
}

async function renderImageToCanvas(
  canvas: HTMLCanvasElement,
  sourcePath: string
): Promise<string> {
  if (!sourceCanUseBrowserImage(sourcePath)) {
    throw new Error(
      "TIFF preview and local Windows OCR are not available in this build. Use PDF, PNG, or JPEG, or choose an OCR-capable sidecar engine."
    );
  }

  const data = await readSourceBytes(sourcePath);
  const blob = new Blob([data]);
  const image = await loadImage(blob);
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Canvas unavailable");
  canvas.width = image.naturalWidth;
  canvas.height = image.naturalHeight;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(image, 0, 0);
  return canvas.toDataURL("image/png").split(",")[1] ?? "";
}

function loadImage(blob: Blob): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const image = new Image();
    image.onload = () => {
      URL.revokeObjectURL(url);
      resolve(image);
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Image preview failed"));
    };
    image.src = url;
  });
}
