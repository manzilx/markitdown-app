import AppKit
import PDFKit
@preconcurrency import Vision

enum VisionOCRService {
    static let lowConfidenceThreshold: Float = 0.85

    /// Concurrency for whole-document recognition. Vision leans on the Neural Engine/GPU,
    /// so we cap workers to avoid thrashing while still using multiple cores.
    static var maxConcurrentOCR: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    // MARK: - Single page (reuses the in-memory document — no disk re-parse)

    /// Render + recognize a page. Only safe for a PDFPage from a document NOT shared with
    /// the main thread (e.g. the per-worker documents in `recognizeAllPages`). For the
    /// shared on-screen document, render on the main actor and call `recognize(cgImage:)`.
    static func recognize(pdfPage: PDFPage, pageNumber: Int) async throws -> OCRPage {
        let cgImage = try autoreleasepool { () throws -> CGImage in
            guard let image = renderPage(pdfPage, scale: 2.0) else { throw OCRError.renderFailed }
            return image
        }
        return try await recognize(cgImage: cgImage, pageNumber: pageNumber)
    }

    static func recognize(imageURL url: URL, pageNumber: Int = 1) async throws -> OCRPage {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw OCRError.openFailed
        }
        return try await recognize(cgImage: cgImage, pageNumber: pageNumber)
    }

    // MARK: - Whole document (parallel)

    struct PageFailure: Sendable {
        let pageNumber: Int
        let message: String
    }

    struct BatchResult: Sendable {
        let succeededCount: Int
        let failures: [PageFailure]
    }

    /// Recognize the given page indexes of a PDF concurrently. Each worker opens its own
    /// PDFDocument from the file URL so PDFKit state is never shared across threads.
    /// Pages stream back through `onPage` as they finish, so cancellation keeps every
    /// page completed so far instead of discarding the whole batch.
    static func recognizePages(
        pdfURL: URL,
        pageIndexes: [Int],
        onPage: @escaping @Sendable (OCRPage) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> BatchResult {
        guard !pageIndexes.isEmpty else { return BatchResult(succeededCount: 0, failures: []) }

        let workerCount = min(maxConcurrentOCR, pageIndexes.count)
        let counter = ProgressCounter(total: pageIndexes.count, onProgress: onProgress)

        return try await withThrowingTaskGroup(of: (Int, [PageFailure]).self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    guard let doc = PDFDocument(url: pdfURL) else { throw OCRError.openFailed }
                    var succeeded = 0
                    var failures: [PageFailure] = []
                    var position = worker
                    while position < pageIndexes.count {
                        try Task.checkCancellation()
                        let index = pageIndexes[position]
                        let pageNumber = index + 1
                        do {
                            guard let page = doc.page(at: index) else { throw OCRError.renderFailed }
                            let ocr = try await recognize(pdfPage: page, pageNumber: pageNumber)
                            onPage(ocr)
                            succeeded += 1
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failures.append(PageFailure(pageNumber: pageNumber, message: error.localizedDescription))
                        }
                        await counter.tick()
                        position += workerCount
                    }
                    return (succeeded, failures)
                }
            }

            var total = 0
            var allFailures: [PageFailure] = []
            for try await (succeeded, failures) in group {
                total += succeeded
                allFailures.append(contentsOf: failures)
            }
            return BatchResult(
                succeededCount: total,
                failures: allFailures.sorted { $0.pageNumber < $1.pageNumber }
            )
        }
    }

    // MARK: - Core recognition

    /// Guards a continuation against double-resume: when a performed Vision request
    /// fails, the completion handler can fire with the error AND `perform` can throw —
    /// resuming twice traps the process.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// Recognize a pre-rendered image off the main thread. Render the shared on-screen
    /// document on the main actor, then hand the CGImage here.
    static func recognize(cgImage: CGImage, pageNumber: Int) async throws -> OCRPage {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var blocks: [OCRBlock] = []
                var lines: [String] = []

                // Reading order: a plain Y sort swaps same-row cells under baseline
                // jitter and scrambles columns; group into visual rows instead.
                let rects = observations.map { obs -> [Double] in
                    let box = obs.boundingBox
                    return [Double(box.origin.x), Double(box.origin.y), Double(box.width), Double(box.height)]
                }
                for observation in ReadingOrder.order(boxes: rects).map({ observations[$0] }) {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let box = observation.boundingBox
                    blocks.append(
                        OCRBlock(
                            text: candidate.string,
                            confidence: candidate.confidence,
                            bboxNormalized: [
                                Double(box.origin.x),
                                Double(box.origin.y),
                                Double(box.width),
                                Double(box.height),
                            ]
                        )
                    )
                    lines.append(candidate.string)
                }

                let text = lines.joined(separator: "\n")
                guard once.claim() else { return }
                continuation.resume(
                    returning: OCRPage(
                        pageNumber: pageNumber,
                        ocrText: text,
                        blocks: blocks
                    )
                )
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // `perform` is synchronous and heavy. Run it on GCD so it never blocks a
            // cooperative-pool thread — with several OCR workers in flight, blocking the
            // pool starves every other async task in the app.
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
        }
    }

    static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

/// Thread-safe progress counter that forwards normalized progress to the main thread.
private actor ProgressCounter {
    private var done = 0
    private let total: Int
    private let onProgress: @Sendable (Double) -> Void

    init(total: Int, onProgress: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1)
        self.onProgress = onProgress
    }

    func tick() {
        done += 1
        onProgress(Double(done) / Double(total))
    }
}
