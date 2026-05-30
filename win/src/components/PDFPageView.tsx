import { useEffect, useRef, useState } from "react";
import * as pdfjs from "pdfjs-dist";
import pdfWorker from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { OCRBlock } from "../models/ocr";
import { confidenceColor } from "../services/documentLogic";

pdfjs.GlobalWorkerOptions.workerSrc = pdfWorker;

interface Props {
  sourcePath: string | null;
  pageNumber: number;
  blocks: OCRBlock[];
  selectedBlockId: string | null;
  showHeatmap: boolean;
  redactedIds: Set<string>;
  onSelectBlock: (id: string | null) => void;
  onPageRendered?: (pngBase64: string) => void;
}

export default function PDFPageView({
  sourcePath,
  pageNumber,
  blocks,
  selectedBlockId,
  showHeatmap,
  redactedIds,
  onSelectBlock,
  onPageRendered,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const overlayRef = useRef<HTMLDivElement>(null);
  const [pageSize, setPageSize] = useState({ width: 0, height: 0 });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!sourcePath) return;
    let cancelled = false;

    (async () => {
      try {
        setError(null);
        const { invoke } = await import("@tauri-apps/api/core");
        const raw = await invoke<number[]>("read_file_bytes", { path: sourcePath });
        const data = new Uint8Array(raw);

        const pdf = await pdfjs.getDocument({ data }).promise;
        const page = await pdf.getPage(pageNumber);
        const viewport = page.getViewport({ scale: 1.5 });
        const canvas = canvasRef.current;
        if (!canvas || cancelled) return;
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        canvas.width = viewport.width;
        canvas.height = viewport.height;
        setPageSize({ width: viewport.width, height: viewport.height });
        await page.render({ canvasContext: ctx, viewport }).promise;

        if (onPageRendered) {
          const png = canvas.toDataURL("image/png").split(",")[1];
          onPageRendered(png);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Failed to render PDF");
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [sourcePath, pageNumber, onPageRendered]);

  return (
    <div className="pdf-pane">
      {error && <div className="error-banner">{error}</div>}
      <div className="pdf-scroll">
        <div className="pdf-stage" style={{ width: pageSize.width, height: pageSize.height }}>
          <canvas ref={canvasRef} className="pdf-canvas" />
          <div ref={overlayRef} className="bbox-overlay">
            {blocks.map((block) => {
              const bbox = block.bboxNormalized;
              if (!bbox) return null;
              const [minX, minY, w, h] = bbox;
              const left = minX * pageSize.width;
              const top = (1 - minY - h) * pageSize.height;
              const width = w * pageSize.width;
              const height = h * pageSize.height;
              const selected = block.id === selectedBlockId;
              const redacted = redactedIds.has(block.id) || block.isRedacted;
              const bg = showHeatmap
                ? confidenceColor(block.confidence)
                : selected
                  ? "rgba(59, 130, 246, 0.35)"
                  : "transparent";
              return (
                <button
                  key={block.id}
                  type="button"
                  className={`bbox ${selected ? "selected" : ""} ${redacted ? "redacted" : ""}`}
                  style={{ left, top, width, height, background: bg }}
                  onClick={() => onSelectBlock(selected ? null : block.id)}
                  title={`${block.text.slice(0, 40)} (${Math.round(block.confidence * 100)}%)`}
                />
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
