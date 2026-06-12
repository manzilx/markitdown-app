import Foundation

enum SidecarConfig {
    static let defaultBaseURL = "http://127.0.0.1:8001"

    static var baseURL: String {
        OCRSettings.sidecarURL
    }
}

enum SidecarError: LocalizedError {
    case unreachable
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Python sidecar is not running. The app tries to start it automatically from ~/markitdown-app — check Settings → project path, or run: make api"
        case .invalidResponse:
            return "Unexpected response from export service."
        case .serverError(let message):
            return message
        }
    }
}

enum EngineSidecarClient {
    struct SidecarEngineInfo: Decodable, Identifiable {
        let id: String
        let label: String
        let description: String
        let badge: String
        let available: Bool
        let supports_ocr: Bool?
        let reason: String?

        var supportsPageOCR: Bool {
            supports_ocr ?? OCRSettings.supportsSidecarPageOCR(id)
        }
    }

    private struct EnginesResponse: Decodable {
        let engines: [SidecarEngineInfo]
        let default_engine: String
    }

    static func fetchEngines() async throws -> [SidecarEngineInfo] {
        guard let url = URL(string: "\(SidecarConfig.baseURL)/v1/engines") else {
            throw SidecarError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SidecarError.unreachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SidecarError.invalidResponse
        }
        return try JSONDecoder().decode(EnginesResponse.self, from: data).engines
    }

    static func isAvailable() async -> Bool {
        guard let url = URL(string: "\(SidecarConfig.baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func ensureAvailable() async throws {
        if await isAvailable() { return }
        await SidecarProcessManager.shared.ensureRunning()
        if await isAvailable() { return }
        if let error = await SidecarProcessManager.shared.lastError {
            throw error
        }
        throw SidecarError.unreachable
    }

    static func exportSearchablePDF(
        sourceURL: URL,
        document: OCRDocument
    ) async throws -> Data {
        guard document.ocrPageCount > 0 else {
            throw SidecarError.serverError("Run OCR on at least one page before exporting.")
        }

        guard let endpoint = URL(string: "\(SidecarConfig.baseURL)/v1/export/searchable-pdf") else {
            throw SidecarError.invalidResponse
        }

        let pagesPayload = try JSONEncoder().encode(document.pagesForExport())
        let pagesString = String(decoding: pagesPayload, as: UTF8.self)

        let boundary = "OCRReview-\(UUID().uuidString)"
        let bodyURL = try makeSearchablePDFMultipartBody(
            sourceURL: sourceURL,
            pagesString: pagesString,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        } catch {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "sidecar.export_searchable_pdf_unreachable",
                context: ["error": String(describing: error)]
            )
            throw SidecarError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.invalidResponse
        }

        if http.statusCode == 200 {
            DiagnosticsLogger.shared.log(
                level: .info,
                event: "sidecar.export_searchable_pdf_succeeded",
                context: ["pages": "\(document.ocrPageCount)"]
            )
            return data
        }

        if let detail = try? JSONDecoder().decode(ErrorDetail.self, from: data) {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "sidecar.export_searchable_pdf_failed",
                context: ["status": "\(http.statusCode)", "detail": detail.detail]
            )
            throw SidecarError.serverError(detail.detail)
        }
        DiagnosticsLogger.shared.log(
            level: .error,
            event: "sidecar.export_searchable_pdf_failed",
            context: ["status": "\(http.statusCode)"]
        )
        throw SidecarError.serverError("Export failed (HTTP \(http.statusCode)).")
    }

    static func exportDOCX(document: OCRDocument) async throws -> Data {
        guard document.ocrPageCount > 0 else {
            throw SidecarError.serverError("Run OCR on at least one page before exporting.")
        }

        guard let endpoint = URL(string: "\(SidecarConfig.baseURL)/v1/export/docx") else {
            throw SidecarError.invalidResponse
        }

        let pagesPayload = try JSONEncoder().encode(document.pagesForExport())
        let pagesString = String(decoding: pagesPayload, as: UTF8.self)
        let title = document.filename
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".png", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".jpg", with: "", options: .caseInsensitive)

        let boundary = "OCRReview-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"pages_json\"\r\n\r\n")
        append(pagesString)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"title\"\r\n\r\n")
        append(title)
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "sidecar.export_docx_unreachable",
                context: ["error": String(describing: error)]
            )
            throw SidecarError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.invalidResponse
        }

        if http.statusCode == 200 {
            DiagnosticsLogger.shared.log(
                level: .info,
                event: "sidecar.export_docx_succeeded",
                context: ["pages": "\(document.ocrPageCount)"]
            )
            return data
        }

        if let detail = try? JSONDecoder().decode(ErrorDetail.self, from: data) {
            DiagnosticsLogger.shared.log(
                level: .error,
                event: "sidecar.export_docx_failed",
                context: ["status": "\(http.statusCode)", "detail": detail.detail]
            )
            throw SidecarError.serverError(detail.detail)
        }
        DiagnosticsLogger.shared.log(
            level: .error,
            event: "sidecar.export_docx_failed",
            context: ["status": "\(http.statusCode)"]
        )
        throw SidecarError.serverError("Export failed (HTTP \(http.statusCode)).")
    }

    private struct ErrorDetail: Decodable {
        let detail: String
    }

    private static func makeSearchablePDFMultipartBody(
        sourceURL: URL,
        pagesString: String,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRReview-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        try write("--\(boundary)\r\n", to: output)
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(formSafeFilename(sourceURL.lastPathComponent))\"\r\n", to: output)
        try write("Content-Type: application/octet-stream\r\n\r\n", to: output)

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }

        try write("\r\n--\(boundary)\r\n", to: output)
        try write("Content-Disposition: form-data; name=\"pages_json\"\r\n\r\n", to: output)
        try write(pagesString, to: output)
        try write("\r\n--\(boundary)--\r\n", to: output)
        return bodyURL
    }

    private static func write(_ string: String, to handle: FileHandle) throws {
        if let data = string.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private static func formSafeFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }
}

private extension OCRDocument {
    struct ExportPage: Encodable {
        let page_number: Int
        let ocr_text: String
        let edited_text: String?
        let export_text: String
        let blocks: [ExportBlock]
    }

    struct ExportBlock: Encodable {
        let text: String
        let confidence: Float
        let bbox_normalized: [Double]?
        let is_redacted: Bool
    }

    func pagesForExport() -> [ExportPage] {
        pages.sorted { $0.pageNumber < $1.pageNumber }.map { page in
            ExportPage(
                page_number: page.pageNumber,
                ocr_text: page.ocrText,
                edited_text: page.editedText,
                export_text: page.exportText,
                blocks: page.blocks.map {
                    ExportBlock(
                        text: $0.text,
                        confidence: $0.confidence,
                        bbox_normalized: $0.bboxNormalized,
                        is_redacted: $0.isRedacted
                    )
                }
            )
        }
    }
}
