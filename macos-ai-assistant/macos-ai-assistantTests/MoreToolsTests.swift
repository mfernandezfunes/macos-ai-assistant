import XCTest
@testable import macos_ai_assistant

final class MoreToolsTests: XCTestCase {
    // MARK: Calculator

    func testArithmeticPrecedenceAndParentheses() throws {
        XCTAssertEqual(try ArithmeticParser.evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(try ArithmeticParser.evaluate("(2 + 3) * 4"), 20)
        XCTAssertEqual(try ArithmeticParser.evaluate("2 ^ 3 ^ 2"), 512)  // right-assoc
        XCTAssertEqual(try ArithmeticParser.evaluate("-3 + 10 % 4"), -1)
        XCTAssertEqual(try ArithmeticParser.evaluate("12.5 / 2.5"), 5, accuracy: 1e-9)
    }

    func testArithmeticRejectsBadInput() {
        XCTAssertThrowsError(try ArithmeticParser.evaluate("1 / 0"))
        XCTAssertThrowsError(try ArithmeticParser.evaluate("2 +"))
        XCTAssertThrowsError(try ArithmeticParser.evaluate("(2 + 3"))
        XCTAssertThrowsError(try ArithmeticParser.evaluate("2 $ 3"))
        XCTAssertThrowsError(try ArithmeticParser.evaluate(String(repeating: "1+", count: 150) + "1"))
        XCTAssertThrowsError(try ArithmeticParser.evaluate(String(repeating: "(", count: 100)))
    }

    func testArithmeticFormatting() {
        XCTAssertEqual(ArithmeticParser.format(14), "14")
        XCTAssertEqual(ArithmeticParser.format(1.0 / 3.0), "0.3333333333")
    }

    // MARK: Read file path validation

    func testReadFileAllowsFilesInHome() throws {
        let url = try ReadFileTool.validate(path: "/Users/test/Documents/a.txt", home: "/Users/test")
        XCTAssertEqual(url.path, "/Users/test/Documents/a.txt")
    }

    func testReadFileRejectsOutsideHomeAndTraversal() {
        XCTAssertThrowsError(try ReadFileTool.validate(path: "/etc/passwd", home: "/Users/test"))
        XCTAssertThrowsError(
            try ReadFileTool.validate(path: "/Users/test/../other/x.txt", home: "/Users/test"))
        XCTAssertThrowsError(
            try ReadFileTool.validate(path: "/Users/testing/x.txt", home: "/Users/test"),
            "A sibling directory sharing the home prefix must not pass")
    }

    func testReadFileRejectsLibraryAndHiddenFolders() {
        XCTAssertThrowsError(try ReadFileTool.validate(path: "/Users/test/.ssh/id_ed25519", home: "/Users/test"))
        XCTAssertThrowsError(try ReadFileTool.validate(path: "/Users/test/Library/Keychains/x", home: "/Users/test"))
        XCTAssertThrowsError(try ReadFileTool.validate(path: "/Users/test/proj/.env", home: "/Users/test"))
    }

    // MARK: Clipboard

    func testClipboardTruncatesLongText() {
        let long = String(repeating: "x", count: ClipboardTool.maxCharacters + 50)
        XCTAssertTrue(ClipboardTool.truncate(long).contains("truncated"))
        XCTAssertEqual(ClipboardTool.truncate("short"), "short")
    }

    // MARK: Tool router

    func testRouterSkipsRoutingForZeroOrOneTool() {
        XCTAssertFalse(ToolRouter.needsRouting(enabledCount: 0))
        XCTAssertFalse(ToolRouter.needsRouting(enabledCount: 1))
        XCTAssertTrue(ToolRouter.needsRouting(enabledCount: 2))
    }

    func testRouterResolveNeverExceedsEnabledSet() {
        let resolved = ToolRouter.resolve(
            selection: [.calendar, .clipboard, .calendar], enabled: [.calendar, .calculator])
        XCTAssertEqual(resolved, [.calendar], "Disabled tools are dropped and duplicates removed")
        XCTAssertTrue(ToolRouter.resolve(selection: [], enabled: [.calendar]).isEmpty)
    }

    func testRouterInstructionsListOnlyGivenTools() {
        let text = ToolRouter.instructions(for: [.calendar, .calculator])
        XCTAssertTrue(text.contains("calendar:"))
        XCTAssertTrue(text.contains("calculator:"))
        XCTAssertFalse(text.contains("clipboard:"))
    }
}
