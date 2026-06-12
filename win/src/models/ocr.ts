export const LOW_CONFIDENCE_THRESHOLD = 0.85;

export interface OCRBlock {
  id: string;
  text: string;
  confidence: number;
  bboxNormalized?: [number, number, number, number] | null;
  originalText?: string;
  isRedacted?: boolean;
}

export interface OCRPage {
  id: string;
  pageNumber: number;
  ocrText: string;
  editedText?: string | null;
  blocks: OCRBlock[];
}

export interface OCRDocument {
  id: string;
  filename: string;
  sourcePath: string;
  createdAt: string;
  pages: OCRPage[];
  engine: string;
  totalPageCount: number;
}

export interface FindMatch {
  pageNumber: number;
  start: number;
  end: number;
  snippet: string;
}

export interface SidecarEngine {
  id: string;
  label: string;
  description: string;
  badge: string;
  available: boolean;
  supportsOcr: boolean;
  reason?: string | null;
}

export function blockPristineText(block: OCRBlock): string {
  return block.originalText ?? block.text;
}

export function blockHasEdits(block: OCRBlock): boolean {
  return block.text !== blockPristineText(block);
}

export function blockIsLowConfidence(block: OCRBlock): boolean {
  return block.confidence < LOW_CONFIDENCE_THRESHOLD;
}

export function pageDisplayText(page: OCRPage): string {
  if (page.editedText && page.editedText.length > 0) return page.editedText;
  return page.ocrText;
}

export function pageExportText(page: OCRPage): string {
  const redacted = page.blocks.filter((b) => b.isRedacted);
  if (redacted.length === 0) return pageDisplayText(page);
  return page.blocks
    .filter((b) => !b.isRedacted)
    .sort((a, b) => (b.bboxNormalized?.[1] ?? 0) - (a.bboxNormalized?.[1] ?? 0))
    .map((b) => b.text)
    .filter(Boolean)
    .join("\n");
}

export function pageIssuesInReadingOrder(page: OCRPage): OCRBlock[] {
  return page.blocks
    .filter(blockIsLowConfidence)
    .sort((a, b) => (b.bboxNormalized?.[1] ?? 0) - (a.bboxNormalized?.[1] ?? 0));
}

export function documentIssueCount(doc: OCRDocument): number {
  return doc.pages.reduce((n, p) => n + p.blocks.filter(blockIsLowConfidence).length, 0);
}

export function documentPage(doc: OCRDocument, number: number): OCRPage | undefined {
  return doc.pages.find((p) => p.pageNumber === number);
}

export function pagesForExport(doc: OCRDocument) {
  return [...doc.pages]
    .sort((a, b) => a.pageNumber - b.pageNumber)
    .map((page) => ({
      page_number: page.pageNumber,
      ocr_text: page.ocrText,
      edited_text: page.editedText ?? null,
      export_text: pageExportText(page),
      blocks: page.blocks.map((b) => ({
        text: b.text,
        confidence: b.confidence,
        bbox_normalized: b.bboxNormalized ?? null,
        is_redacted: b.isRedacted ?? false,
      })),
    }));
}

export function engineLabel(engine: string): string {
  switch (engine) {
    case "windows_ocr":
      return "Windows OCR";
    case "vision":
      return "Apple Vision";
    case "azure_doc_intel":
      return "Azure Document Intelligence";
    case "pymupdf4llm":
      return "PyMuPDF4LLM";
    case "ocr_plugin":
      return "LLM OCR";
    case "builtin":
      return "Built-in";
    default:
      return engine;
  }
}
