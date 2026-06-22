import Foundation

/// Sorts OCR line boxes into natural reading order. Vision returns observations in
/// detection order with baseline jitter, so a plain Y sort can swap same-row cells
/// (table label vs value) and scrambles multi-column content. Lines whose vertical
/// extents overlap by ≥50% of the smaller height form one visual row (read
/// left→right); rows read top→bottom.
enum ReadingOrder {
    /// Returns indexes into `boxes` in reading order. Boxes are Vision-style
    /// bottom-left-origin normalized rects: [x, y, width, height].
    static func order(boxes: [[Double]]) -> [Int] {
        struct Band {
            var top: Double      // distance from page top (1 - maxY), smaller = higher
            var bottom: Double
            var items: [Int]
        }

        let measured = boxes.map { box -> (top: Double, bottom: Double, left: Double) in
            let top = 1.0 - (box[1] + box[3])
            return (top: top, bottom: top + box[3], left: box[0])
        }

        var bands: [Band] = []
        for index in measured.indices.sorted(by: { measured[$0].top < measured[$1].top }) {
            let line = measured[index]
            var placed = false
            for bandIndex in bands.indices.reversed() {
                let band = bands[bandIndex]
                let overlap = min(line.bottom, band.bottom) - max(line.top, band.top)
                let minHeight = min(line.bottom - line.top, band.bottom - band.top)
                if overlap >= 0.5 * max(minHeight, 1e-9) {
                    bands[bandIndex].items.append(index)
                    bands[bandIndex].top = min(band.top, line.top)
                    bands[bandIndex].bottom = max(band.bottom, line.bottom)
                    placed = true
                    break
                }
            }
            if !placed {
                bands.append(Band(top: line.top, bottom: line.bottom, items: [index]))
            }
        }

        return bands
            .sorted { $0.top < $1.top }
            .flatMap { band in band.items.sorted { measured[$0].left < measured[$1].left } }
    }

    /// Blocks in reading order. Blocks without usable geometry keep their relative
    /// order and trail the boxed ones.
    static func sorted(blocks: [OCRBlock]) -> [OCRBlock] {
        let boxed = blocks.filter { ($0.bboxNormalized?.count ?? 0) >= 4 }
        let unboxed = blocks.filter { ($0.bboxNormalized?.count ?? 0) < 4 }
        let ordered = order(boxes: boxed.map { $0.bboxNormalized! }).map { boxed[$0] }
        return ordered + unboxed
    }
}
