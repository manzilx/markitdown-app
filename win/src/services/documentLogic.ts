import type { FindMatch, OCRBlock, OCRDocument, OCRPage } from "../models/ocr";
import {
  blockHasEdits,
  blockIsLowConfidence,
  blockPristineText,
  documentIssueCount,
  documentPage,
  pageDisplayText,
  pageExportText,
  pageIssuesInReadingOrder,
} from "../models/ocr";

export function findMatches(doc: OCRDocument, query: string): FindMatch[] {
  if (!query.trim()) return [];
  const lower = query.toLowerCase();
  const matches: FindMatch[] = [];
  for (const page of doc.pages) {
    const text = pageDisplayText(page);
    const textLower = text.toLowerCase();
    let start = 0;
    while (true) {
      const idx = textLower.indexOf(lower, start);
      if (idx === -1) break;
      matches.push({
        pageNumber: page.pageNumber,
        start: idx,
        end: idx + query.length,
        snippet: text.slice(Math.max(0, idx - 20), idx + query.length + 20),
      });
      start = idx + 1;
    }
  }
  return matches;
}

export function replaceAllPages(doc: OCRDocument, find: string, replace: string): OCRDocument {
  if (!find) return doc;
  const pages = doc.pages.map((page) => {
    const text = pageDisplayText(page);
    const next = text.split(find).join(replace);
    if (next === text) return page;
    return { ...page, editedText: next };
  });
  return { ...doc, pages };
}

export function replaceOnePage(
  doc: OCRDocument,
  pageNumber: number,
  find: string,
  replace: string,
  occurrence: number
): OCRDocument {
  const page = documentPage(doc, pageNumber);
  if (!page || !find) return doc;
  const text = pageDisplayText(page);
  let count = 0;
  let idx = -1;
  let searchFrom = 0;
  while (count <= occurrence) {
    idx = text.indexOf(find, searchFrom);
    if (idx === -1) return doc;
    if (count === occurrence) break;
    searchFrom = idx + find.length;
    count++;
  }
  const next = text.slice(0, idx) + replace + text.slice(idx + find.length);
  return updatePageText(doc, pageNumber, next);
}

export function updatePageText(doc: OCRDocument, pageNumber: number, text: string): OCRDocument {
  const pages = doc.pages.map((p) =>
    p.pageNumber === pageNumber ? { ...p, editedText: text } : p
  );
  return { ...doc, pages };
}

export function updateBlockText(
  doc: OCRDocument,
  pageNumber: number,
  blockId: string,
  text: string
): OCRDocument {
  const pages = doc.pages.map((p) => {
    if (p.pageNumber !== pageNumber) return p;
    const blocks = p.blocks.map((b) => (b.id === blockId ? { ...b, text } : b));
    const sorted = [...blocks].sort(
      (a, b) => (b.bboxNormalized?.[1] ?? 0) - (a.bboxNormalized?.[1] ?? 0)
    );
    return { ...p, blocks, editedText: sorted.map((b) => b.text).join("\n") };
  });
  return { ...doc, pages };
}

export function revertPage(doc: OCRDocument, pageNumber: number): OCRDocument {
  const pages = doc.pages.map((p) => {
    if (p.pageNumber !== pageNumber) return p;
    return {
      ...p,
      editedText: null,
      blocks: p.blocks.map((b) => ({ ...b, text: blockPristineText(b) })),
    };
  });
  return { ...doc, pages };
}

export function revertBlock(doc: OCRDocument, pageNumber: number, blockId: string): OCRDocument {
  const pages = doc.pages.map((p) => {
    if (p.pageNumber !== pageNumber) return p;
    const blocks = p.blocks.map((b) =>
      b.id === blockId ? { ...b, text: blockPristineText(b) } : b
    );
    return { ...p, blocks };
  });
  return { ...doc, pages };
}

export function issueRefs(doc: OCRDocument): { pageNumber: number; blockId: string }[] {
  const refs: { pageNumber: number; blockId: string }[] = [];
  for (const page of [...doc.pages].sort((a, b) => a.pageNumber - b.pageNumber)) {
    for (const block of pageIssuesInReadingOrder(page)) {
      refs.push({ pageNumber: page.pageNumber, blockId: block.id });
    }
  }
  return refs;
}

export function reviewSummary(doc: OCRDocument | null): string {
  if (!doc || doc.pages.length === 0) return "";
  const issues = documentIssueCount(doc);
  return issues === 0 ? "All clear" : `${issues} to review`;
}

export function lowConfidenceBlocks(page: OCRPage | undefined): OCRBlock[] {
  return page?.blocks.filter(blockIsLowConfidence) ?? [];
}

export function pageHasEdits(page: OCRPage | undefined): boolean {
  if (!page) return false;
  return (
    (page.editedText != null && page.editedText !== page.ocrText) ||
    page.blocks.some(blockHasEdits)
  );
}

export function buildMarkdownExport(doc: OCRDocument): string {
  return [...doc.pages]
    .sort((a, b) => a.pageNumber - b.pageNumber)
    .map((p) => pageExportText(p))
    .join("\n\n---\n\n");
}

export function confidenceColor(confidence: number): string {
  if (confidence >= 0.85) return "rgba(34, 197, 94, 0.35)";
  if (confidence >= 0.65) return "rgba(234, 179, 8, 0.45)";
  return "rgba(239, 68, 68, 0.5)";
}
