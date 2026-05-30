import AppKit
import PDFKit
import SwiftUI

/// Lightweight controller that lets SwiftUI drive zoom on the underlying PDFView.
@MainActor
final class PDFViewController: ObservableObject {
    weak var pdfView: PDFView?
    @Published var scalePercent: Int = 100

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 6.0

    func zoomIn() { setScale(currentScale * 1.2) }
    func zoomOut() { setScale(currentScale / 1.2) }
    func actualSize() { setScale(1) }

    func fit() {
        guard let view = pdfView else { return }
        view.autoScales = true
        DispatchQueue.main.async { [weak self] in self?.syncPercent() }
    }

    func syncPercent() {
        guard let view = pdfView else { return }
        scalePercent = Int((view.scaleFactor * 100).rounded())
    }

    private var currentScale: CGFloat { pdfView?.scaleFactor ?? 1 }

    private func setScale(_ scale: CGFloat) {
        guard let view = pdfView else { return }
        view.autoScales = false
        let clamped = min(max(scale, minScale), maxScale)
        view.scaleFactor = clamped
        scalePercent = Int((clamped * 100).rounded())
    }
}

struct PDFPageViewWithBlocks: NSViewRepresentable {
    let document: PDFDocument?
    let pageIndex: Int
    let blocks: [OCRBlock]
    let selectedBlockID: UUID?
    var showHeatmap: Bool = false
    var redactedBlockIDs: Set<UUID> = []
    var controller: PDFViewController?
    let onSelectBlock: (UUID?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectBlock: onSelectBlock)
    }

    func makeNSView(context: Context) -> BlockOverlayPDFView {
        let view = BlockOverlayPDFView()
        view.onSelectBlock = onSelectBlock
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(red: 0.039, green: 0.043, blue: 0.055, alpha: 1.0)
        context.coordinator.pdfView = view
        controller?.pdfView = view
        return view
    }

    func updateNSView(_ pdfView: BlockOverlayPDFView, context: Context) {
        pdfView.onSelectBlock = onSelectBlock
        pdfView.showHeatmap = showHeatmap
        pdfView.redactedBlockIDs = redactedBlockIDs
        pdfView.document = document
        controller?.pdfView = pdfView
        if let document, pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) {
            pdfView.go(to: page)
            pdfView.updateBlockOverlay(
                blocks: blocks,
                page: page,
                selectedBlockID: selectedBlockID
            )
            DispatchQueue.main.async { controller?.syncPercent() }
        } else {
            pdfView.clearBlockOverlay()
        }
    }

    final class Coordinator {
        var pdfView: BlockOverlayPDFView?
        let onSelectBlock: (UUID?) -> Void

        init(onSelectBlock: @escaping (UUID?) -> Void) {
            self.onSelectBlock = onSelectBlock
        }
    }
}

final class BlockOverlayPDFView: PDFView {
    var onSelectBlock: ((UUID?) -> Void)?
    var showHeatmap = false {
        didSet { if showHeatmap != oldValue { redrawOverlay() } }
    }
    var redactedBlockIDs: Set<UUID> = [] {
        didSet { if redactedBlockIDs != oldValue { redrawOverlay() } }
    }

    private var overlayBlocks: [OCRBlock] = []
    private var blockEntries: [(id: UUID, rect: NSRect, confidence: Float)] = []
    private var selectedBlockID: UUID?
    private let overlayLayer = CALayer()

    private static let accentColor = NSColor(srgbRed: 0.45, green: 0.44, blue: 0.96, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overlayLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(overlayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBlockOverlay(blocks: [OCRBlock], page: PDFPage, selectedBlockID: UUID?) {
        overlayBlocks = blocks
        self.selectedBlockID = selectedBlockID
        let mediaBox = page.bounds(for: .mediaBox)
        blockEntries = blocks.compactMap { block in
            guard let bbox = block.bboxNormalized else { return nil }
            let pageRect = BBoxCoordinateMapper.pageRect(from: bbox, mediaBox: mediaBox)
            let viewRect = convert(pageRect, from: page)
            return (block.id, viewRect, block.confidence)
        }
        redrawOverlay()
    }

    func clearBlockOverlay() {
        overlayBlocks = []
        blockEntries = []
        selectedBlockID = nil
        overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    override func layout() {
        super.layout()
        overlayLayer.frame = bounds
        if let page = currentPage, !overlayBlocks.isEmpty {
            updateBlockOverlay(blocks: overlayBlocks, page: page, selectedBlockID: selectedBlockID)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = blockEntries.first(where: { $0.rect.contains(point) }) {
            onSelectBlock?(hit.id)
        } else {
            onSelectBlock?(nil)
        }
        super.mouseDown(with: event)
    }

    private func redrawOverlay() {
        overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlayLayer.frame = bounds

        for entry in blockEntries {
            let layer = CAShapeLayer()
            layer.path = CGPath(roundedRect: entry.rect, cornerWidth: 3, cornerHeight: 3, transform: nil)

            if redactedBlockIDs.contains(entry.id) {
                layer.fillColor = NSColor.black.cgColor
                layer.strokeColor = NSColor.black.cgColor
                layer.lineWidth = 1
                overlayLayer.addSublayer(layer)
                continue
            }

            let isSelected = entry.id == selectedBlockID
            let base: NSColor
            if isSelected {
                base = Self.accentColor
            } else if showHeatmap {
                base = ConfidencePalette.nsColor(for: entry.confidence)
            } else {
                base = Self.accentColor
            }
            layer.fillColor = base.withAlphaComponent(isSelected ? 0.26 : (showHeatmap ? 0.20 : 0.10)).cgColor
            layer.strokeColor = base.withAlphaComponent(isSelected ? 1 : 0.7).cgColor
            layer.lineWidth = isSelected ? 2 : 1
            if isSelected {
                layer.shadowColor = base.cgColor
                layer.shadowOpacity = 0.7
                layer.shadowRadius = 6
                layer.shadowOffset = .zero
            }
            overlayLayer.addSublayer(layer)
        }
    }
}

struct ImagePageViewWithBlocks: View {
    let url: URL
    let blocks: [OCRBlock]
    let selectedBlockID: UUID?
    var showHeatmap: Bool = false
    var redactedBlockIDs: Set<UUID> = []
    let onSelectBlock: (UUID?) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    let size = image.size
                    ForEach(blocks) { block in
                        if let bbox = block.bboxNormalized {
                            let rect = BBoxCoordinateMapper.viewRect(
                                from: bbox,
                                contentSize: size,
                                viewSize: geo.size
                            )
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(blockFill(for: block))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(blockStroke(for: block), lineWidth: block.id == selectedBlockID ? 2 : 1)
                                )
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .onTapGesture { onSelectBlock(block.id) }
                        }
                    }
                } else {
                    Text("Could not load image")
                        .foregroundStyle(Theme.dim)
                }
            }
            .contentShape(Rectangle())
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectBlock(nil) }
            )
        }
    }

    private func blockFill(for block: OCRBlock) -> Color {
        if redactedBlockIDs.contains(block.id) { return .black }
        if block.id == selectedBlockID { return Theme.accent.opacity(0.26) }
        if showHeatmap { return Theme.confidenceColor(block.confidence).opacity(0.20) }
        return Theme.accent.opacity(0.10)
    }

    private func blockStroke(for block: OCRBlock) -> Color {
        if redactedBlockIDs.contains(block.id) { return .black }
        if block.id == selectedBlockID { return Theme.accent }
        if showHeatmap { return Theme.confidenceColor(block.confidence).opacity(0.8) }
        return Theme.accent.opacity(0.7)
    }
}
