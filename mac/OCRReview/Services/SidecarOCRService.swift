import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum SidecarOCRService {
    /// Recognize a PDF page through the sidecar, reusing the already-loaded page (no disk re-parse).
    static func recognize(pdfPage: PDFPage, pageNumber: Int, engine: String) async throws -> OCRPage {
        guard let cgImage = VisionOCRService.renderPage(pdfPage, scale: 2.0) else {
            throw OCRError.renderFailed
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw OCRError.renderFailed
        }
        let markdown = try await convert(data: png, filename: "page-\(pageNumber).png", engine: engine)
        return OCRPage(pageNumber: pageNumber, ocrText: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Recognize a pre-rendered page image through the sidecar. Render the shared
    /// on-screen document on the main actor, then hand the CGImage here.
    static func recognize(cgImage: CGImage, pageNumber: Int, engine: String) async throws -> OCRPage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw OCRError.renderFailed
        }
        let markdown = try await convert(data: png, filename: "page-\(pageNumber).png", engine: engine)
        return OCRPage(pageNumber: pageNumber, ocrText: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func recognize(imageURL url: URL, pageNumber: Int = 1, engine: String) async throws -> OCRPage {
        let data = try Data(contentsOf: url)
        let markdown = try await convert(data: data, filename: url.lastPathComponent, engine: engine)
        return OCRPage(pageNumber: pageNumber, ocrText: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func convert(data: Data, filename: String, engine: String) async throws -> String {
        guard let endpoint = URL(string: "\(SidecarConfig.baseURL)/v1/convert") else {
            throw SidecarError.invalidResponse
        }

        let boundary = "OCRReview-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            if let chunk = string.data(using: .utf8) { body.append(chunk) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n")
        append(engine)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"embed_images\"\r\n\r\n")
        append("false")
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SidecarError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SidecarError.invalidResponse
        }

        if http.statusCode == 200 {
            let decoded = try JSONDecoder().decode(ConvertResponse.self, from: responseData)
            return decoded.markdown
        }

        if let detail = try? JSONDecoder().decode(ErrorDetail.self, from: responseData) {
            throw SidecarError.serverError(detail.detail)
        }
        throw SidecarError.serverError("OCR failed (HTTP \(http.statusCode)).")
    }

    private struct ConvertResponse: Decodable {
        let markdown: String
    }

    private struct ErrorDetail: Decodable {
        let detail: String
    }
}
