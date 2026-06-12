using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

/// <summary>
/// Detects and removes repeated headers/footers and page numbers from OCR text.
/// Faithful port of the macOS DenoiseService: edge-zone detection, index-independent
/// page-number recurrence, roman-numeral front matter, selective apply, and a
/// never-empty-a-page safety guard.
/// </summary>
public static class DenoiseService
{
    public enum Zone { Top, Bottom }

    public enum Reason { RepeatedEdgeText, PageNumber, Watermark }

    /// <summary>Stable key for the page-number candidate group (all page-number shaped
    /// lines toggle together; repeated header/footer lines each get their normalized key).</summary>
    public const string PageNumberKey = "page-number";

    public sealed class RemovedLine
    {
        public string Text { get; init; } = "";
        public Reason Reason { get; init; }
        public Zone Zone { get; init; }
        public string NormalizedKey { get; init; } = "";
        /// <summary>Index of this line in the page's original (uncleaned) line array.</summary>
        public int OriginalIndex { get; init; }

        public string CandidateKey => Reason == Reason.PageNumber ? PageNumberKey : NormalizedKey;
    }

    public sealed class PageResult
    {
        public int PageNumber { get; init; }
        public string CleanedText { get; init; } = "";
        public IReadOnlyList<RemovedLine> RemovedLines { get; init; } = Array.Empty<RemovedLine>();

        public HashSet<string> RemovedKeys => RemovedLines.Select(r => r.NormalizedKey).ToHashSet();
    }

    public sealed class Candidate
    {
        public string Key { get; init; } = "";
        public string DisplayText { get; init; } = "";
        public IReadOnlySet<int> Pages { get; init; } = new HashSet<int>();
        public Reason Reason { get; init; }
        public IReadOnlyList<string> Samples { get; init; } = Array.Empty<string>();
    }

    public sealed class Plan
    {
        public IReadOnlyDictionary<int, PageResult> PageResults { get; init; } = new Dictionary<int, PageResult>();
        public IReadOnlyList<Candidate> Candidates { get; init; } = Array.Empty<Candidate>();

        public int RemovedLineCount => PageResults.Values.Sum(r => r.RemovedLines.Count);

        public int AffectedPageCount => PageResults.Values.Count(r => r.RemovedLines.Count > 0);

        public HashSet<string> AllCandidateKeys => Candidates.Select(c => c.Key).ToHashSet();

        public int RemovedLineCountFor(IReadOnlySet<string> enabledKeys) =>
            PageResults.Values.Sum(r => r.RemovedLines.Count(l => enabledKeys.Contains(l.CandidateKey)));

        public int AffectedPageCountFor(IReadOnlySet<string> enabledKeys) =>
            PageResults.Values.Count(r => r.RemovedLines.Any(l => enabledKeys.Contains(l.CandidateKey)));

        public string CandidatePreview
        {
            get
            {
                var names = Candidates.Select(c => c.DisplayText).Where(s => !string.IsNullOrEmpty(s)).ToList();
                if (names.Count == 0) return "page numbers and repeated edge text";
                return string.Join(", ", names.Take(5));
            }
        }
    }

    public sealed class ApplicationResult
    {
        public OcrDocument Document { get; init; } = new();
        public Plan Plan { get; init; } = new();
    }

    private sealed class LineInfo
    {
        public int OriginalIndex { get; init; }
        public string Text { get; init; } = "";
        public string Trimmed { get; init; } = "";
        public Zone? Zone { get; init; }
        public string NormalizedKey { get; init; } = "";
    }

    private sealed class CandidateStats
    {
        public List<string> Examples { get; } = new();
        public HashSet<int> Pages { get; } = new();
        public int TopCount;
        public int BottomCount;

        public void Record(LineInfo line, int pageNumber)
        {
            Pages.Add(pageNumber);
            if (line.Trimmed.Length > 0 && Examples.Count < 4) Examples.Add(line.Trimmed);
            switch (line.Zone)
            {
                case Zone.Top: TopCount++; break;
                case Zone.Bottom: BottomCount++; break;
            }
        }

        public double DominantZoneShare
        {
            get
            {
                var total = Math.Max(TopCount + BottomCount, 1);
                return (double)Math.Max(TopCount, BottomCount) / total;
            }
        }

        public string DisplayText =>
            Examples.OrderByDescending(e => Examples.Count(x => x == e)).FirstOrDefault() ?? "";
    }

    public static Plan MakePlan(OcrDocument document)
    {
        var pages = document.Pages.OrderBy(p => p.PageNumber).ToList();
        if (pages.Count == 0) return new Plan();

        var stats = new Dictionary<string, CandidateStats>();
        var watermarkStats = new Dictionary<string, CandidateStats>();
        var pageLines = new Dictionary<int, List<LineInfo>>();
        var pageNumberShapedPages = new HashSet<int>();

        foreach (var page in pages)
        {
            var lines = LineInfos(page.DisplayText);
            pageLines[page.PageNumber] = lines;
            foreach (var line in lines)
            {
                if (line.Trimmed.Length == 0) continue;
                // Watermark stamps (CONFIDENTIAL, DRAFT, COPY …) sit anywhere on the
                // page, so they are tracked independent of the edge zones.
                if (IsWatermarkText(line.Trimmed))
                {
                    if (!watermarkStats.TryGetValue(line.NormalizedKey, out var w)) watermarkStats[line.NormalizedKey] = w = new CandidateStats();
                    w.Record(line, page.PageNumber);
                }
                if (line.Zone is null) continue;
                if (IsRepeatCandidate(line.NormalizedKey))
                {
                    if (!stats.TryGetValue(line.NormalizedKey, out var s)) stats[line.NormalizedKey] = s = new CandidateStats();
                    s.Record(line, page.PageNumber);
                }
                if (IsPageNumberShape(line.Trimmed)) pageNumberShapedPages.Add(page.PageNumber);
            }
        }

        var repeatThreshold = Math.Max(2, (int)Math.Ceiling(pages.Count * 0.35));
        var repeatedKeys = stats
            .Where(kv => kv.Value.Pages.Count >= Math.Min(repeatThreshold, pages.Count) && kv.Value.DominantZoneShare >= 0.65)
            .Select(kv => kv.Key)
            .ToHashSet();

        // Page numbers are noise whenever a page-number-shaped line recurs across pages —
        // regardless of whether the printed value matches the file index (front matter,
        // offsets, and re-numbered scans are common).
        var pageNumberRecurThreshold = Math.Max(2, (int)Math.Ceiling(pages.Count * 0.3));
        var pageNumbersRecur = pageNumberShapedPages.Count >= Math.Min(pageNumberRecurThreshold, pages.Count);

        var watermarkThreshold = Math.Max(2, (int)Math.Ceiling(pages.Count * 0.3));
        var watermarkKeys = watermarkStats
            .Where(kv => kv.Value.Pages.Count >= Math.Min(watermarkThreshold, pages.Count))
            .Select(kv => kv.Key)
            .ToHashSet();

        var candidatesByKey = new Dictionary<string, Candidate>();
        foreach (var key in repeatedKeys)
        {
            var value = stats[key];
            candidatesByKey[key] = new Candidate
            {
                Key = key,
                DisplayText = value.DisplayText,
                Pages = value.Pages.ToHashSet(),
                Reason = Reason.RepeatedEdgeText,
                Samples = value.Examples.ToList(),
            };
        }

        var results = new Dictionary<int, PageResult>();
        foreach (var page in pages)
        {
            var lines = pageLines.GetValueOrDefault(page.PageNumber) ?? new List<LineInfo>();
            var removed = new List<RemovedLine>();
            var keptIndexes = lines.Select(l => l.OriginalIndex).ToHashSet();

            foreach (var line in lines)
            {
                if (line.Trimmed.Length == 0) continue;
                Reason? reason = null;
                // Watermarks are removable anywhere on the page; everything else
                // requires an edge zone.
                if (watermarkKeys.Contains(line.NormalizedKey) && IsWatermarkText(line.Trimmed))
                    reason = Reason.Watermark;
                else if (line.Zone is not null)
                {
                    if (IsExplicitIndexPageNumber(line.Trimmed, page.PageNumber, document.TotalPageCount))
                        reason = Reason.PageNumber;
                    else if (pageNumbersRecur && IsPageNumberShape(line.Trimmed))
                        reason = Reason.PageNumber;
                    else if (repeatedKeys.Contains(line.NormalizedKey))
                        reason = Reason.RepeatedEdgeText;
                }

                if (reason is null) continue;
                keptIndexes.Remove(line.OriginalIndex);
                removed.Add(new RemovedLine
                {
                    Text = line.Trimmed,
                    Reason = reason.Value,
                    Zone = line.Zone ?? Zone.Top,
                    NormalizedKey = line.NormalizedKey,
                    OriginalIndex = line.OriginalIndex,
                });
            }

            if (removed.Count == 0) continue;
            var rawLines = SplitLines(page.DisplayText);
            var cleanedLines = rawLines.Where((_, i) => keptIndexes.Contains(i)).ToList();
            var cleanedText = Compact(cleanedLines);
            // Never reduce a page to nothing: leave an all-edge page untouched. This avoids a
            // blank page and the EditedText == "" -> OcrText fallback in the model.
            if (cleanedText.Trim().Length == 0) continue;
            results[page.PageNumber] = new PageResult
            {
                PageNumber = page.PageNumber,
                CleanedText = cleanedText,
                RemovedLines = removed,
            };
        }

        // Drop repeated-text candidates whose lines were all claimed by the page-number
        // reason (e.g. "Page N" recurs as a normalized key too) — a toggle that removes
        // nothing would be confusing.
        var usedRepeatedKeys = results.Values
            .SelectMany(r => r.RemovedLines.Where(l => l.Reason == Reason.RepeatedEdgeText))
            .Select(l => l.NormalizedKey)
            .ToHashSet();
        candidatesByKey = candidatesByKey.Where(kv => usedRepeatedKeys.Contains(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value);

        // Watermark candidates: one toggle per distinct stamp. They share the key
        // space with repeated-text candidates; the removal loop labels these lines
        // Watermark first, so a stamp never appears as two candidates.
        var usedWatermarkKeys = results.Values
            .SelectMany(r => r.RemovedLines.Where(l => l.Reason == Reason.Watermark))
            .Select(l => l.NormalizedKey)
            .ToHashSet();
        foreach (var key in usedWatermarkKeys)
        {
            if (!watermarkStats.TryGetValue(key, out var w)) continue;
            candidatesByKey[key] = new Candidate
            {
                Key = key,
                DisplayText = w.DisplayText,
                Pages = w.Pages.ToHashSet(),
                Reason = Reason.Watermark,
                Samples = w.Examples.ToList(),
            };
        }

        var pageNumberRemovals = results.Values
            .SelectMany(r => r.RemovedLines.Where(l => l.Reason == Reason.PageNumber))
            .ToList();
        if (pageNumberRemovals.Count > 0)
        {
            candidatesByKey[PageNumberKey] = new Candidate
            {
                Key = PageNumberKey,
                DisplayText = "page numbers",
                Pages = results.Values.Where(r => r.RemovedLines.Any(l => l.Reason == Reason.PageNumber))
                    .Select(r => r.PageNumber).ToHashSet(),
                Reason = Reason.PageNumber,
                Samples = pageNumberRemovals.Take(4).Select(l => l.Text).ToList(),
            };
        }

        return new Plan
        {
            PageResults = results,
            Candidates = candidatesByKey.Values.OrderBy(c => c.DisplayText, StringComparer.Ordinal).ToList(),
        };
    }

    public static ApplicationResult Apply(OcrDocument document)
    {
        var plan = MakePlan(document);
        return Apply(plan, document, plan.AllCandidateKeys);
    }

    /// <summary>Apply only the candidate groups in <paramref name="enabledKeys"/>. Mutates the
    /// given document in place and returns it; snapshot beforehand if you need undo.</summary>
    public static ApplicationResult Apply(Plan plan, OcrDocument document, IReadOnlySet<string> enabledKeys)
    {
        var filtered = FilteredPlan(plan, document, enabledKeys);
        if (filtered.RemovedLineCount == 0)
            return new ApplicationResult { Document = document, Plan = filtered };

        foreach (var page in document.Pages)
        {
            if (!filtered.PageResults.TryGetValue(page.PageNumber, out var result)) continue;
            page.SetDisplayText(result.CleanedText);
            CleanBlocks(page, result.RemovedLines);
        }
        return new ApplicationResult { Document = document, Plan = filtered };
    }

    private static Plan FilteredPlan(Plan plan, OcrDocument document, IReadOnlySet<string> enabledKeys)
    {
        if (enabledKeys.IsSupersetOf(plan.AllCandidateKeys)) return plan;

        var results = new Dictionary<int, PageResult>();
        foreach (var (pageNumber, result) in plan.PageResults)
        {
            var kept = result.RemovedLines.Where(l => enabledKeys.Contains(l.CandidateKey)).ToList();
            if (kept.Count == 0) continue;
            if (document.Page(pageNumber) is not { } page) continue;

            var removedIndexes = kept.Select(l => l.OriginalIndex).ToHashSet();
            var rawLines = SplitLines(page.DisplayText);
            var cleanedLines = rawLines.Where((_, i) => !removedIndexes.Contains(i)).ToList();
            var cleanedText = Compact(cleanedLines);
            if (cleanedText.Trim().Length == 0) continue;
            results[pageNumber] = new PageResult
            {
                PageNumber = pageNumber,
                CleanedText = cleanedText,
                RemovedLines = kept,
            };
        }

        return new Plan
        {
            PageResults = results,
            Candidates = plan.Candidates.Where(c => enabledKeys.Contains(c.Key)).ToList(),
        };
    }

    /// <summary>Clear edge blocks matching a removed line, so redaction/export/block
    /// paths also drop the noise. Repeated-text removals match by normalized key;
    /// page-number removals match by EXACT text — their normalized key is just "#",
    /// which would otherwise blank every numeric edge block (years, totals).</summary>
    private static void CleanBlocks(OcrPage page, IReadOnlyList<RemovedLine> removals)
    {
        if (page.Blocks.Count == 0 || removals.Count == 0) return;
        var repeatedKeys = removals.Where(l => l.Reason == Reason.RepeatedEdgeText)
            .Select(l => l.NormalizedKey).ToHashSet();
        var pageNumberTexts = removals.Where(l => l.Reason == Reason.PageNumber)
            .Select(l => l.Text).ToHashSet(StringComparer.Ordinal);
        var watermarkKeys = removals.Where(l => l.Reason == Reason.Watermark)
            .Select(l => l.NormalizedKey).ToHashSet();
        foreach (var block in page.Blocks)
        {
            var text = block.Text.Trim();
            if (text.Length == 0) continue;
            // Watermark stamps can sit anywhere; edge noise only at the edges.
            if (watermarkKeys.Contains(NormalizedKey(text)) && IsWatermarkText(text))
            {
                block.Text = "";
                continue;
            }
            if (!BlockIsEdge(block)) continue;
            if (repeatedKeys.Contains(NormalizedKey(text)) || pageNumberTexts.Contains(text)) block.Text = "";
        }
    }

    private static List<LineInfo> LineInfos(string text)
    {
        var lines = SplitLines(text);
        var nonEmpty = lines.Select((l, i) => (l, i)).Where(t => t.l.Trim().Length > 0).Select(t => t.i).ToList();
        var edgeLimit = Math.Max(2, Math.Min(4, (int)Math.Ceiling(Math.Max(nonEmpty.Count, 1) * 0.2)));
        var topIndexes = nonEmpty.Take(edgeLimit).ToHashSet();
        var bottomIndexes = nonEmpty.Skip(Math.Max(0, nonEmpty.Count - edgeLimit)).ToHashSet();

        var result = new List<LineInfo>(lines.Count);
        for (var index = 0; index < lines.Count; index++)
        {
            var trimmed = lines[index].Trim();
            Zone? zone = topIndexes.Contains(index) ? Zone.Top : bottomIndexes.Contains(index) ? Zone.Bottom : null;
            result.Add(new LineInfo
            {
                OriginalIndex = index,
                Text = lines[index],
                Trimmed = trimmed,
                Zone = zone,
                NormalizedKey = NormalizedKey(trimmed),
            });
        }
        return result;
    }

    private static List<string> SplitLines(string text) =>
        text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').ToList();

    private static string Compact(List<string> lines)
    {
        var output = new List<string>();
        var previousBlank = true;
        foreach (var line in lines)
        {
            var isBlank = line.Trim().Length == 0;
            if (isBlank)
            {
                if (previousBlank) continue;
                output.Add("");
                previousBlank = true;
            }
            else
            {
                output.Add(line);
                previousBlank = false;
            }
        }
        while (output.Count > 0 && output[^1].Trim().Length == 0) output.RemoveAt(output.Count - 1);
        return string.Join("\n", output);
    }

    private static bool IsRepeatCandidate(string key) =>
        key.Length >= 4 && key.Any(char.IsLetter);

    /// <summary>Month and weekday names (English + French, with common abbreviations)
    /// fold to "#" like digits do, so date-stamped footers ("Printed 12 May 2024" vs
    /// "Printed 13 June 2024") share one normalized key and recur like any header.</summary>
    private static readonly Regex DateWordsRegex = new(
        "\\b(january|february|march|april|may|june|july|august|september|october|november|december|"
        + "jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec|"
        + "monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
        + "janvier|fevrier|mars|avril|mai|juin|juillet|aout|septembre|octobre|novembre|decembre|"
        + "lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static string NormalizedKey(string text)
    {
        var folded = FoldDiacritics(text).ToLowerInvariant();
        folded = DateWordsRegex.Replace(folded, "#");
        folded = Regex.Replace(folded, "\\d+", "#");
        folded = Regex.Replace(folded, "#+", "#");
        var sb = new StringBuilder(folded.Length);
        foreach (var c in folded)
            if (char.IsLetterOrDigit(c) || c == '#') sb.Append(c);
        return sb.ToString().ToLowerInvariant();
    }

    private static string FoldDiacritics(string text)
    {
        var normalized = text.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(normalized.Length);
        foreach (var c in normalized)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString().Normalize(NormalizationForm.FormC);
    }

    /// <summary>High-confidence: the printed value equals the file index (handles small
    /// docs where recurrence can't be established).</summary>
    private static bool IsExplicitIndexPageNumber(string text, int pageNumber, int totalPages)
    {
        var trimmed = text.Trim();
        if (trimmed.Length > 32) return false;
        var p = Regex.Escape(pageNumber.ToString());
        var t = Regex.Escape(totalPages.ToString());
        string[] patterns =
        {
            $"^\\s*[-–—]?\\s*{p}\\s*[-–—]?\\s*$",
            $"^\\s*page\\s+{p}\\s*$",
            $"^\\s*page\\s+{p}\\s+(of|/)\\s+{t}\\s*$",
            $"^\\s*{p}\\s*(/|of)\\s*{t}\\s*$",
        };
        return patterns.Any(pat => Regex.IsMatch(trimmed, pat, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
    }

    /// <summary>The line looks like a page number independent of the file index: a bare or
    /// decorated arabic number, roman numeral (front matter), "Page N", "Page N of M", or
    /// "N / M". Used only when such lines recur across pages.</summary>
    private static bool IsPageNumberShape(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || trimmed.Length > 24) return false;
        string[] patterns =
        {
            "^[\\-–—•·.\\s]*\\d{1,4}[\\-–—•·.\\s]*$",
            "^(page|pg\\.?|p\\.?)\\s*\\d{1,4}(\\s*(of|/|-|–|—)\\s*\\d{1,4})?$",
            "^\\d{1,4}\\s*(of|/)\\s*\\d{1,4}$",
            "^[\\(\\[\\{]\\s*\\d{1,4}(\\s*(of|/|-|–|—)\\s*\\d{1,4})?\\s*[\\)\\]\\}]$",
        };
        if (patterns.Any(pat => Regex.IsMatch(trimmed, pat, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))) return true;
        return IsRomanNumeralPageNumber(trimmed);
    }

    /// <summary>Roman-numeral page numbers (i, iv, xii, …) as used in front matter. The
    /// grammar is strict — a letter-subset check would also match words like "mild" or "dim".</summary>
    private static bool IsRomanNumeralPageNumber(string trimmed)
    {
        var stripped = trimmed.Trim('-', '–', '—', '•', '·', '.', ' ', '\t', '(', ')', '[', ']', '{', '}');
        if (stripped.Length == 0 || stripped.Length > 10) return false;
        const string roman = "^(?=[mdclxvi])m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$";
        return Regex.IsMatch(stripped, roman, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    /// <summary>Whole-line watermark/stamp phrases (English + French). Strict whole-line
    /// matching after stripping decoration — "the copy machine" is body text, "*** COPY ***"
    /// is a stamp. Used only when the stamp recurs across pages (or on 1-page docs).</summary>
    private static readonly HashSet<string> WatermarkPhrases = new(StringComparer.Ordinal)
    {
        "confidential", "strictly confidential", "draft", "copy", "certified copy",
        "true copy", "specimen", "sample", "void", "duplicate", "duplicata", "copie",
        "confidentiel", "brouillon", "do not copy", "not for distribution",
        "internal use only", "for internal use only", "uncontrolled copy",
        "uncontrolled when printed",
    };

    private static bool IsWatermarkText(string trimmed)
    {
        if (trimmed.Length == 0 || trimmed.Length > 40) return false;
        var stripped = trimmed.Trim('-', '–', '—', '•', '·', '*', '#', '_', '~', ' ', '\t', '(', ')', '[', ']', '{', '}');
        if (stripped.Length == 0) return false;
        var folded = Regex.Replace(FoldDiacritics(stripped).ToLowerInvariant(), "\\s+", " ");
        return WatermarkPhrases.Contains(folded);
    }

    private static bool BlockIsEdge(OcrBlock block)
    {
        if (block.BboxNormalized is not { Length: >= 4 } box) return false;
        var minY = box[1];
        var maxY = box[1] + box[3];
        return minY <= 0.14 || maxY >= 0.86;
    }
}
