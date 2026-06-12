import Foundation

@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var recents: [OCRDocument] = []
    @Published private(set) var lastError: AppError?

    private let recentsKey = "ocrreview.recents"
    private let maxRecents = 12
    private let maxSnapshotsPerDocument = 20
    private let maxSnapshotBytesPerDocument: UInt64 = 100 * 1024 * 1024

    /// Serial queue so encodes happen off the main thread and disk writes stay ordered.
    private let io = DispatchQueue(label: "com.ocrreview.jobstore.io", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    /// Latest unsaved document state, keyed by id. Always holds the newest snapshot.
    private var pending: [UUID: OCRDocument] = [:]
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(600)

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OCRReview/jobs", isDirectory: true)
        return dir
    }

    init() {
        loadRecents()
    }

    // MARK: - Saving

    /// Coalesced, off-main-thread save. Use for high-frequency edits (typing, find/replace,
    /// spell fixes). Many calls in quick succession collapse into a single disk write.
    func scheduleSave(_ document: OCRDocument) {
        pending[document.id] = document
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    func clearLastError() {
        lastError = nil
    }

    /// Immediate save. Use for infrequent, important changes (open, OCR completion,
    /// page structure edits). Still encodes + writes off the main thread.
    func save(_ document: OCRDocument) {
        pending[document.id] = document
        flush()
    }

    /// Write all pending snapshots now and refresh recents. Cancels any debounce.
    func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        guard !pending.isEmpty else { return }
        let snapshots = Array(pending.values)
        pending.removeAll()
        for document in snapshots {
            write(document)
            upsertRecent(document)
        }
    }

    /// Synchronous flush for app termination — blocks until pending writes finish.
    func flushSynchronously() {
        debounceTask?.cancel()
        debounceTask = nil
        // Drain queued async writes FIRST: they hold older document versions, and
        // letting them run after the synchronous writes below would overwrite the
        // newest state with stale data.
        io.sync {}
        let snapshots = Array(pending.values)
        pending.removeAll()
        for document in snapshots {
            switch writeSynchronously(document) {
            case .saved:
                upsertRecent(document)
            case .failed(let error):
                lastError = error
                pending[document.id] = document
            }
        }
    }

    private func write(_ document: OCRDocument) {
        let currentURL = currentFileURL(for: document.id)
        let snapshotURL = snapshotFileURL(for: document.id, date: Date())
        let documentDirectory = documentDirectory(for: document.id)
        let snapshotsDirectory = snapshotsDirectory(for: document.id)
        let encoder = self.encoder
        io.async {
            do {
                try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
                let data = try encoder.encode(document)
                try data.write(to: currentURL, options: .atomic)
                try data.write(to: snapshotURL, options: .atomic)
                Self.pruneSnapshots(
                    in: snapshotsDirectory,
                    maxCount: self.maxSnapshotsPerDocument,
                    maxBytes: self.maxSnapshotBytesPerDocument
                )
                Task { @MainActor in
                    self.upsertRecent(document)
                }
                DiagnosticsLogger.shared.log(
                    level: .info,
                    event: "job.saved",
                    context: ["document": document.id.uuidString, "pages": "\(document.pages.count)"]
                )
            } catch {
                let appError = AppError(
                    kind: .save,
                    title: "Save failed",
                    userMessage: "OCR Review could not save the latest changes. Keep the app open and try again.",
                    technicalMessage: String(describing: error),
                    recoveryAction: "Check disk space and file permissions."
                )
                DiagnosticsLogger.shared.log(
                    level: .error,
                    event: "job.save_failed",
                    context: ["document": document.id.uuidString, "error": String(describing: error)]
                )
                Task { @MainActor in
                    // Re-queue the failed version only if no NEWER edit is already
                    // pending — otherwise this rollback would clobber it.
                    if self.pending[document.id] == nil {
                        self.pending[document.id] = document
                    }
                    self.lastError = appError
                }
            }
        }
    }

    // MARK: - Loading

    func load(id: UUID) -> OCRDocument? {
        if let document = decodeDocument(at: currentFileURL(for: id)) {
            return document
        }

        if let document = newestValidSnapshot(for: id) {
            lastError = AppError(
                kind: .save,
                title: "Recovered from backup",
                userMessage: "The latest saved copy could not be opened, so OCR Review restored the newest valid backup.",
                recoveryAction: "Review the document before continuing."
            )
            DiagnosticsLogger.shared.log(
                level: .warning,
                event: "job.recovered_from_snapshot",
                context: ["document": id.uuidString]
            )
            _ = writeSynchronously(document)
            return document
        }

        if let document = decodeDocument(at: legacyJobFileURL(for: id)) {
            _ = writeSynchronously(document)
            return document
        }

        DiagnosticsLogger.shared.log(level: .warning, event: "job.load_failed", context: ["document": id.uuidString])
        return nil
    }

    func delete(id: UUID) {
        pending[id] = nil
        let documentDirectory = documentDirectory(for: id)
        let legacyURL = legacyJobFileURL(for: id)
        io.async {
            try? FileManager.default.removeItem(at: documentDirectory)
            try? FileManager.default.removeItem(at: legacyURL)
        }
        recents.removeAll { $0.id == id }
        persistRecentsIndex()
    }

    private func documentDirectory(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func snapshotsDirectory(for id: UUID) -> URL {
        documentDirectory(for: id).appendingPathComponent("snapshots", isDirectory: true)
    }

    private func currentFileURL(for id: UUID) -> URL {
        documentDirectory(for: id).appendingPathComponent("current.json")
    }

    private func legacyJobFileURL(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func snapshotFileURL(for id: UUID, date: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        // Random suffix so two saves within the same millisecond don't overwrite each other.
        let suffix = String(UUID().uuidString.prefix(8))
        return snapshotsDirectory(for: id).appendingPathComponent("\(name)-\(suffix).json")
    }

    private func writeSynchronously(_ document: OCRDocument) -> SaveResult {
        do {
            let documentDirectory = documentDirectory(for: document.id)
            let snapshotsDirectory = snapshotsDirectory(for: document.id)
            try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: currentFileURL(for: document.id), options: .atomic)
            try data.write(to: snapshotFileURL(for: document.id, date: Date()), options: .atomic)
            Self.pruneSnapshots(
                in: snapshotsDirectory,
                maxCount: maxSnapshotsPerDocument,
                maxBytes: maxSnapshotBytesPerDocument
            )
            DiagnosticsLogger.shared.log(level: .info, event: "job.saved_sync", context: ["document": document.id.uuidString])
            return .saved(currentFileURL(for: document.id))
        } catch {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "job.save_sync_failed",
                context: ["document": document.id.uuidString, "error": String(describing: error)]
            )
            return .failed(
                AppError(
                    kind: .save,
                    title: "Save failed",
                    userMessage: "OCR Review could not save the latest changes.",
                    technicalMessage: String(describing: error),
                    recoveryAction: "Check disk space and file permissions."
                )
            )
        }
    }

    private func decodeDocument(at url: URL) -> OCRDocument? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(OCRDocument.self, from: data)
        } catch {
            return nil
        }
    }

    private func newestValidSnapshot(for id: UUID) -> OCRDocument? {
        let directory = snapshotsDirectory(for: id)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = urls.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        return sorted.lazy.compactMap { self.decodeDocument(at: $0) }.first
    }

    nonisolated private static func pruneSnapshots(in directory: URL, maxCount: Int, maxBytes: UInt64) {
        guard var urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        urls.sort {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }

        var keptBytes: UInt64 = 0
        for (index, url) in urls.enumerated() {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            keptBytes += size
            if index >= maxCount || keptBytes > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Recents

    private func upsertRecent(_ document: OCRDocument) {
        recents.removeAll { $0.id == document.id }
        recents.insert(document, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        persistRecentsIndex()
    }

    private func loadRecents() {
        guard let ids = UserDefaults.standard.stringArray(forKey: recentsKey) else { return }
        recents = ids.compactMap { UUID(uuidString: $0) }.compactMap { load(id: $0) }
    }

    private func persistRecentsIndex() {
        let ids = recents.map(\.id.uuidString)
        UserDefaults.standard.set(ids, forKey: recentsKey)
    }
}

enum SaveResult {
    case saved(URL)
    case failed(AppError)
}
