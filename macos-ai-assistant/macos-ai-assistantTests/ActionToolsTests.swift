import XCTest
@testable import macos_ai_assistant

final class ActionToolsTests: XCTestCase {
    // MARK: Dates

    func testActionDateParsesSupportedFormats() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let full = try XCTUnwrap(ActionDate.parse("2026-11-20 15:30", calendar: cal))
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: full).hour, 15)
        let iso = try XCTUnwrap(ActionDate.parse("2026-11-20T15:30", calendar: cal))
        XCTAssertEqual(full, iso)
        let bare = try XCTUnwrap(ActionDate.parse("2026-11-20", calendar: cal))
        XCTAssertEqual(cal.dateComponents([.hour], from: bare).hour, 9)
        XCTAssertNil(ActionDate.parse("tomorrow", calendar: cal))
    }

    // MARK: Open target

    func testOpenResolvesWebAndRejectsOtherSchemes() throws {
        XCTAssertEqual(try OpenTarget.resolve("https://example.com"), .url(URL(string: "https://example.com")!))
        XCTAssertThrowsError(try OpenTarget.resolve("file:///etc/passwd"))
        XCTAssertThrowsError(try OpenTarget.resolve("ssh://host"))
        XCTAssertThrowsError(try OpenTarget.resolve("javascript://x"))
    }

    func testOpenRefusesCodeBearingAndOutOfHomeFiles() {
        XCTAssertThrowsError(try OpenTarget.resolve("/Users/test/run.command", home: "/Users/test"))
        XCTAssertThrowsError(try OpenTarget.resolve("/Users/test/Tool.app", home: "/Users/test"))
        XCTAssertThrowsError(try OpenTarget.resolve("/etc/hosts", home: "/Users/test"))
        XCTAssertThrowsError(try OpenTarget.resolve("/Users/test/.ssh/config", home: "/Users/test"))
    }

    func testOpenFindsAppsOnlyInStandardFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Notes.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = try OpenTarget.resolve("Notes", appDirectories: [dir.path])
        XCTAssertEqual(found, .app(dir.appendingPathComponent("Notes.app")))
        XCTAssertThrowsError(try OpenTarget.resolve("Missing", appDirectories: [dir.path]))
        XCTAssertThrowsError(try OpenTarget.resolve("../Notes", appDirectories: [dir.path]),
                             "Path components in an app name must be rejected")
    }

    // MARK: Shortcuts

    func testShortcutAllowListIsExact() {
        let allowed = ["Morning Routine", "Toggle Dark Mode"]
        XCTAssertTrue(ShortcutRunner.isAllowed("Morning Routine", allowed: allowed))
        XCTAssertTrue(ShortcutRunner.isAllowed("  Toggle Dark Mode ", allowed: allowed))
        XCTAssertFalse(ShortcutRunner.isAllowed("morning routine", allowed: allowed))
        XCTAssertFalse(ShortcutRunner.isAllowed("Delete Everything", allowed: allowed))
        XCTAssertFalse(ShortcutRunner.isAllowed("", allowed: allowed))
        XCTAssertFalse(ShortcutRunner.isAllowed("Morning Routine", allowed: []))
    }

    // MARK: Web guard

    func testWebGuardClassifiesIPv4() {
        for blocked: [UInt8] in [[127, 0, 0, 1], [10, 1, 2, 3], [192, 168, 1, 1], [172, 16, 0, 1],
                                 [172, 31, 255, 1], [169, 254, 169, 254], [100, 64, 0, 1], [0, 0, 0, 0]] {
            XCTAssertFalse(WebGuard.isPublicIPv4(blocked), "\(blocked) must be blocked")
        }
        for allowed: [UInt8] in [[8, 8, 8, 8], [172, 32, 0, 1], [1, 1, 1, 1], [100, 63, 0, 1]] {
            XCTAssertTrue(WebGuard.isPublicIPv4(allowed), "\(allowed) must be allowed")
        }
    }

    func testWebGuardClassifiesIPv6() {
        var loopback = [UInt8](repeating: 0, count: 16); loopback[15] = 1
        XCTAssertFalse(WebGuard.isPublicIPv6(loopback))
        var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xfe; linkLocal[1] = 0x80
        XCTAssertFalse(WebGuard.isPublicIPv6(linkLocal))
        var ula = [UInt8](repeating: 0, count: 16); ula[0] = 0xfd
        XCTAssertFalse(WebGuard.isPublicIPv6(ula))
        var mappedPrivate = [UInt8](repeating: 0, count: 16)
        mappedPrivate[10] = 0xff; mappedPrivate[11] = 0xff
        mappedPrivate[12] = 10; mappedPrivate[15] = 1
        XCTAssertFalse(WebGuard.isPublicIPv6(mappedPrivate), "IPv4-mapped private must be blocked")
        var global = [UInt8](repeating: 0, count: 16); global[0] = 0x26; global[1] = 0x06
        XCTAssertTrue(WebGuard.isPublicIPv6(global))
    }

    func testWebGuardRejectsNonHTTPSAndLocalHosts() {
        XCTAssertThrowsError(try WebGuard.validate("http://example.com"))
        XCTAssertThrowsError(try WebGuard.validate("https://localhost/admin"))
        XCTAssertThrowsError(try WebGuard.validate("https://127.0.0.1/"))
        XCTAssertThrowsError(try WebGuard.validate("https://[::1]/"))
        XCTAssertThrowsError(try WebGuard.validate("https://printer.local/"))
        XCTAssertThrowsError(try WebGuard.validate("https://169.254.169.254/latest/meta-data"))
        XCTAssertThrowsError(try WebGuard.validate("ftp://example.com"))
    }

    func testHTMLTextExtractionDropsScriptsAndTags() {
        let html = "<html><head><style>p{color:red}</style><script>alert(1)</script></head><body><h1>Hi &amp; bye</h1><p>One\n  two</p></body></html>"
        XCTAssertEqual(HTMLText.extract(html), "Hi & bye One two")
    }

    // MARK: System info

    func testSystemInfoSummaryHasExpectedLines() {
        let summary = SystemInfo.summary()
        XCTAssertTrue(summary.contains("macOS:"))
        XCTAssertTrue(summary.contains("Battery:"))
        XCTAssertTrue(summary.contains("Disk:"))
        XCTAssertEqual(SystemInfo.uptimeText(90_000), "1d 1h")
    }
}
