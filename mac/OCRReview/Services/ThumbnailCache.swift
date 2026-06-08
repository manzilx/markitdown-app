import AppKit
import PDFKit

/// Caches rendered PDF page thumbnails so the page strip doesn't regenerate
/// bitmaps on every scroll/redraw. Keyed by page identity + rotation + width,
/// so reordering keeps cached images valid while rotation invalidates them.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 240
    }

    private func key(for page: PDFPage, width: CGFloat) -> NSString {
        let identity = UInt(bitPattern: ObjectIdentifier(page).hashValue)
        return "\(identity)-\(page.rotation)-\(Int(width))" as NSString
    }

    func cached(for page: PDFPage, width: CGFloat) -> NSImage? {
        cache.object(forKey: key(for: page, width: width))
    }

    /// Render a thumbnail and cache it.
    ///
    /// Rendering happens on the **main actor**. PDFKit is not thread-safe, and this page
    /// belongs to the same `PDFDocument` the on-screen PDF view uses — rendering it on a
    /// background thread (as before) raced with the main thread and crashed on multi-page
    /// documents, where the strip realizes many thumbnails at once. Thumbnails are small,
    /// so the per-item main-thread cost is negligible and results are cached.
    func thumbnail(for page: PDFPage, width: CGFloat) async -> NSImage? {
        let cacheKey = key(for: page, width: width)
        if let hit = cache.object(forKey: cacheKey) { return hit }

        let bounds = page.bounds(for: .mediaBox)
        let scale = width / max(bounds.width, 1)
        let size = NSSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))

        let image = page.thumbnail(of: size, for: .mediaBox)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }
}
