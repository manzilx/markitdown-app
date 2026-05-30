import { invoke } from "@tauri-apps/api/core";
import type { OCRDocument } from "../models/ocr";

export interface RecentJob {
  id: string;
  filename: string;
  sourcePath: string;
  updatedAt: string;
}

export async function listRecents(): Promise<RecentJob[]> {
  return invoke<RecentJob[]>("job_list_recents");
}

export async function loadJob(id: string): Promise<OCRDocument | null> {
  return invoke<OCRDocument | null>("job_load", { id });
}

export async function saveJob(document: OCRDocument): Promise<void> {
  await invoke("job_save", { document });
}

export async function deleteJob(id: string): Promise<void> {
  await invoke("job_delete", { id });
}
