import XCTest
@testable import OCRReview

final class ReadingOrderTests: XCTestCase {

    // Vision-style bottom-left normalized [x, y, w, h].
    private func box(x: Double, top: Double, w: Double = 0.2, h: Double = 0.02) -> [Double] {
        [x, 1.0 - top - h, w, h]
    }

    func testSameRowFragmentsReadLeftToRight() {
        // Engine returned value before label; baselines jittered slightly.
        let boxes = [
            box(x: 0.60, top: 0.102),  // "ACME Corp" (value)
            box(x: 0.08, top: 0.100),  // "Company" (label)
        ]
        XCTAssertEqual(ReadingOrder.order(boxes: boxes), [1, 0])
    }

    func testRowsReadTopToBottomDespiteScrambledInput() {
        let boxes = [
            box(x: 0.08, top: 0.300),  // row 3 label
            box(x: 0.08, top: 0.100),  // row 1 label
            box(x: 0.60, top: 0.198),  // row 2 value (jittered up)
            box(x: 0.60, top: 0.103),  // row 1 value (jittered down)
            box(x: 0.08, top: 0.200),  // row 2 label
        ]
        XCTAssertEqual(ReadingOrder.order(boxes: boxes), [1, 3, 4, 2, 0])
    }

    func testPlainYSortJitterDoesNotSwapCells() {
        // The label sits slightly BELOW the value's top — a plain Y sort would emit
        // the value first; row grouping must keep label-then-value.
        let boxes = [
            box(x: 0.08, top: 0.104),  // label, lower baseline
            box(x: 0.60, top: 0.100),  // value, higher baseline
        ]
        XCTAssertEqual(ReadingOrder.order(boxes: boxes), [0, 1])
    }

    func testDistinctLinesWithSmallOverlapStaySeparateRows() {
        // 20%-height overlap (tight leading) must NOT merge two paragraph lines.
        let boxes = [
            box(x: 0.08, top: 0.116, w: 0.5),
            box(x: 0.08, top: 0.100, w: 0.5),
        ]
        XCTAssertEqual(ReadingOrder.order(boxes: boxes), [1, 0])
    }

    func testBlocksWithoutGeometryTrailInOriginalOrder() {
        let blocks = [
            OCRBlock(text: "no box A", confidence: 1, bboxNormalized: nil),
            OCRBlock(text: "second row", confidence: 1, bboxNormalized: box(x: 0.08, top: 0.2)),
            OCRBlock(text: "first row", confidence: 1, bboxNormalized: box(x: 0.08, top: 0.1)),
            OCRBlock(text: "no box B", confidence: 1, bboxNormalized: nil),
        ]
        XCTAssertEqual(
            ReadingOrder.sorted(blocks: blocks).map(\.text),
            ["first row", "second row", "no box A", "no box B"]
        )
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(ReadingOrder.order(boxes: []), [])
    }
}
