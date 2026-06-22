import Foundation

enum DenoiseService {
    enum Zone: String {
        case top
        case bottom
    }

    enum Reason: String {
        case repeatedEdgeText
        case pageNumber
        case watermark
    }

    /// Stable key for the page-number candidate group (all page-number shaped lines
    /// toggle together; repeated header/footer lines each get their normalized key).
    static let pageNumberKey = "page-number"

    struct RemovedLine {
        let text: String
        let reason: Reason
        let zone: Zone
        let normalizedKey: String
        /// Index of this line in the page's original (uncleaned) line array.
        let originalIndex: Int

        /// The candidate group this removal belongs to, for selective apply.
        var candidateKey: String {
            reason == .pageNumber ? DenoiseService.pageNumberKey : normalizedKey
        }
    }

    struct PageResult {
        let pageNumber: Int
        let cleanedText: String
        let removedLines: [RemovedLine]

        var removedKeys: Set<String> {
            Set(removedLines.map(\.normalizedKey))
        }
    }

    struct Candidate: Identifiable {
        let key: String
        let displayText: String
        let pages: Set<Int>
        let reason: Reason
        var samples: [String] = []

        var id: String { key }
    }

    struct Plan {
        let pageResults: [Int: PageResult]
        let candidates: [Candidate]

        var removedLineCount: Int {
            pageResults.values.reduce(0) { $0 + $1.removedLines.count }
        }

        var affectedPageCount: Int {
            pageResults.values.filter { !$0.removedLines.isEmpty }.count
        }

        var allCandidateKeys: Set<String> {
            Set(candidates.map(\.key))
        }

        func removedLineCount(enabledKeys: Set<String>) -> Int {
            pageResults.values.reduce(0) { sum, result in
                sum + result.removedLines.filter { enabledKeys.contains($0.candidateKey) }.count
            }
        }

        func affectedPageCount(enabledKeys: Set<String>) -> Int {
            pageResults.values
                .filter { result in result.removedLines.contains { enabledKeys.contains($0.candidateKey) } }
                .count
        }

        var candidatePreview: String {
            let names = candidates.map(\.displayText).filter { !$0.isEmpty }
            guard !names.isEmpty else { return "page numbers and repeated edge text" }
            return names.prefix(5).joined(separator: ", ")
        }
    }

    struct ApplicationResult {
        let document: OCRDocument
        let plan: Plan
    }

    private struct LineInfo {
        let originalIndex: Int
        let text: String
        let trimmed: String
        let zone: Zone?
        let normalizedKey: String
    }

    private struct CandidateStats {
        var examples: [String] = []
        var pages: Set<Int> = []
        var topCount = 0
        var bottomCount = 0

        mutating func record(line: LineInfo, pageNumber: Int) {
            pages.insert(pageNumber)
            if !line.trimmed.isEmpty, examples.count < 4 {
                examples.append(line.trimmed)
            }
            switch line.zone {
            case .top:
                topCount += 1
            case .bottom:
                bottomCount += 1
            case .none:
                break
            }
        }

        var dominantZoneShare: Double {
            let total = max(topCount + bottomCount, 1)
            return Double(max(topCount, bottomCount)) / Double(total)
        }

        var displayText: String {
            examples.max { left, right in
                examples.filter { $0 == left }.count < examples.filter { $0 == right }.count
            } ?? examples.first ?? ""
        }
    }

    static func makePlan(for document: OCRDocument) -> Plan {
        let pages = document.pages.sorted { $0.pageNumber < $1.pageNumber }
        guard !pages.isEmpty else {
            return Plan(pageResults: [:], candidates: [])
        }

        var stats: [String: CandidateStats] = [:]
        var watermarkStats: [String: CandidateStats] = [:]
        var pageLines: [Int: [LineInfo]] = [:]
        var pageNumberShapedPages = Set<Int>()

        for page in pages {
            let lines = lineInfos(for: page.displayText)
            pageLines[page.pageNumber] = lines
            for line in lines where !line.trimmed.isEmpty {
                // Watermark stamps (CONFIDENTIAL, DRAFT, COPY …) sit anywhere on the
                // page, so they are tracked independent of the edge zones.
                if isWatermarkText(line.trimmed) {
                    watermarkStats[line.normalizedKey, default: CandidateStats()].record(line: line, pageNumber: page.pageNumber)
                }
                guard line.zone != nil else { continue }
                if isRepeatCandidate(line.normalizedKey) {
                    stats[line.normalizedKey, default: CandidateStats()].record(line: line, pageNumber: page.pageNumber)
                }
                if isPageNumberShape(line.trimmed) {
                    pageNumberShapedPages.insert(page.pageNumber)
                }
            }
        }

        let repeatThreshold = max(2, Int(ceil(Double(pages.count) * 0.35)))
        let repeatedKeys = Set(stats.compactMap { key, value -> String? in
            guard value.pages.count >= min(repeatThreshold, pages.count),
                  value.dominantZoneShare >= 0.65
            else { return nil }
            return key
        })

        // Page numbers are noise whenever a page-number-shaped line recurs across
        // pages — regardless of whether the printed value matches the file index
        // (front matter, offsets, and re-numbered scans are common).
        let pageNumberRecurThreshold = max(2, Int(ceil(Double(pages.count) * 0.3)))
        let pageNumbersRecur = pageNumberShapedPages.count >= min(pageNumberRecurThreshold, pages.count)

        let watermarkThreshold = max(2, Int(ceil(Double(pages.count) * 0.3)))
        let watermarkKeys = Set(watermarkStats.compactMap { key, value -> String? in
            value.pages.count >= min(watermarkThreshold, pages.count) ? key : nil
        })

        var candidatesByKey: [String: Candidate] = [:]
        for key in repeatedKeys {
            guard let value = stats[key] else { continue }
            candidatesByKey[key] = Candidate(
                key: key,
                displayText: value.displayText,
                pages: value.pages,
                reason: .repeatedEdgeText,
                samples: value.examples
            )
        }

        var results: [Int: PageResult] = [:]
        for page in pages {
            let lines = pageLines[page.pageNumber] ?? []
            var removed: [RemovedLine] = []
            var keptIndexes = Set(lines.map(\.originalIndex))

            for line in lines {
                guard !line.trimmed.isEmpty else { continue }
                var reason: Reason?
                // Watermarks are removable anywhere on the page; everything else
                // requires an edge zone.
                if watermarkKeys.contains(line.normalizedKey), isWatermarkText(line.trimmed) {
                    reason = .watermark
                } else if line.zone != nil {
                    if isExplicitIndexPageNumber(line.trimmed, pageNumber: page.pageNumber, totalPages: document.totalPageCount) {
                        reason = .pageNumber
                    } else if pageNumbersRecur && isPageNumberShape(line.trimmed) {
                        reason = .pageNumber
                    } else if repeatedKeys.contains(line.normalizedKey) {
                        reason = .repeatedEdgeText
                    }
                }

                guard let reason else { continue }
                keptIndexes.remove(line.originalIndex)
                removed.append(
                    RemovedLine(
                        text: line.trimmed,
                        reason: reason,
                        zone: line.zone ?? .top,
                        normalizedKey: line.normalizedKey,
                        originalIndex: line.originalIndex
                    )
                )
            }

            guard !removed.isEmpty else { continue }
            let rawLines = splitLines(page.displayText)
            let cleanedLines = rawLines.enumerated()
                .filter { keptIndexes.contains($0.offset) }
                .map(\.element)
            let cleanedText = compact(lines: cleanedLines)
            // Never reduce a page to nothing: leave an all-edge page untouched. This
            // avoids a blank page and the editedText == "" → ocrText fallback in the model.
            guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            results[page.pageNumber] = PageResult(
                pageNumber: page.pageNumber,
                cleanedText: cleanedText,
                removedLines: removed
            )
        }

        // Drop repeated-text candidates whose lines were all claimed by the page-number
        // reason (e.g. "Page N" recurs as a normalized key too) — a toggle that removes
        // nothing would be confusing in the preview.
        let usedRepeatedKeys = Set(
            results.values.flatMap { $0.removedLines.filter { $0.reason == .repeatedEdgeText } }
                .map(\.normalizedKey)
        )
        candidatesByKey = candidatesByKey.filter { usedRepeatedKeys.contains($0.key) }

        // Watermark candidates: one toggle per distinct stamp. They share the key
        // space with repeated-text candidates; the removal loop labels these lines
        // watermark first, so a stamp never appears as two candidates.
        let usedWatermarkKeys = Set(
            results.values.flatMap { $0.removedLines.filter { $0.reason == .watermark } }
                .map(\.normalizedKey)
        )
        for key in usedWatermarkKeys {
            guard let value = watermarkStats[key] else { continue }
            candidatesByKey[key] = Candidate(
                key: key,
                displayText: value.displayText,
                pages: value.pages,
                reason: .watermark,
                samples: value.examples
            )
        }

        let pageNumberRemovals = results.values.flatMap { $0.removedLines.filter { $0.reason == .pageNumber } }
        if !pageNumberRemovals.isEmpty {
            candidatesByKey[pageNumberKey] = Candidate(
                key: pageNumberKey,
                displayText: "page numbers",
                pages: Set(results.values
                    .filter { $0.removedLines.contains { $0.reason == .pageNumber } }
                    .map(\.pageNumber)),
                reason: .pageNumber,
                samples: Array(pageNumberRemovals.prefix(4).map(\.text))
            )
        }

        return Plan(
            pageResults: results,
            candidates: Array(candidatesByKey.values).sorted { $0.displayText < $1.displayText }
        )
    }

    static func apply(to document: OCRDocument) -> ApplicationResult {
        let plan = makePlan(for: document)
        return apply(plan: plan, to: document, enabledKeys: plan.allCandidateKeys)
    }

    /// Apply only the candidate groups in `enabledKeys` (the preview sheet lets the user
    /// keep e.g. a footer while still stripping page numbers). The filtered plan rebuilds
    /// each page's text from its original lines minus the enabled removals.
    static func apply(plan: Plan, to document: OCRDocument, enabledKeys: Set<String>) -> ApplicationResult {
        let filtered = filteredPlan(plan, for: document, enabledKeys: enabledKeys)
        guard filtered.removedLineCount > 0 else {
            return ApplicationResult(document: document, plan: filtered)
        }

        var cleaned = document
        for pageIndex in cleaned.pages.indices {
            let pageNumber = cleaned.pages[pageIndex].pageNumber
            guard let result = filtered.pageResults[pageNumber] else { continue }
            cleaned.pages[pageIndex].setDisplayText(result.cleanedText)
            cleanBlocks(in: &cleaned.pages[pageIndex], removals: result.removedLines)
        }
        return ApplicationResult(document: cleaned, plan: filtered)
    }

    private static func filteredPlan(_ plan: Plan, for document: OCRDocument, enabledKeys: Set<String>) -> Plan {
        if enabledKeys.isSuperset(of: plan.allCandidateKeys) {
            return plan
        }

        var results: [Int: PageResult] = [:]
        for (pageNumber, result) in plan.pageResults {
            let kept = result.removedLines.filter { enabledKeys.contains($0.candidateKey) }
            guard !kept.isEmpty, let page = document.page(number: pageNumber) else { continue }

            let removedIndexes = Set(kept.map(\.originalIndex))
            let rawLines = splitLines(page.displayText)
            let cleanedLines = rawLines.enumerated()
                .filter { !removedIndexes.contains($0.offset) }
                .map(\.element)
            let cleanedText = compact(lines: cleanedLines)
            guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            results[pageNumber] = PageResult(
                pageNumber: pageNumber,
                cleanedText: cleanedText,
                removedLines: kept
            )
        }

        return Plan(
            pageResults: results,
            candidates: plan.candidates.filter { enabledKeys.contains($0.key) }
        )
    }

    /// Clear edge blocks matching a line we removed, so redaction/export/block paths
    /// also drop the noise. Repeated-text removals match by normalized key; page-number
    /// removals match by EXACT text — their normalized key is just "#", which would
    /// otherwise blank every numeric edge block (years, totals) on the page.
    private static func cleanBlocks(in page: inout OCRPage, removals: [RemovedLine]) {
        guard !page.blocks.isEmpty, !removals.isEmpty else { return }
        let repeatedKeys = Set(removals.filter { $0.reason == .repeatedEdgeText }.map(\.normalizedKey))
        let pageNumberTexts = Set(removals.filter { $0.reason == .pageNumber }.map(\.text))
        let watermarkKeys = Set(removals.filter { $0.reason == .watermark }.map(\.normalizedKey))
        for index in page.blocks.indices {
            let text = page.blocks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Watermark stamps can sit anywhere; edge noise only at the edges.
            if watermarkKeys.contains(normalizedKey(for: text)), isWatermarkText(text) {
                page.blocks[index].text = ""
                continue
            }
            guard blockIsEdge(page.blocks[index]) else { continue }
            if repeatedKeys.contains(normalizedKey(for: text)) || pageNumberTexts.contains(text) {
                page.blocks[index].text = ""
            }
        }
    }

    private static func lineInfos(for text: String) -> [LineInfo] {
        let lines = splitLines(text)
        let nonEmpty = lines.enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.offset)
        let edgeLimit = max(2, min(4, Int(ceil(Double(max(nonEmpty.count, 1)) * 0.2))))
        let topIndexes = Set(nonEmpty.prefix(edgeLimit))
        let bottomIndexes = Set(nonEmpty.suffix(edgeLimit))

        return lines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let zone: Zone?
            if topIndexes.contains(index) {
                zone = .top
            } else if bottomIndexes.contains(index) {
                zone = .bottom
            } else {
                zone = nil
            }
            return LineInfo(
                originalIndex: index,
                text: line,
                trimmed: trimmed,
                zone: zone,
                normalizedKey: normalizedKey(for: trimmed)
            )
        }
    }

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func compact(lines: [String]) -> String {
        var output: [String] = []
        var previousBlank = true
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                guard !previousBlank else { continue }
                output.append("")
                previousBlank = true
            } else {
                output.append(line)
                previousBlank = false
            }
        }
        while output.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    private static func isRepeatCandidate(_ key: String) -> Bool {
        guard key.count >= 4 else { return false }
        return key.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Month and weekday names (English + French, with common abbreviations) fold to
    /// "#" like digits do, so date-stamped footers ("Printed 12 May 2024" vs
    /// "Printed 13 June 2024") share one normalized key and recur like any header.
    private static let dateWordsPattern =
        "\\b(january|february|march|april|may|june|july|august|september|october|november|december|"
        + "jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec|"
        + "monday|tuesday|wednesday|thursday|friday|saturday|sunday|"
        + "janvier|fevrier|mars|avril|mai|juin|juillet|aout|septembre|octobre|novembre|decembre|"
        + "lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\\b"

    private static func normalizedKey(for text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: dateWordsPattern, with: "#", options: .regularExpression)
            .replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
            .replacingOccurrences(of: "#+", with: "#", options: .regularExpression)

        let hash = UnicodeScalar("#")
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == hash
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    /// High-confidence: the line is a page number whose printed value equals the file
    /// index (handles small docs where recurrence can't be established).
    private static func isExplicitIndexPageNumber(_ text: String, pageNumber: Int, totalPages: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 32 else { return false }
        let escapedPage = NSRegularExpression.escapedPattern(for: "\(pageNumber)")
        let escapedTotal = NSRegularExpression.escapedPattern(for: "\(totalPages)")
        let patterns = [
            "^\\s*[-–—]?\\s*\(escapedPage)\\s*[-–—]?\\s*$",
            "^\\s*page\\s+\(escapedPage)\\s*$",
            "^\\s*page\\s+\(escapedPage)\\s+(of|/)\\s+\(escapedTotal)\\s*$",
            "^\\s*\(escapedPage)\\s*(/|of)\\s*\(escapedTotal)\\s*$",
        ]
        return patterns.contains {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The line *looks like* a page number, independent of the file index: a bare or
    /// decorated arabic number, roman numeral (front matter), "Page N", "Page N of M",
    /// or "N / M". Used only when such lines recur across pages, so a lone edge number
    /// is left alone.
    private static func isPageNumberShape(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
        let patterns = [
            "^[\\-–—•·.\\s]*\\d{1,4}[\\-–—•·.\\s]*$",
            "^(page|pg\\.?|p\\.?)\\s*\\d{1,4}(\\s*(of|/|-|–|—)\\s*\\d{1,4})?$",
            "^\\d{1,4}\\s*(of|/)\\s*\\d{1,4}$",
            "^[\\(\\[\\{]\\s*\\d{1,4}(\\s*(of|/|-|–|—)\\s*\\d{1,4})?\\s*[\\)\\]\\}]$",
        ]
        if patterns.contains(where: {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return true
        }
        return isRomanNumeralPageNumber(trimmed)
    }

    /// Roman-numeral page numbers (i, iv, xii, …) as used in front matter. The grammar
    /// is strict — letter-subset checks would also match words like "mild" or "dim".
    private static func isRomanNumeralPageNumber(_ trimmed: String) -> Bool {
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-–—•·. \t()[]{}"))
        guard !stripped.isEmpty, stripped.count <= 10 else { return false }
        let roman = "^(?=[mdclxvi])m{0,3}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$"
        return stripped.range(of: roman, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whole-line watermark/stamp phrases (English + French). Strict whole-line
    /// matching after stripping decoration — "the copy machine" is body text,
    /// "*** COPY ***" is a stamp. Used only when the stamp recurs across pages
    /// (or on 1-page docs).
    private static let watermarkPhrases: Set<String> = [
        "confidential", "strictly confidential", "draft", "copy", "certified copy",
        "true copy", "specimen", "sample", "void", "duplicate", "duplicata", "copie",
        "confidentiel", "brouillon", "do not copy", "not for distribution",
        "internal use only", "for internal use only", "uncontrolled copy",
        "uncontrolled when printed",
    ]

    private static func isWatermarkText(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-–—•·*#_~ \t()[]{}"))
        guard !stripped.isEmpty else { return false }
        let folded = stripped
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return watermarkPhrases.contains(folded)
    }

    private static func blockIsEdge(_ block: OCRBlock) -> Bool {
        guard let box = block.bboxNormalized, box.count >= 4 else { return false }
        let minY = box[1]
        let maxY = box[1] + box[3]
        return minY <= 0.14 || maxY >= 0.86
    }
}
