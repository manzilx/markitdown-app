import PDFKit

enum PageStructureService {
    static func remapAfterDelete(pages: [OCRPage], deletedPageNumber: Int) -> [OCRPage] {
        pages.compactMap { page in
            if page.pageNumber == deletedPageNumber { return nil }
            var updated = page
            if updated.pageNumber > deletedPageNumber {
                updated.pageNumber -= 1
            }
            return updated
        }
        .sorted { $0.pageNumber < $1.pageNumber }
    }

    static func remapAfterMove(pages: [OCRPage], fromIndex: Int, toIndex: Int, pageCount: Int) -> [OCRPage] {
        var slots: [OCRPage?] = (0..<pageCount).map { index in
            pages.first { $0.pageNumber == index + 1 }
        }
        guard fromIndex >= 0, fromIndex < slots.count, toIndex >= 0, toIndex < slots.count else {
            return pages
        }
        let item = slots.remove(at: fromIndex)
        slots.insert(item, at: toIndex)
        return slots.enumerated().compactMap { index, page in
            guard var updated = page else { return nil }
            updated.pageNumber = index + 1
            return updated
        }
    }
}
