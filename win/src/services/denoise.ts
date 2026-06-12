import type { OCRBlock, OCRDocument, OCRPage } from "../models/ocr";
import { pageDisplayText } from "../models/ocr";

export interface DenoiseSummary {
  removedLines: number;
  affectedPages: number;
}

interface DenoiseResult {
  document: OCRDocument;
  summary: DenoiseSummary;
}

export function denoiseDocument(document: OCRDocument): DenoiseResult {
  const pages = [...document.pages].sort((a, b) => a.pageNumber - b.pageNumber);
  if (pages.length < 2) {
    return { document, summary: { removedLines: 0, affectedPages: 0 } };
  }

  const recurringBlockKeys = recurringEdgeBlockKeys(pages);
  const recurringTextKeys = recurringEdgeTextKeys(pages);
  let removedLines = 0;
  let affectedPages = 0;

  const nextPages = document.pages.map((page) => {
    const blockResult = denoiseBlocks(page, recurringBlockKeys, document.totalPageCount);
    const textResult = blockResult.removed > 0
      ? blockTextWithoutNoise(blockResult.blocks)
      : denoiseText(pageDisplayText(page), recurringTextKeys, document.totalPageCount);

    if (blockResult.removed === 0 && textResult.removed === 0) return page;

    removedLines += blockResult.removed + textResult.removed;
    affectedPages += 1;
    return {
      ...page,
      blocks: blockResult.blocks,
      editedText: textResult.text,
    };
  });

  return {
    document: { ...document, pages: nextPages },
    summary: { removedLines, affectedPages },
  };
}

function denoiseBlocks(
  page: OCRPage,
  recurringKeys: Set<string>,
  totalPages: number
): { blocks: OCRBlock[]; removed: number } {
  let removed = 0;
  const blocks = page.blocks.map((block) => {
    if (!isNoisyBlock(block, recurringKeys, totalPages)) return block;
    removed += 1;
    return {
      ...block,
      originalText: block.originalText ?? block.text,
      isRedacted: true,
    };
  });
  return { blocks, removed };
}

function blockTextWithoutNoise(blocks: OCRBlock[]): { text: string; removed: number } {
  const visible = blocks
    .filter((block) => !block.isRedacted)
    .sort((a, b) => (b.bboxNormalized?.[1] ?? 0) - (a.bboxNormalized?.[1] ?? 0))
    .map((block) => block.text.trim())
    .filter(Boolean);
  return { text: visible.join("\n"), removed: 0 };
}

function denoiseText(
  text: string,
  recurringKeys: Set<string>,
  totalPages: number
): { text: string; removed: number } {
  const lines = text.split(/\r?\n/);
  const result: string[] = [];
  let removed = 0;

  lines.forEach((line, index) => {
    const edgeLine = index < 2 || index >= lines.length - 2;
    const normalized = normalizeLine(line);
    const noisy =
      edgeLine &&
      (recurringKeys.has(normalized) || (totalPages > 1 && isPageNumberShape(line)));
    if (noisy) {
      removed += 1;
    } else {
      result.push(line);
    }
  });

  return { text: result.join("\n").trim(), removed };
}

function recurringEdgeBlockKeys(pages: OCRPage[]): Set<string> {
  const pageSets = new Map<string, Set<number>>();
  for (const page of pages) {
    for (const block of page.blocks) {
      if (!blockIsEdge(block)) continue;
      const key = normalizeLine(block.text);
      if (!key) continue;
      if (!pageSets.has(key)) pageSets.set(key, new Set());
      pageSets.get(key)?.add(page.pageNumber);
    }
  }
  return recurringKeys(pageSets, pages.length);
}

function recurringEdgeTextKeys(pages: OCRPage[]): Set<string> {
  const pageSets = new Map<string, Set<number>>();
  for (const page of pages) {
    const lines = pageDisplayText(page).split(/\r?\n/);
    lines.forEach((line, index) => {
      if (index >= 2 && index < lines.length - 2) return;
      const key = normalizeLine(line);
      if (!key) return;
      if (!pageSets.has(key)) pageSets.set(key, new Set());
      pageSets.get(key)?.add(page.pageNumber);
    });
  }
  return recurringKeys(pageSets, pages.length);
}

function recurringKeys(pageSets: Map<string, Set<number>>, pageCount: number): Set<string> {
  const minimum = Math.min(3, Math.max(2, Math.ceil(pageCount * 0.5)));
  const out = new Set<string>();
  for (const [key, pages] of pageSets) {
    if (key.length >= 3 && pages.size >= minimum) out.add(key);
  }
  return out;
}

function isNoisyBlock(block: OCRBlock, recurringKeys: Set<string>, totalPages: number): boolean {
  if (!blockIsEdge(block)) return false;
  const key = normalizeLine(block.text);
  return recurringKeys.has(key) || (totalPages > 1 && isPageNumberShape(block.text));
}

function normalizeLine(text: string): string {
  return text
    .toLowerCase()
    .replace(/\d+/g, "#")
    .replace(/[^\p{L}\p{N}#]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function isPageNumberShape(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed || trimmed.length > 24) return false;
  return [
    /^[\-.()\[\]{}\s]*\d{1,4}[\-.()\[\]{}\s]*$/i,
    /^(page|pg\.?|p\.?)\s*\d{1,4}(\s*(of|\/|-)\s*\d{1,4})?$/i,
    /^\d{1,4}\s*(of|\/)\s*\d{1,4}$/i,
  ].some((pattern) => pattern.test(trimmed));
}

function blockIsEdge(block: OCRBlock): boolean {
  const box = block.bboxNormalized;
  if (!box) return false;
  const minY = box[1];
  const maxY = box[1] + box[3];
  return minY <= 0.14 || maxY >= 0.86;
}
