import Foundation

enum AppErrorKind: String, Codable {
    case open
    case save
    case export
    case sidecar
    case ocr
    case validation
    case unknown
}

struct AppError: LocalizedError, Identifiable, Equatable {
    let id = UUID()
    let kind: AppErrorKind
    let title: String
    let userMessage: String
    let technicalMessage: String?
    let recoveryAction: String?

    init(
        kind: AppErrorKind,
        title: String,
        userMessage: String,
        technicalMessage: String? = nil,
        recoveryAction: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.userMessage = userMessage
        self.technicalMessage = technicalMessage
        self.recoveryAction = recoveryAction
    }

    var errorDescription: String? {
        userMessage
    }

    var displayMessage: String {
        if let recoveryAction, !recoveryAction.isEmpty {
            return "\(userMessage)\n\(recoveryAction)"
        }
        return userMessage
    }

    static func wrap(
        _ error: Error,
        kind: AppErrorKind,
        title: String,
        fallback: String,
        recoveryAction: String? = nil
    ) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return AppError(
            kind: kind,
            title: title,
            userMessage: error.localizedDescription.isEmpty ? fallback : error.localizedDescription,
            technicalMessage: String(describing: error),
            recoveryAction: recoveryAction
        )
    }
}

enum OperationState: Equatable {
    case idle
    case running(message: String, progress: Double, pageNumber: Int?, canCancel: Bool)
    case succeeded(message: String)
    case failed(AppError)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    enum Level: String {
        case info
        case warning
        case error
    }

    private let queue = DispatchQueue(label: "com.ocrreview.diagnostics", qos: .utility)
    private let maxLogBytes: UInt64 = 512 * 1024
    private let maxRotatedFiles = 5

    private var logDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OCRReview/logs", isDirectory: true)
    }

    private var currentLogURL: URL {
        logDirectory.appendingPathComponent("diagnostics.log")
    }

    private init() {
        let directory = logDirectory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func log(level: Level, event: String, context: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let contextText = context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: "\\n"))" }
            .joined(separator: " ")
        let suffix = contextText.isEmpty ? "" : " \(contextText)"
        let line = "\(timestamp) [\(level.rawValue.uppercased())] \(event)\(suffix)\n"

        queue.async {
            self.rotateIfNeeded()
            do {
                try FileManager.default.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: self.currentLogURL.path) {
                    let handle = try FileHandle(forWritingTo: self.currentLogURL)
                    try handle.seekToEnd()
                    if let data = line.data(using: .utf8) {
                        try handle.write(contentsOf: data)
                    }
                    try handle.close()
                } else {
                    try line.write(to: self.currentLogURL, atomically: true, encoding: .utf8)
                }
            } catch {
                // Diagnostics are best effort; never make app reliability depend on logging.
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let size = attributes[.size] as? UInt64,
              size >= maxLogBytes
        else { return }

        for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let source = logDirectory.appendingPathComponent("diagnostics.\(index).log")
            let destination = logDirectory.appendingPathComponent("diagnostics.\(index + 1).log")
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        }

        let first = logDirectory.appendingPathComponent("diagnostics.1.log")
        if FileManager.default.fileExists(atPath: first.path) {
            try? FileManager.default.removeItem(at: first)
        }
        try? FileManager.default.moveItem(at: currentLogURL, to: first)
    }
}
