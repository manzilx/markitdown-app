import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { v4 as uuidv4 } from "uuid";
import type { OCRBlock, OCRDocument, OCRPage } from "./models/ocr";
import ReviewWorkspace from "./components/ReviewWorkspace";
import SettingsModal from "./components/SettingsModal";
import WelcomeView from "./components/WelcomeView";
import { loadJob, listRecents, saveJob, type RecentJob } from "./services/jobStore";
import { pdfPageCount, readSourceBytes, sourceKind } from "./services/rendering";
import { convertDocumentToMarkdown } from "./services/sidecar";

function convertedPage(markdown: string): OCRPage {
  const text = markdown.trim();
  const block: OCRBlock = {
    id: uuidv4(),
    text,
    confidence: 1,
    bboxNormalized: null,
    originalText: text,
    isRedacted: false,
  };
  return {
    id: uuidv4(),
    pageNumber: 1,
    ocrText: text,
    editedText: null,
    blocks: text ? [block] : [],
  };
}

function isPlainTextDocument(path: string): boolean {
  const lower = path.toLowerCase();
  return (
    lower.endsWith(".md") ||
    lower.endsWith(".markdown") ||
    lower.endsWith(".txt") ||
    lower.endsWith(".csv") ||
    lower.endsWith(".json") ||
    lower.endsWith(".xml") ||
    lower.endsWith(".html") ||
    lower.endsWith(".htm")
  );
}

export default function App() {
  const [document, setDocument] = useState<OCRDocument | null>(null);
  const [recents, setRecents] = useState<RecentJob[]>([]);
  const [engine, setEngine] = useState("windows_ocr");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  const refreshRecents = useCallback(async () => {
    try {
      setRecents(await listRecents());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load recent documents");
    }
  }, []);

  useEffect(() => {
    void refreshRecents();
    void invoke<string>("get_default_engine").then(setEngine).catch(() => {});
  }, [refreshRecents]);

  const persist = useCallback(
    async (doc: OCRDocument) => {
      setDocument(doc);
      try {
        await saveJob(doc);
        await refreshRecents();
        setError(null);
      } catch (e) {
        setError(e instanceof Error ? `Save failed: ${e.message}` : "Save failed");
        throw e;
      }
    },
    [refreshRecents]
  );

  const openPath = async (path: string) => {
    try {
      setStatus("Opening document...");
      const info = await invoke<{ pageCount: number; filename: string }>("inspect_document", {
        path,
      });
      const kind = sourceKind(path);
      const pages: OCRPage[] = [];
      let totalPageCount = info.pageCount;
      let documentEngine = engine;

      if (kind === "pdf") {
        totalPageCount = await pdfPageCount(path);
      } else if (kind === "document") {
        setStatus(`Converting ${info.filename}...`);
        const markdown = isPlainTextDocument(path)
          ? new TextDecoder().decode(await readSourceBytes(path))
          : await convertDocumentToMarkdown(path, "builtin");
        pages.push(convertedPage(markdown));
        documentEngine = "builtin";
        totalPageCount = 1;
      }

      const doc: OCRDocument = {
        id: uuidv4(),
        filename: info.filename,
        sourcePath: path,
        createdAt: new Date().toISOString(),
        pages,
        engine: documentEngine,
        totalPageCount,
      };
      await persist(doc);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to open document");
    } finally {
      setStatus(null);
    }
  };

  const openRecent = async (id: string) => {
    try {
      const job = await loadJob(id);
      if (job) {
        setDocument(job);
        setError(null);
      } else {
        setError("Recent document could not be found.");
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to open recent document");
    }
  };

  if (document) {
    return (
      <>
        <ReviewWorkspace
          ocrDocument={document}
          engine={engine}
          onDocumentChange={persist}
          onClose={() => setDocument(null)}
          onOpenSettings={() => setSettingsOpen(true)}
        />
        {error && <div className="app-error">{error}</div>}
        <SettingsModal
          open={settingsOpen}
          engine={engine}
          onEngineChange={setEngine}
          onClose={() => setSettingsOpen(false)}
        />
      </>
    );
  }

  return (
    <>
      <WelcomeView
        recents={recents}
        error={error}
        status={status}
        onOpenPath={openPath}
        onOpenRecent={openRecent}
      />
      <SettingsModal
        open={settingsOpen}
        engine={engine}
        onEngineChange={setEngine}
        onClose={() => setSettingsOpen(false)}
      />
      <button
        type="button"
        className="settings-fab"
        onClick={() => setSettingsOpen(true)}
        title="Settings"
      >
        Settings
      </button>
    </>
  );
}
