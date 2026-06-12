import XCTest
@testable import OCRReview

final class DenoiseServiceTests: XCTestCase {

    // Distinct word pairs per line so body lines have unique normalized keys
    // (i.e. they are NOT mistaken for repeated headers/footers).
    private static let pool = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
        "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray",
    ]

    private func uniqueBody(page n: Int, lines: Int) -> [String] {
        (0..<lines).map { k in
            let a = Self.pool[(n * 7 + k * 3) % Self.pool.count]
            let b = Self.pool[(n * 11 + k * 5) % Self.pool.count]
            return "The \(a) section reviews \(b) findings in depth."
        }
    }

    private func makeDoc(pageTexts: [String], totalPageCount: Int? = nil) -> OCRDocument {
        let pages = pageTexts.enumerated().map { OCRPage(pageNumber: $0.offset + 1, ocrText: $0.element) }
        return OCRDocument(
            filename: "t.pdf", sourcePath: "/tmp/t.pdf", pages: pages,
            engine: "vision", totalPageCount: totalPageCount ?? pageTexts.count
        )
    }

    private func page(_ n: Int, header: String?, footer: String?, bodyLines: Int = 8) -> String {
        var lines: [String] = []
        if let header { lines.append(header) }
        lines.append(contentsOf: uniqueBody(page: n, lines: bodyLines))
        if let footer { lines.append(footer) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Headers

    func testRemovesRepeatedHeader() {
        let texts = (1...15).map { page($0, header: "ACME ANNUAL REPORT", footer: nil) }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        XCTAssertGreaterThan(result.plan.removedLineCount, 0)
        for p in result.document.pages {
            XCTAssertFalse(p.displayText.contains("ACME ANNUAL REPORT"), "header should be gone on page \(p.pageNumber)")
            XCTAssertTrue(p.displayText.contains("section reviews"), "body should remain on page \(p.pageNumber)")
        }
    }

    // MARK: - Page numbers

    func testRemovesPageNumbersMatchingIndex() {
        let texts = (1...12).map { page($0, header: nil, footer: "Page \($0)") }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        for p in result.document.pages {
            XCTAssertFalse(p.displayText.lowercased().contains("page \(p.pageNumber)"),
                           "page number should be gone on page \(p.pageNumber)")
        }
    }

    /// The headline fix: printed page numbers OFFSET from the file index (front matter)
    /// must still be removed.
    func testRemovesPageNumbersOffsetFromIndex() {
        let texts = (1...12).map { page($0, header: nil, footer: "\($0 + 4)") }  // printed 5..16
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        XCTAssertGreaterThanOrEqual(result.plan.removedLineCount, 12, "offset page numbers should be removed")
        for p in result.document.pages {
            let last = p.displayText.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            XCTAssertNotEqual(last, "\(p.pageNumber + 4)", "footer page number should be gone on page \(p.pageNumber)")
        }
    }

    func testRemovesDecoratedAndBracketedPageNumbers() {
        let dash = (1...10).map { page($0, header: nil, footer: "- \($0 + 2) -") }
        let dashResult = DenoiseService.apply(to: makeDoc(pageTexts: dash))
        for p in dashResult.document.pages {
            XCTAssertFalse(p.displayText.contains("- \(p.pageNumber + 2) -"), "decorated page number should be gone")
        }

        let bracket = (1...10).map { page($0, header: nil, footer: "[\($0 + 2)]") }
        let bracketResult = DenoiseService.apply(to: makeDoc(pageTexts: bracket))
        for p in bracketResult.document.pages {
            XCTAssertFalse(p.displayText.contains("[\(p.pageNumber + 2)]"), "bracketed page number should be gone")
        }
    }

    func testRemovesPageXofYFooter() {
        let texts = (1...9).map { page($0, header: "WEEKLY DIGEST", footer: "Page \($0) of 9") }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        for p in result.document.pages {
            XCTAssertFalse(p.displayText.lowercased().contains("of 9"), "page X of Y footer should be gone")
            XCTAssertFalse(p.displayText.contains("WEEKLY DIGEST"), "repeated header should be gone")
        }
    }

    func testRemovesRomanNumeralPageNumbers() {
        let romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
        let texts = (1...12).map { page($0, header: nil, footer: romans[$0 - 1]) }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        XCTAssertGreaterThanOrEqual(result.plan.removedLineCount, 12, "roman numeral page numbers should be removed")
        for p in result.document.pages {
            let last = p.displayText.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            XCTAssertNotEqual(last, romans[p.pageNumber - 1], "roman numeral footer should be gone on page \(p.pageNumber)")
        }
    }

    func testRomanWordsAreNotPageNumbers() {
        // "mild" and "dim" are made of roman letters but are not valid numerals.
        let words = ["mild", "dim", "civil", "livid", "mild", "dim", "civil", "livid", "mild", "dim"]
        let texts = (1...10).map { n -> String in
            var lines = uniqueBody(page: n, lines: 8)
            lines.append("\(words[n - 1]) \(Self.pool[n % Self.pool.count])")
            return lines.joined(separator: "\n")
        }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        XCTAssertEqual(result.plan.removedLineCount, 0, "roman-lookalike words must not be treated as page numbers")
    }

    // MARK: - Selective apply

    func testSelectiveApplyRespectsEnabledKeys() {
        let texts = (1...12).map { page($0, header: "ACME ANNUAL REPORT", footer: "Page \($0)") }
        let doc = makeDoc(pageTexts: texts)
        let plan = DenoiseService.makePlan(for: doc)
        XCTAssertEqual(plan.candidates.count, 2, "expected a header candidate and a page-number candidate")

        let onlyNumbers = DenoiseService.apply(plan: plan, to: doc, enabledKeys: [DenoiseService.pageNumberKey])
        for p in onlyNumbers.document.pages {
            XCTAssertTrue(p.displayText.contains("ACME ANNUAL REPORT"), "disabled header must be kept")
            XCTAssertFalse(p.displayText.lowercased().contains("page \(p.pageNumber)"), "enabled page numbers must be removed")
        }

        let headerKey = plan.candidates.first { $0.reason == .repeatedEdgeText }!.key
        let onlyHeader = DenoiseService.apply(plan: plan, to: doc, enabledKeys: [headerKey])
        for p in onlyHeader.document.pages {
            XCTAssertFalse(p.displayText.contains("ACME ANNUAL REPORT"), "enabled header must be removed")
            XCTAssertTrue(p.displayText.lowercased().contains("page \(p.pageNumber)"), "disabled page numbers must be kept")
        }
    }

    func testSelectiveApplyWithNothingEnabledIsNoop() {
        let texts = (1...12).map { page($0, header: "ACME ANNUAL REPORT", footer: "Page \($0)") }
        let doc = makeDoc(pageTexts: texts)
        let plan = DenoiseService.makePlan(for: doc)
        let result = DenoiseService.apply(plan: plan, to: doc, enabledKeys: [])
        XCTAssertEqual(result.plan.removedLineCount, 0)
        for (original, cleaned) in zip(doc.pages, result.document.pages) {
            XCTAssertEqual(original.displayText, cleaned.displayText)
        }
    }

    // MARK: - Safety

    func testKeepsStandaloneBodyNumber() {
        // A standalone number in the MIDDLE of a long page is body, not a page number.
        let texts = (1...10).map { n -> String in
            var lines = ["UNIQUE HEADER \(Self.pool[n % Self.pool.count])"]
            lines.append(contentsOf: uniqueBody(page: n, lines: 4))
            lines.append("42")  // middle, surrounded by body
            lines.append(contentsOf: uniqueBody(page: n + 100, lines: 4))
            lines.append("footer note \(Self.pool[(n + 5) % Self.pool.count])")
            return lines.joined(separator: "\n")
        }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        for p in result.document.pages {
            XCTAssertTrue(p.displayText.contains("42"), "body number should be kept on page \(p.pageNumber)")
        }
    }

    func testNoopOnCleanDocument() {
        let texts = (1...8).map { page($0, header: nil, footer: nil) }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        XCTAssertEqual(result.plan.removedLineCount, 0, "clean document should have nothing removed")
    }

    func testNeverEmptiesAPage() {
        // A page that is ONLY a repeated header + page number must not become empty.
        let texts = (1...10).map { "REPEATED HEADER\n\($0)" }
        let result = DenoiseService.apply(to: makeDoc(pageTexts: texts))
        for p in result.document.pages {
            XCTAssertFalse(p.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "page \(p.pageNumber) must not be emptied")
        }
    }

    func testEmptyDocumentProducesEmptyPlan() {
        let result = DenoiseService.apply(to: makeDoc(pageTexts: []))
        XCTAssertEqual(result.plan.removedLineCount, 0)
    }
}
