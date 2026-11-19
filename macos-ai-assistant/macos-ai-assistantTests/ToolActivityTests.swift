import XCTest
@testable import macos_ai_assistant

@MainActor
final class ToolActivityTests: XCTestCase {
    func testApprovalAllowsCall() async {
        let center = ToolActivityCenter()
        let id = center.begin(.spotlightSearch, detail: "Search files for “x”")
        async let result = center.requestApproval(for: id, tool: .spotlightSearch, detail: "d")
        await Task.yield()
        XCTAssertEqual(center.pendingApproval?.id, id)
        center.resolve(id, approved: true)
        let approved = await result
        XCTAssertTrue(approved)
        XCTAssertNil(center.pendingApproval)
        XCTAssertEqual(center.events.first?.status, .running)
    }

    func testDenialMarksEventDenied() async {
        let center = ToolActivityCenter()
        let id = center.begin(.spotlightSearch, detail: "d")
        async let result = center.requestApproval(for: id, tool: .spotlightSearch, detail: "d")
        await Task.yield()
        center.resolve(id, approved: false)
        let approved = await result
        XCTAssertFalse(approved)
        XCTAssertEqual(center.events.first?.status, .denied)
    }

    func testUnansweredRequestIsDeniedAfterTimeout() async {
        let center = ToolActivityCenter()
        center.approvalTimeout = .milliseconds(50)
        let id = center.begin(.spotlightSearch, detail: "d")
        let approved = await center.requestApproval(for: id, tool: .spotlightSearch, detail: "d")
        XCTAssertFalse(approved)
        XCTAssertNil(center.pendingApproval)
    }

    func testResolveIsIdempotent() async {
        let center = ToolActivityCenter()
        let id = center.begin(.spotlightSearch, detail: "d")
        async let result = center.requestApproval(for: id, tool: .spotlightSearch, detail: "d")
        await Task.yield()
        center.resolve(id, approved: true)
        center.resolve(id, approved: false)  // must not crash or flip the result
        let approved = await result
        XCTAssertTrue(approved)
    }

    func testSpotlightRequiresConfirmationByDefault() {
        let defaults = UserDefaults(suiteName: "ToolActivityTests-\(UUID().uuidString)")!
        XCTAssertEqual(
            ToolSettings.currentConfirmationIDs(defaults: defaults),
            [.spotlightSearch, .clipboard, .readFile, .calendar, .reminders])
        XCTAssertFalse(ToolSettings.currentConfirmationIDs(defaults: defaults).contains(.calculator))
    }
}
