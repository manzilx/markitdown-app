import { open } from "@tauri-apps/plugin-dialog";
import type { RecentJob } from "../services/jobStore";

interface Props {
  recents: RecentJob[];
  onOpenPath: (path: string) => void;
  onOpenRecent: (id: string) => void;
}

export default function WelcomeView({ recents, onOpenPath, onOpenRecent }: Props) {
  const pickFile = async () => {
    const selected = await open({
      multiple: false,
      filters: [
        { name: "Documents", extensions: ["pdf", "png", "jpg", "jpeg", "tif", "tiff"] },
      ],
    });
    if (typeof selected === "string") onOpenPath(selected);
  };

  return (
    <div className="welcome" onDragOver={(e) => e.preventDefault()}>
      <div className="welcome-card">
        <h1>OCR Review</h1>
        <p>Adobe-style OCR review for scanned PDFs and images.</p>
        <button type="button" className="primary" onClick={pickFile}>
          Open Document…
        </button>
        <p className="hint">Or drag and drop a PDF or image here</p>
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
