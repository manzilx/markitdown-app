import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { v4 as uuidv4 } from "uuid";
import type { OCRDocument } from "./models/ocr";
import ReviewWorkspace from "./components/ReviewWorkspace";
import SettingsModal from "./components/SettingsModal";
import WelcomeView from "./components/WelcomeView";
import { loadJob, listRecents, saveJob, type RecentJob } from "./services/jobStore";

export default function App() {
  const [document, setDocument] = useState<OCRDocument | null>(null);
  const [recents, setRecents] = useState<RecentJob[]>([]);
  const [engine, setEngine] = useState("windows_ocr");
  const [settingsOpen, setSettingsOpen] = useState(false);

  const refreshRecents = useCallback(async () => {
    setRecents(await listRecents());
  }, []);

  useEffect(() => {
    void refreshRecents();
    void invoke<string>("get_default_engine").then(setEngine).catch(() => {});
  }, [refreshRecents]);

  const persist = useCallback(async (doc: OCRDocument) => {
    setDocument(doc);
    await saveJob(doc);
    await refreshRecents();
  }, [refreshRecents]);

  const openPath = async (path: string) => {
    const info = await invoke<{ pageCount: number; filename: string }>("inspect_document", {
      path,
    });
    const doc: OCRDocument = {
      id: uuidv4(),
      filename: info.filename,
      sourcePath: path,
      createdAt: new Date().toISOString(),
      pages: [],
      engine,
      totalPageCount: info.pageCount,
    };
    await persist(doc);
  };

  const openRecent = async (id: string) => {
    const job = await loadJob(id);
    if (job) setDocument(job);
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
      <WelcomeView recents={recents} onOpenPath={openPath} onOpenRecent={openRecent} />
      <SettingsModal
        open={settingsOpen}
        engine={engine}
        onEngineChange={setEngine}
        onClose={() => setSettingsOpen(false)}
      />
      <button type="button" className="settings-fab" onClick={() => setSettingsOpen(true)}>
        ⚙
      </button>
    </>
  );
}
