import { open } from "@tauri-apps/plugin-dialog";
import type { RecentJob } from "../services/jobStore";

interface Props {
  recents: RecentJob[];
  error: string | null;
  status: string | null;
  onOpenPath: (path: string) => void;
  onOpenRecent: (id: string) => void;
}

export default function WelcomeView({ recents, error, status, onOpenPath, onOpenRecent }: Props) {
  const pickFile = async () => {
    const selected = await open({
      multiple: false,
      filters: [
        {
          name: "Documents",
          extensions: [
            "pdf",
            "docx",
            "pptx",
            "xlsx",
            "xls",
            "csv",
            "json",
            "xml",
            "html",
            "htm",
            "md",
            "txt",
            "epub",
            "zip",
            "png",
            "jpg",
            "jpeg",
            "tif",
            "tiff",
            "heic",
          ],
        },
      ],
    });
    if (typeof selected === "string") onOpenPath(selected);
  };

  return (
    <div
      className="welcome"
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault();
        const path = e.dataTransfer.files[0]?.path;
        if (path) onOpenPath(path);
      }}
    >
      <div className="welcome-card">
        <h1>OCR Review</h1>
        <p>Review scanned PDFs, images, and converted Word documents in one workspace.</p>
        <button type="button" className="primary" onClick={pickFile} disabled={Boolean(status)}>
          Open Document
        </button>
        <p className="hint">Or drag and drop PDF, Office, data, web, Markdown, text, or image files here</p>
        <div className="format-row" aria-label="Supported file types">
          <span>PDF</span>
          <span>Office</span>
          <span>CSV/JSON</span>
          <span>HTML</span>
          <span>PNG/JPEG</span>
        </div>
        {status && <div className="progress-bar">{status}</div>}
        {error && <div className="error-banner">{error}</div>}
        {recents.length > 0 && (
          <div className="recents">
            <h2>Recent</h2>
            <ul>
              {recents.map((job) => (
                <li key={job.id}>
                  <button type="button" onClick={() => onOpenRecent(job.id)}>
                    {job.filename}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </div>
  );
}
