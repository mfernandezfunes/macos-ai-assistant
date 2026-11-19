import XCTest
import AppKit
import PDFKit
@testable import macos_ai_assistant

final class ConversationExportTests: XCTestCase {
    private func sample() -> ConversationSnapshot {
        ConversationSnapshot(
            title: "Trip: Paris/Rome?", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            systemInstructions: "Be brief.\nReally.",
            messages: [
                .init(role: "user", content: "Hola", createdAt: Date(timeIntervalSince1970: 1_700_000_001), attachments: ["a.pdf"]),
                .init(role: "assistant", content: "Hi **there**", createdAt: Date(timeIntervalSince1970: 1_700_000_002), attachments: []),
            ])
    }

    func testJSONRoundTrip() throws {
        let data = try ConversationExport.json(sample())
        XCTAssertEqual(try ConversationExport.decode(data), sample())
    }

    func testDecodeRejectsGarbageAndFutureVersions() throws {
        XCTAssertThrowsError(try ConversationExport.decode(Data("nope".utf8)))
        var future = sample(); future.version = 99
        XCTAssertThrowsError(try ConversationExport.decode(try ConversationExport.json(future)))
    }

    func testMarkdown() {
        let md = ConversationExport.markdown(sample())
        XCTAssertTrue(md.hasPrefix("# Trip: Paris/Rome?"))
        XCTAssertTrue(md.contains("> **System instructions:** Be brief.\n> Really."))
        XCTAssertTrue(md.contains("## You"))
        XCTAssertTrue(md.contains("_Attachments: a.pdf_"))
        XCTAssertTrue(md.contains("## Assistant\n\nHi **there**"))
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(ConversationExport.fileName(for: sample()), "Trip  Paris Rome")
        var empty = sample(); empty.title = ""
        XCTAssertEqual(ConversationExport.fileName(for: empty), "Conversation")
    }

    func testMakeFromSnapshotKeepsOrderAndRoles() {
        let (conversation, messages) = Conversation.make(from: sample())
        XCTAssertEqual(conversation.title, "Trip: Paris/Rome?")
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages[0].attachmentNames, "a.pdf")
    }

    func testSearch() {
        XCTAssertTrue(ConversationSearch.matches(title: "Viaje", messages: ["Café con leche"], query: "cafe"))
        XCTAssertTrue(ConversationSearch.matches(title: "Viaje", messages: [], query: "VIAJ"))
        XCTAssertFalse(ConversationSearch.matches(title: "Viaje", messages: ["hola"], query: "zzz"))
        XCTAssertTrue(ConversationSearch.matches(title: "x", messages: [], query: "  "))
    }
}

final class AttachmentExtractorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testTextFileAndTruncation() async throws {
        let url = dir.appendingPathComponent("n.txt")
        try String(repeating: "a", count: 6000).write(to: url, atomically: true, encoding: .utf8)
        let r = try await AttachmentExtractor.extract(from: url)
        XCTAssertEqual(r.text.count, AttachmentExtractor.maxCharacters)
        XCTAssertTrue(r.truncated)
        XCTAssertTrue(AttachmentExtractor.promptBlock([r]).contains("[Attached file: n.txt (truncated)]"))
    }

    func testUnsupportedType() async throws {
        let url = dir.appendingPathComponent("x.bin")
        try Data([0, 1, 2]).write(to: url)
        do { _ = try await AttachmentExtractor.extract(from: url); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("unsupported")) }
    }

    func testEmptyTextFileIsRejected() async throws {
        let url = dir.appendingPathComponent("e.txt")
        try "  \n".write(to: url, atomically: true, encoding: .utf8)
        do { _ = try await AttachmentExtractor.extract(from: url); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("no text")) }
    }

    func testPDFText() async throws {
        let url = dir.appendingPathComponent("d.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: "Invoice 12345", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attr.draw(at: NSPoint(x: 20, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        try (data as Data).write(to: url)
        let r = try await AttachmentExtractor.extract(from: url)
        XCTAssertTrue(r.text.contains("Invoice 12345"), r.text)
    }

    func testImageOCR() async throws {
        let url = dir.appendingPathComponent("i.png")
        let image = NSImage(size: NSSize(width: 500, height: 120))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 500, height: 120).fill()
        NSAttributedString(string: "Hello OCR 2026", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: 20, y: 30))
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        let r = try await AttachmentExtractor.extract(from: url)
        XCTAssertTrue(r.text.contains("OCR"), r.text)
    }
}
