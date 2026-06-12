import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { save } from "@tauri-apps/plugin-dialog";
import type { OCRBlock, OCRDocument, OCRPage } from "../models/ocr";
import { engineLabel } from "../models/ocr";
import { denoiseDocument } from "../services/denoise";
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
  convertViaSidecar,
  exportDocx,
  exportMarkdown,
  exportPlainText,
  exportSearchablePdf,
  ocrPageImage,
  saveBytes,
} from "../services/sidecar";
import {
  renderSourcePageToPngBase64,
  sourceCanUseBrowserImage,
  sourceKind,
} from "../services/rendering";
import FindReplaceBar from "./FindReplaceBar";
import PDFPageView from "./PDFPageView";

interface Props {
  ocrDocument: OCRDocument;
  engine: string;
  onDocumentChange: (doc: OCRDocument) => void | Promise<void>;
  onClose: () => void;
  onOpenSettings: () => void;
}

type FailedPages = Record<number, string>;

function upsertPage(document: OCRDocument, page: OCRPage, engine: string): OCRDocument {
  return {
    ...document,
    engine,
    pages: [...document.pages.filter((p) => p.pageNumber !== page.pageNumber), page].sort(
      (a, b) => a.pageNumber - b.pageNumber
    ),
  };
}

function textOnlyPage(markdown: string, pageNumber: number): OCRPage {
  const text = markdown.trim();
  const block: OCRBlock = {
    id: crypto.randomUUID(),
    text,
    confidence: text ? 1 : 0,
    bboxNormalized: null,
    originalText: text,
    isRedacted: false,
  };
  return {
    id: crypto.randomUUID(),
    pageNumber,
    ocrText: text,
    editedText: null,
    blocks: text ? [block] : [],
  };
}

function pageErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "OCR failed";
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
  const [processingPages, setProcessingPages] = useState<Set<number>>(new Set());
  const [failedPages, setFailedPages] = useState<FailedPages>({});
  const [progress, setProgress] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [isFindVisible, setIsFindVisible] = useState(false);
  const [findText, setFindText] = useState("");
  const [replaceText, setReplaceText] = useState("");
  const [findIndex, setFindIndex] = useState(0);
  const [pageJump, setPageJump] = useState("1");

  const documentRef = useRef(ocrDocument);
  const inFlightPagesRef = useRef<Set<number>>(new Set());
  const cancelRequestedRef = useRef(false);

  useEffect(() => {
    documentRef.current = ocrDocument;
  }, [ocrDocument]);

  const pageNumber = pageIndex + 1;
  const currentPage = ocrDocument.pages.find((p) => p.pageNumber === pageNumber);
  const totalPages = Math.max(ocrDocument.totalPageCount, 1);
  const ocrCount = ocrDocument.pages.length;
  const failedCount = Object.keys(failedPages).length;

  useEffect(() => {
    setPageJump(String(pageNumber));
    setSelectedBlockId(null);
  }, [pageNumber]);

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

  const commitDocument = useCallback(
    async (next: OCRDocument) => {
      documentRef.current = next;
      await Promise.resolve(onDocumentChange(next));
    },
    [onDocumentChange]
  );

  const setEditorText = (text: string) => {
    if (selectedBlockId) {
      void commitDocument(updateBlockText(documentRef.current, pageNumber, selectedBlockId, text));
    } else if (currentPage) {
      void commitDocument(updatePageText(documentRef.current, pageNumber, text));
    }
  };

  const recognizePage = useCallback(
    async (
      targetPage: number,
      options: { force?: boolean; pngBase64?: string; keepBusy?: boolean } = {}
    ): Promise<boolean> => {
      const activeDoc = documentRef.current;
      if (!options.force && activeDoc.pages.some((p) => p.pageNumber === targetPage)) {
        return true;
      }
      if (inFlightPagesRef.current.has(targetPage)) return false;

      inFlightPagesRef.current.add(targetPage);
      setProcessingPages((pages) => new Set(pages).add(targetPage));
      setIsProcessing(true);
      setProgress(`OCR page ${targetPage} of ${totalPages}`);
      setError(null);
      setNotice(null);

      try {
        let newPage: OCRPage;
        const kind = sourceKind(activeDoc.sourcePath);
        if (kind === "image" && !sourceCanUseBrowserImage(activeDoc.sourcePath)) {
          if (engine === "windows_ocr") {
            throw new Error(
              "TIFF local OCR is not available. Choose an OCR-capable sidecar engine in Settings, or convert the file to PDF/PNG/JPEG."
            );
          }
          const markdown = await convertViaSidecar(activeDoc.sourcePath, engine, targetPage);
          newPage = textOnlyPage(markdown, targetPage);
        } else {
          const pngBase64 =
            options.pngBase64 ??
            (await renderSourcePageToPngBase64(activeDoc.sourcePath, targetPage));
          const result = await ocrPageImage(pngBase64, engine);
          newPage = {
            id: crypto.randomUUID(),
            pageNumber: targetPage,
            ocrText: result.ocrText,
            editedText: null,
            blocks: result.blocks,
          };
        }

        const next = upsertPage(documentRef.current, newPage, engine);
        await commitDocument(next);
        setFailedPages((pages) => {
          const copy = { ...pages };
          delete copy[targetPage];
          return copy;
        });
        return true;
      } catch (e) {
        const message = pageErrorMessage(e);
        setFailedPages((pages) => ({ ...pages, [targetPage]: message }));
        setError(`Page ${targetPage}: ${message}`);
        return false;
      } finally {
        inFlightPagesRef.current.delete(targetPage);
        setProcessingPages((pages) => {
          const copy = new Set(pages);
          copy.delete(targetPage);
          return copy;
        });
        if (!options.keepBusy) {
          setIsProcessing(false);
          setProgress("");
        }
      }
    },
    [commitDocument, engine, totalPages]
  );

  const ensureCurrentPage = useCallback(async () => {
    if (!currentPage) await recognizePage(pageNumber);
  }, [currentPage, pageNumber, recognizePage]);

  const handlePageRendered = useCallback(
    (pngBase64: string) => {
      const doc = documentRef.current;
      const hasPage = doc.pages.some((p) => p.pageNumber === pageNumber);
      if (!hasPage && !inFlightPagesRef.current.has(pageNumber)) {
        void recognizePage(pageNumber, { pngBase64 });
      }
    },
    [pageNumber, recognizePage]
  );

  const recognizeAllPages = async () => {
    if (isProcessing) return;
    cancelRequestedRef.current = false;
    setIsProcessing(true);
    setError(null);
    setNotice(null);
    let failures = 0;

    try {
      for (let n = 1; n <= totalPages; n += 1) {
        if (cancelRequestedRef.current) break;
        if (documentRef.current.pages.some((p) => p.pageNumber === n)) continue;
        setProgress(`OCR page ${n} of ${totalPages}`);
        const ok = await recognizePage(n, { keepBusy: true });
        if (!ok) failures += 1;
      }

      if (cancelRequestedRef.current) {
        setNotice(
          `OCR cancelled. Preserved ${documentRef.current.pages.length}/${totalPages} pages.`
        );
      } else if (failures > 0) {
        setError(
          `OCR completed with ${failures} failed page${failures === 1 ? "" : "s"}. Successful pages were preserved.`
        );
      } else {
        setNotice(`OCR complete: ${documentRef.current.pages.length}/${totalPages} pages recognized.`);
      }
    } finally {
      cancelRequestedRef.current = false;
      setIsProcessing(false);
      setProgress("");
    }
  };

  const cancelCurrentOperation = () => {
    cancelRequestedRef.current = true;
    setProgress("Cancelling after the current page finishes...");
  };

  const retryFailedPage = async (targetPage: number) => {
    await recognizePage(targetPage, { force: true });
  };

  const handleDenoise = async () => {
    const result = denoiseDocument(documentRef.current);
    if (result.summary.removedLines === 0) {
      setNotice("No recurring headers, footers, or page numbers found.");
      return;
    }
    await commitDocument(result.document);
    setNotice(
      `Denoised ${result.summary.removedLines} line${result.summary.removedLines === 1 ? "" : "s"} across ${result.summary.affectedPages} page${result.summary.affectedPages === 1 ? "" : "s"}.`
    );
    setError(null);
  };

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

  const requireOcrForExport = (): boolean => {
    if (ocrDocument.pages.length > 0) return true;
    setError("Recognize at least one page before exporting.");
    return false;
  };

  const handleExportMd = async () => {
    if (!requireOcrForExport()) return;
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.[^.]+$/, "") + ".md",
      filters: [{ name: "Markdown", extensions: ["md"] }],
    });
    if (typeof path !== "string") return;
    try {
      await exportMarkdown(ocrDocument, path);
      setNotice("Markdown exported.");
    } catch (e) {
      setError(pageErrorMessage(e));
    }
  };

  const handleExportTxt = async () => {
    if (!requireOcrForExport()) return;
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.[^.]+$/, "") + ".txt",
      filters: [{ name: "Text", extensions: ["txt"] }],
    });
    if (typeof path !== "string") return;
    try {
      await exportPlainText(ocrDocument, path);
      setNotice("Text exported.");
    } catch (e) {
      setError(pageErrorMessage(e));
    }
  };

  const handleExportDocx = async () => {
    if (!requireOcrForExport()) return;
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.[^.]+$/, "") + ".docx",
      filters: [{ name: "Word", extensions: ["docx"] }],
    });
    if (typeof path !== "string") return;
    setIsProcessing(true);
    setError(null);
    try {
      const bytes = await exportDocx(ocrDocument);
      await saveBytes(path, bytes);
      setNotice("Word document exported.");
    } catch (e) {
      setError(pageErrorMessage(e));
    } finally {
      setIsProcessing(false);
    }
  };

  const handleExportSearchable = async () => {
    if (!requireOcrForExport()) return;
    if (sourceKind(ocrDocument.sourcePath) !== "pdf") {
      setError("Searchable PDF export requires a PDF source document.");
      return;
    }
    const path = await save({
      defaultPath: ocrDocument.filename.replace(/\.pdf$/i, "") + "-searchable.pdf",
      filters: [{ name: "PDF", extensions: ["pdf"] }],
    });
    if (typeof path !== "string") return;
    setIsProcessing(true);
    setError(null);
    try {
      const bytes = await exportSearchablePdf(ocrDocument.sourcePath, ocrDocument);
      await saveBytes(path, bytes);
      setNotice("Searchable PDF exported.");
    } catch (e) {
      setError(pageErrorMessage(e));
    } finally {
      setIsProcessing(false);
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
          Back
        </button>
        <div className="title-block">
          <strong>{ocrDocument.filename}</strong>
          <span className="badge">{engineLabel(ocrDocument.engine || engine)}</span>
          <span className="muted">
            OCR {ocrCount}/{totalPages} · {reviewSummary(ocrDocument)}
            {failedCount > 0 ? ` · ${failedCount} failed` : ""}
          </span>
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
            Issue Up
          </button>
          <button type="button" onClick={() => goToIssue(1)} title="Next issue">
            Issue Down
          </button>
          <button type="button" onClick={() => setShowHeatmap((v) => !v)}>
            Heatmap
          </button>
          <button type="button" onClick={() => setIsFindVisible((v) => !v)}>
            Find
          </button>
          <button type="button" onClick={() => void ensureCurrentPage()} disabled={isProcessing}>
            Recognize Page
          </button>
          <button type="button" onClick={() => void recognizeAllPages()} disabled={isProcessing}>
            Recognize All
          </button>
          {isProcessing && (
            <button type="button" className="ghost" onClick={cancelCurrentOperation}>
              Cancel
            </button>
          )}
          <button type="button" onClick={() => void handleDenoise()} disabled={ocrCount === 0}>
            Denoise
          </button>
          <div className="menu-group">
            <button type="button" onClick={() => void handleExportTxt()}>
              TXT
            </button>
            <button type="button" onClick={() => void handleExportMd()}>
              MD
            </button>
            <button type="button" onClick={() => void handleExportDocx()}>
              Word
            </button>
            <button type="button" onClick={() => void handleExportSearchable()}>
              PDF
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
          void commitDocument(
            replaceOnePage(documentRef.current, m.pageNumber, findText, replaceText, 0)
          );
        }}
        onReplaceAll={() =>
          void commitDocument(replaceAllPages(documentRef.current, findText, replaceText))
        }
        onClose={() => setIsFindVisible(false)}
      />

      {(progress || isProcessing) && <div className="progress-bar">{progress || "Working..."}</div>}
      {notice && <div className="notice-banner">{notice}</div>}
      {error && <div className="error-banner">{error}</div>}
      {failedCount > 0 && (
        <div className="failed-pages">
          {Object.entries(failedPages)
            .sort(([a], [b]) => Number(a) - Number(b))
            .map(([page, message]) => (
              <button
                key={page}
                type="button"
                className="chip warn"
                title={message}
                onClick={() => void retryFailedPage(Number(page))}
              >
                Retry page {page}
              </button>
            ))}
        </div>
      )}

      <div className="split">
        <PDFPageView
          sourcePath={ocrDocument.sourcePath}
          pageNumber={pageNumber}
          blocks={currentPage?.blocks ?? []}
          selectedBlockId={selectedBlockId}
          showHeatmap={showHeatmap}
          redactedIds={redactedIds}
          onSelectBlock={setSelectedBlockId}
          onPageRendered={handlePageRendered}
        />
        <aside className="editor-pane">
          <div className="editor-header">
            <span>{selectedBlockId ? "Selected region" : `Page ${pageNumber} text`}</span>
            <div>
              {currentPage && (
                <button
                  type="button"
                  className="ghost"
                  onClick={() => void retryFailedPage(pageNumber)}
                >
                  Re-OCR
                </button>
              )}
              {pageHasEdits(currentPage) && (
                <button
                  type="button"
                  className="ghost"
                  onClick={() =>
                    void commitDocument(
                      selectedBlockId
                        ? revertBlock(documentRef.current, pageNumber, selectedBlockId)
                        : revertPage(documentRef.current, pageNumber)
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
              <p>{failedPages[pageNumber] ?? "No OCR for this page yet."}</p>
              <button type="button" onClick={() => void recognizePage(pageNumber, { force: true })}>
                {failedPages[pageNumber] ? "Retry This Page" : "Recognize This Page"}
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
        {Array.from({ length: Math.min(totalPages, 80) }, (_, i) => i + 1).map((n) => {
          const page = ocrDocument.pages.find((p) => p.pageNumber === n);
          const hasOcr = Boolean(page);
          const hasIssues = page?.blocks.some((b) => b.confidence < 0.85);
          const failed = failedPages[n] != null;
          const processing = processingPages.has(n);
          return (
            <button
              key={n}
              type="button"
              className={`thumb ${pageNumber === n ? "active" : ""} ${hasOcr ? "ocr" : ""} ${hasIssues ? "issue" : ""} ${failed ? "failed" : ""} ${processing ? "processing" : ""}`}
              onClick={() => jumpToPage(n)}
              title={failedPages[n] ?? `Page ${n}`}
            >
              {n}
            </button>
          );
        })}
        {totalPages > 80 && <span className="muted">...{totalPages} pages</span>}
      </footer>
    </div>
  );
}
