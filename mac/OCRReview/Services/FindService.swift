import Foundation

struct FindMatch: Identifiable, Equatable {
    let id = UUID()
    let pageNumber: Int
    let range: Range<String.Index>
    let snippet: String
}

enum FindService {
    static func find(in document: OCRDocument, query: String, caseSensitive: Bool = false) -> [FindMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var matches: [FindMatch] = []
        for page in document.pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            let text = page.displayText
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: trimmed,
                      options: caseSensitive ? [] : .caseInsensitive,
                      range: searchStart..<text.endIndex
                  )
            {
                let snippet = snippet(for: text, around: range)
                matches.append(FindMatch(pageNumber: page.pageNumber, range: range, snippet: snippet))
                searchStart = range.upperBound
            }
        }
        return matches
    }

    static func replace(
        in text: String,
        query: String,
        replacement: String,
        at range: Range<String.Index>,
        caseSensitive: Bool = false
    ) -> String? {
        let matched = String(text[range])
        if caseSensitive {
            guard matched == query else { return nil }
        } else {
            guard matched.caseInsensitiveCompare(query) == .orderedSame else { return nil }
        }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }

    static func replaceAll(in text: String, query: String, replacement: String, caseSensitive: Bool = false) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result.range(
                  of: trimmed,
                  options: caseSensitive ? [] : .caseInsensitive,
                  range: searchStart..<result.endIndex
              )
        {
            result.replaceSubrange(range, with: replacement)
            searchStart = result.index(range.lowerBound, offsetBy: replacement.count)
        }
        return result
    }

    private static func snippet(for text: String, around range: Range<String.Index>, radius: Int = 24) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}
