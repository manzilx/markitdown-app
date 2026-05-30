import CoreGraphics
import PDFKit

enum BBoxCoordinateMapper {
    /// Vision normalized bbox → PDF page rect (origin bottom-left).
    static func pageRect(from bbox: [Double], mediaBox: CGRect) -> CGRect {
        let minX = bbox[0] * mediaBox.width + mediaBox.minX
        let minY = bbox[1] * mediaBox.height + mediaBox.minY
        let width = bbox[2] * mediaBox.width
        let height = bbox[3] * mediaBox.height
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// Vision normalized bbox → view rect for a fitted image/content area (origin top-left).
    static func viewRect(
        from bbox: [Double],
        contentSize: CGSize,
        viewSize: CGSize
    ) -> CGRect {
        let scale = min(viewSize.width / max(contentSize.width, 1), viewSize.height / max(contentSize.height, 1))
        let drawnWidth = contentSize.width * scale
        let drawnHeight = contentSize.height * scale
        let offsetX = (viewSize.width - drawnWidth) / 2
        let offsetY = (viewSize.height - drawnHeight) / 2

        let minX = bbox[0] * drawnWidth + offsetX
        let width = bbox[2] * drawnWidth
        let height = bbox[3] * drawnHeight
        // Flip Y: Vision origin is bottom-left, SwiftUI is top-left.
        let topY = offsetY + (1.0 - bbox[1] - bbox[3]) * drawnHeight
        return CGRect(x: minX, y: topY, width: width, height: height)
    }
}
