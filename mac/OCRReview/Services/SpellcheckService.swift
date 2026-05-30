import AppKit
import Foundation

struct SpellIssue: Identifiable, Equatable {
    let id = UUID()
    let word: String
    let location: Int
    let length: Int
    let suggestions: [String]
}

enum SpellcheckService {
    static func issues(in text: String) -> [SpellIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let checker = NSSpellChecker.shared
        let language = Locale.preferredLanguages.first ?? "en_US"
        let nsText = text as NSString
        var results: [SpellIssue] = []
        var searchStart = 0

        while searchStart < nsText.length {
            let range = checker.checkSpelling(
                of: text,
                startingAt: searchStart,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if range.location == NSNotFound { break }

            let word = nsText.substring(with: range)
            if shouldSkip(word) {
                searchStart = range.location + max(range.length, 1)
                continue
            }

            let guesses = checker.guesses(
                forWordRange: range,
                in: text,
                language: language,
                inSpellDocumentWithTag: 0
            ) ?? []

            if !guesses.isEmpty {
                results.append(
                    SpellIssue(
                        word: word,
                        location: range.location,
                        length: range.length,
                        suggestions: Array(guesses.prefix(5))
                    )
                )
            }

            searchStart = range.location + max(range.length, 1)
        }

        return results
    }

    static func replace(in text: String, issue: SpellIssue, with replacement: String) -> String {
        guard issue.location >= 0,
              issue.location + issue.length <= (text as NSString).length
        else { return text }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: NSRange(location: issue.location, length: issue.length), with: replacement)
        return mutable as String
    }

    private static func shouldSkip(_ word: String) -> Bool {
        if word.isEmpty { return true }
        if word.allSatisfy(\.isNumber) { return true }
        if word.count == 1 && !word.first!.isLetter { return true }
        return false
    }
}
