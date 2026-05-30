import { useCallback, useMemo, useState } from "react";
import { save } from "@tauri-apps/plugin-dialog";
import type { OCRDocument } from "../models/ocr";
import { engineLabel } from "../models/ocr";
import {
  findMatches,
  issueRefs,
  lowConfidenceBlocks,
  pageHasEdits,
  replaceAllPages,
  replaceOnePage,
  revertBlock,
  revertPage,
  reviewSummary,
  updateBlockText,
  updatePageText,
} from "../services/documentLogic";
import {
  exportDocx,
  exportMarkdown,
  exportSearchablePdf,
  ocrPageImage,
  saveBytes,
} from "../services/sidecar";
import FindReplaceBar from "./FindReplaceBar";
import PDFPageView from "./PDFPageView";

interface Props {
  ocrDocument: OCRDocument;
  engine: string;
  onDocumentChange: (doc: OCRDocument) => void;
  onClose: () => void;
  onOpenSettings: () => void;
}

export default function ReviewWorkspace({
  ocrDocument,
  engine,
  onDocumentChange,
  onClose,
  onOpenSettings,
}: Props) {
  const [pageIndex, setPageIndex] = useState(0);
  const [selectedBlockId, setSelectedBlockId] = useState<string | null>(null);
  const [showHeatmap, setShowHeatmap] = useState(false);
  const [isProcessing, setIsProcessing] = useState(false);
  const [progress, setProgress] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isFindVisible, setIsFindVisible] = useState(false);
  const [findText, setFindText] = useState("");
  const [replaceText, setReplaceText] = useState("");
  const [findIndex, setFindIndex] = useState(0);
  const [pageJump, setPageJump] = useState("1");

  const pageNumber = pageIndex + 1;
  const currentPage = ocrDocument.pages.find((p) => p.pageNumber === pageNumber);
  const totalPages = ocrDocument.totalPageCount;
  const ocrCount = ocrDocument.pages.length;

  const matches = useMemo(
    () => findMatches(ocrDocument, findText),
    [ocrDocument, findText]
  );

  const editorText = useMemo(() => {
    if (selectedBlockId && currentPage) {
      return currentPage.blocks.find((b) => b.id === selectedBlockId)?.text ?? "";
    }
    return currentPage?.editedText ?? currentPage?.ocrText ?? "";
  }, [currentPage, selectedBlockId]);

  const setEditorText = (text: string) => {
    if (selectedBlockId) {
      onDocumentChange(updateBlockText(ocrDocument, pageNumber, selectedBlockId, text));
    } else if (currentPage) {
      onDocumentChange(updatePageText(ocrDocument, pageNumber, text));
    }
  };

  const recognizePage = useCallback(
    async (targetPage: number) => {
      if (ocrDocument.pages.some((p) => p.pageNumber === targetPage)) return;
      setIsProcessing(true);
      setProgress(`OCR page ${targetPage}…`);
      setError(null);
      try {
        const canvas = window.document.createElement("canvas");
        const { invoke } = await import("@tauri-apps/api/core");
        const raw = await invoke<number[]>("read_file_bytes", { path: ocrDocument.sourcePath });
        const pdfjs = await import("pdfjs-dist");
        const pdf = await pdfjs.getDocument({ data: new Uint8Array(raw) }).promise;
        const page = await pdf.getPage(targetPage);
        const viewport = page.getViewport({ scale: 2 });
        canvas.width = viewport.width;
        canvas.height = viewport.height;
        const ctx = canvas.getContext("2d");
        if (!ctx) throw new Error("Canvas unavailable");
        await page.render({ canvasContext: ctx, viewport }).promise;
        const pngBase64 = canvas.toDataURL("image/png").split(",")[1];
        const result = await ocrPageImage(pngBase64, engine);
        const newPage = {
          id: crypto.randomUUID(),
          pageNumber: targetPage,
          ocrText: result.ocrText,
          editedText: null,
          blocks: result.blocks,
        };
        onDocumentChange({
          ...ocrDocument,
          engine,
          pages: [...ocrDocument.pages, newPage].sort((a, b) => a.pageNumber - b.pageNumber),
        });
      } catch (e) {
        setError(e instanceof Error ? e.message : "OCR failed");
      } finally {
        setIsProcessing(false);
        setProgress("");
      }
    },
    [ocrDocument, engine, onDocumentChange]
  );

  const ensureCurrentPage = useCallback(async () => {
    if (!currentPage) await recognizePage(pageNumber);
  }, [currentPage, pageNumber, recognizePage]);

  const goToIssue = (direction: 1 | -1) => {
    const refs = issueRefs(ocrDocument);
    if (refs.length === 0) return;
    const currentIdx = refs.findIndex(
      (r) => r.pageNumber === pageNumber && r.blockId === selectedBlockId
    );
    let nextIdx = currentIdx + direction;
    if (nextIdx < 0) nextIdx = refs.length - 1;
    if (nextIdx >= refs.length) nextIdx = 0;
    const ref = refs[nextIdx];
    setPageIndex(ref.pageNumber - 1);
    setSelectedBlockId(ref.blockId);
  };

  const jumpToPage = (n: number) => {
    const clamped = Math.max(1, Math.min(totalPages, n));
    setPageIndex(clamped - 1);
    setPageJump(String(clamped));
    setSelectedBlockId(null);
  };

  const handleExportMd = async () => {
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.[^.]+$/, "") + ".md",
      filters: [{ name: "Markdown", extensions: ["md"] }],
    });
    if (typeof path === "string") {
      await exportMarkdown(ocrDocument, path);
    }
  };

  const handleExportDocx = async () => {
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.[^.]+$/, "") + ".docx",
      filters: [{ name: "Word", extensions: ["docx"] }],
    });
    if (typeof path === "string") {
      setIsProcessing(true);
      try {
        const bytes = await exportDocx(ocrDocument);
        await saveBytes(path, bytes);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Export failed");
      } finally {
        setIsProcessing(false);
      }
    }
  };

  const handleExportSearchable = async () => {
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.pdf$/i, "") + "-searchable.pdf",
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (typeof path === "string") {
      setIsProcessing(true);
      try {
        const bytes = await exportSearchablePdf(ocrDocument.sourcePath, ocrDocument);
        await saveBytes(path, bytes);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Export failed");
      } finally {
        setIsProcessing(false);
      }
    }
  };

  const redactedIds = useMemo(
    () => new Set((currentPage?.blocks ?? []).filter((b) => b.isRedacted).map((b) => b.id)),
    [currentPage]
  );

  return (
    <div className="workspace">
      <header className="toolbar">
        <button type="button" className="ghost" onClick={onClose}>
          ← Back
        </button>
        <div className="title-block">
          <strong>{ocrDocument.filename}</strong>
          <span className="badge">{engineLabel(ocrDocument.engine || engine)}</span>
          {ocrCount > 0 && (
            <span className="muted">
              OCR {ocrCount}/{totalPages} · {reviewSummary(ocrDocument)}
            </span>
          )}
        </div>
        <div className="toolbar-actions">
          <input
            className="page-jump"
            value={pageJump}
            onChange={(e) => setPageJump(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") jumpToPage(parseInt(pageJump, 10) || 1);
            }}
          />
          <button type="button" onClick={() => goToIssue(-1)} title="Previous issue">
            ↑ Issue
          </button>
          <button type="button" onClick={() => goToIssue(1)} title="Next issue">
            ↓ Issue
          </button>
          <button type="button" onClick={() => setShowHeatmap((v) => !v)}>
            Heatmap
          </button>
          <button type="button" onClick={() => setIsFindVisible((v) => !v)}>
            Find
          </button>
          <button type="button" onClick={() => void ensureCurrentPage()}>
            Recognize Page
          </button>
          <div className="menu-group">
            <button type="button" onClick={() => void handleExportMd()}>
              Export MD
            </button>
            <button type="button" onClick={() => void handleExportDocx()}>
              Export Word
            </button>
            <button type="button" onClick={() => void handleExportSearchable()}>
              Searchable PDF
            </button>
          </div>
          <button type="button" className="ghost" onClick={onOpenSettings}>
            Settings
          </button>
        </div>
      </header>

      <FindReplaceBar
        visible={isFindVisible}
        findText={findText}
        replaceText={replaceText}
        matchCount={matches.length}
        matchIndex={findIndex}
        onFindChange={setFindText}
        onReplaceChange={setReplaceText}
        onNext={() => {
          if (matches.length === 0) return;
          const next = (findIndex + 1) % matches.length;
          setFindIndex(next);
          jumpToPage(matches[next].pageNumber);
        }}
        onPrev={() => {
          if (matches.length === 0) return;
          const next = (findIndex - 1 + matches.length) % matches.length;
          setFindIndex(next);
          jumpToPage(matches[next].pageNumber);
        }}
        onReplace={() => {
          if (matches.length === 0) return;
          const m = matches[findIndex];
          onDocumentChange(replaceOnePage(ocrDocument, m.pageNumber, findText, replaceText, 0));
        }}
        onReplaceAll={() => onDocumentChange(replaceAllPages(ocrDocument, findText, replaceText))}
        onClose={() => setIsFindVisible(false)}
      />

      {(progress || isProcessing) && <div className="progress-bar">{progress || "Working…"}</div>}
      {error && <div className="error-banner">{error}</div>}

      <div className="split">
        <PDFPageView
          sourcePath={ocrDocument.sourcePath}
          pageNumber={pageNumber}
          blocks={currentPage?.blocks ?? []}
          selectedBlockId={selectedBlockId}
          showHeatmap={showHeatmap}
          redactedIds={redactedIds}
          onSelectBlock={setSelectedBlockId}
          onPageRendered={() => {
            if (!currentPage) void recognizePage(pageNumber);
          }}
        />
        <aside className="editor-pane">
          <div className="editor-header">
            <span>{selectedBlockId ? "Editing selected region" : "Page text"}</span>
            <div>
              {pageHasEdits(currentPage) && (
                <button
                  type="button"
                  className="ghost"
                  onClick={() =>
                    onDocumentChange(
                      selectedBlockId
                        ? revertBlock(ocrDocument, pageNumber, selectedBlockId)
                        : revertPage(ocrDocument, pageNumber)
                    )
                  }
                >
                  Revert
                </button>
              )}
            </div>
          </div>
          {!currentPage ? (
            <div className="placeholder">
              <p>No OCR for this page yet.</p>
              <button type="button" onClick={() => void recognizePage(pageNumber)}>
                Recognize This Page
              </button>
            </div>
          ) : (
            <>
              {lowConfidenceBlocks(currentPage).length > 0 && (
                <div className="suspects">
                  {lowConfidenceBlocks(currentPage).map((b) => (
                    <button
                      key={b.id}
                      type="button"
                      className="chip warn"
                      onClick={() => setSelectedBlockId(b.id)}
                    >
                      {b.text.slice(0, 24)} ({Math.round(b.confidence * 100)}%)
                    </button>
                  ))}
                </div>
              )}
              <textarea
                value={editorText}
                onChange={(e) => setEditorText(e.target.value)}
                spellCheck
              />
            </>
          )}
        </aside>
      </div>

      <footer className="thumb-strip">
        {Array.from({ length: Math.min(totalPages, 40) }, (_, i) => i + 1).map((n) => {
          const hasOcr = ocrDocument.pages.some((p) => p.pageNumber === n);
          const hasIssues = ocrDocument.pages
            .find((p) => p.pageNumber === n)
            ?.blocks.some((b) => b.confidence < 0.85);
          return (
            <button
              key={n}
              type="button"
              className={`thumb ${pageNumber === n ? "active" : ""} ${hasOcr ? "ocr" : ""} ${hasIssues ? "issue" : ""}`}
              onClick={() => jumpToPage(n)}
            >
              {n}
            </button>
          );
        })}
        {totalPages > 40 && <span className="muted">…{totalPages} pages</span>}
      </footer>
    </div>
  );
}
