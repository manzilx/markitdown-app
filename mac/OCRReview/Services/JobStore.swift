import Foundation

@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var recents: [OCRDocument] = []

    private let recentsKey = "ocrreview.recents"
    private let maxRecents = 12

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

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OCRReview/jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        let snapshots = Array(pending.values)
        pending.removeAll()
        for document in snapshots {
            let url = jobFileURL(for: document.id)
            if let data = try? encoder.encode(document) {
                try? data.write(to: url, options: .atomic)
            }
            upsertRecent(document)
        }
        io.sync {}  // drain any in-flight async writes
    }

    private func write(_ document: OCRDocument) {
        let url = jobFileURL(for: document.id)
        let encoder = self.encoder
        io.async {
            if let data = try? encoder.encode(document) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Loading

    func load(id: UUID) -> OCRDocument? {
        let url = jobFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OCRDocument.self, from: data)
    }

    func delete(id: UUID) {
        pending[id] = nil
        let url = jobFileURL(for: id)
        io.async { try? FileManager.default.removeItem(at: url) }
        recents.removeAll { $0.id == id }
        persistRecentsIndex()
    }

    private func jobFileURL(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("\(id.uuidString).json")
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
