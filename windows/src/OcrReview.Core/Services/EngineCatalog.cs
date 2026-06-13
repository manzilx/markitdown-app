namespace OcrReview.Core.Services;

/// <summary>Display labels for OCR engines. "windows" is the on-device default.</summary>
public static class EngineCatalog
{
    public const string DefaultEngine = "windows";

    public static string Label(string id) => id switch
    {
        "windows" => "Windows OCR · on-device",
        "builtin" => "Built-in · sidecar",
        "azure_doc_intel" => "Azure Document Intelligence",
        "pymupdf4llm" => "PyMuPDF4LLM",
        "ocr_plugin" => "LLM OCR",
        _ => id,
    };

    public static string ShortLabel(string id) => id switch
    {
        "windows" => "Windows OCR",
        "azure_doc_intel" => "Azure",
        "pymupdf4llm" => "PyMuPDF4LLM",
        "ocr_plugin" => "LLM OCR",
        "builtin" => "Built-in",
        _ => "Engine",
    };

    public static bool IsLocal(string id) => id == "windows";

    public static string Description(string id) => id switch
    {
        "windows" => "Windows OCR runs locally — free, private, offline. Best default for review workflows.",
        "azure_doc_intel" => "Azure Document Intelligence for hard scans, tables, and forms. Requires MARKITDOWN_DOCINTEL_* in .env.",
        "pymupdf4llm" => "Fast PDF conversion via PyMuPDF4LLM. Good for text-heavy PDFs.",
        "ocr_plugin" => "LLM vision OCR for embedded images. Requires MARKITDOWN_LLM_* in .env.",
        "builtin" => "MarkItDown built-in converters (pdfplumber, office parsers).",
        _ => "Selected engine runs through the Python sidecar per page.",
    };
}
