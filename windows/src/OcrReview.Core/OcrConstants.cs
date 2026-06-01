namespace OcrReview.Core;

public static class OcrConstants
{
    /// <summary>Blocks below this confidence are flagged for review.</summary>
    public const float LowConfidenceThreshold = 0.85f;

    /// <summary>Confidence assigned to blocks the spellchecker flags (Windows OCR has no native confidence).</summary>
    public const float SuspectConfidence = 0.5f;

    public const string DefaultSidecarBaseUrl = "http://127.0.0.1:8001";
}
