import Foundation
import PDFKit
import Vision
import AppKit

/// Turns a user-chosen file into plain text for the model: PDFKit for PDFs,
/// Vision OCR for images, UTF-8 for text-like files. Output is capped because
/// the on-device context window is small.
nonisolated enum AttachmentExtractor {
    struct Extracted: Equatable, Sendable {
        let name: String
        let text: String
        let truncated: Bool
    }

    enum ExtractionError: LocalizedError {
        case unsupported(String)
        case empty(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let n): return "\(n): unsupported file type."
            case .empty(let n): return "\(n): no text could be extracted."
            case .tooLarge(let n): return "\(n): file is too large (limit 25 MB)."
            }
        }
    }

    static let maxCharacters = 5000
    static let maxFileBytes = 25_000_000
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "json", "xml", "yml", "yaml", "log", "swift", "py", "js", "ts",
        "html", "css", "sh", "java", "kt", "go", "rs", "c", "h", "cpp", "sql", "toml", "ini",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"]

    static func extract(from url: URL) async throws -> Extracted {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileBytes else { throw ExtractionError.tooLarge(name) }

        let raw: String
        if ext == "pdf" {
            raw = try pdfText(url, name: name)
        } else if imageExtensions.contains(ext) {
            raw = try await ocrText(url, name: name)
        } else if textExtensions.contains(ext) {
            let data = try Data(contentsOf: url)
            raw = String(decoding: data, as: UTF8.self)
        } else {
            throw ExtractionError.unsupported(name)
        }

        let (text, truncated) = cap(raw)
        guard !text.isEmpty else { throw ExtractionError.empty(name) }
        return Extracted(name: name, text: text, truncated: truncated)
    }

    static func cap(_ raw: String, limit: Int = maxCharacters) -> (String, Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return (trimmed, false) }
        return (String(trimmed.prefix(limit)), true)
    }

    /// The block appended to a user prompt so the model can see the files.
    static func promptBlock(_ items: [Extracted]) -> String {
        items.map { item in
            let note = item.truncated ? " (truncated)" : ""
            return "[Attached file: \(item.name)\(note)]\n\(item.text)\n[End of file]"
        }.joined(separator: "\n\n")
    }

    private static func pdfText(_ url: URL, name: String) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ExtractionError.unsupported(name) }
        var out = ""
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index)?.string else { continue }
            out += page + "\n"
            if out.count > maxCharacters * 2 { break }  // enough; avoid walking huge PDFs
        }
        return out
    }

    private static func ocrText(_ url: URL, name: String) async throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ExtractionError.unsupported(name) }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
