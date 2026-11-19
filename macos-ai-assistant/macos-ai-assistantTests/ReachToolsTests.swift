import XCTest
import Contacts
import MapKit
import FoundationModels
@testable import macos_ai_assistant

final class ReachToolsTests: XCTestCase {
    func testNetworkSummary() {
        XCTAssertEqual(NetworkInfo.summary(from: []), "Network: no active IPv4 interface (offline?)")
        let list = [NetworkInfo.Interface(name: "en0", address: "192.168.1.5", isIPv6: false),
                    NetworkInfo.Interface(name: "en0", address: "2001::1", isIPv6: true)]
        XCTAssertEqual(NetworkInfo.summary(from: list), "Network: en0 192.168.1.5")
        XCTAssertTrue(SystemInfo.summary().contains("Network:"))
    }

    func testSearchParser() {
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&amp;rut=abc">Example <b>Title</b></a>
        <a class="result__snippet" href="x">A &amp; B snippet</a>
        <a class="result__a" href="https://other.org/p">Other</a>
        <a class="result__a" href="http://insecure.org/">Insecure</a>
        """
        let r = WebSearchParser.parse(html)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0], .init(title: "Example Title", url: "https://example.com/a?x=1", snippet: "A & B snippet"))
        XCTAssertEqual(r[1].url, "https://other.org/p")
        XCTAssertTrue(WebSearchParser.parse("<html>nothing</html>").isEmpty)
        XCTAssertEqual(WebSearchParser.parse(html, limit: 1).count, 1)
    }

    func testMapsFormatting() {
        XCTAssertEqual(MapsFormat.duration(20), "1 min")
        XCTAssertEqual(MapsFormat.duration(25 * 60), "25 min")
        XCTAssertEqual(MapsFormat.duration(95 * 60), "1 h 35 min")
        XCTAssertEqual(MapsFormat.transport("Walking"), .walking)
        XCTAssertEqual(MapsFormat.transport("by bus"), .transit)
        XCTAssertEqual(MapsFormat.transport("driving"), .automobile)
        XCTAssertTrue(MapsFormat.distance(12_000, locale: Locale(identifier: "es_AR")).contains("12"))
    }

    func testContactFormat() {
        let c = CNMutableContact()
        c.givenName = "Ana"; c.familyName = "Garcia"; c.organizationName = "ACME"
        c.phoneNumbers = [CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "+54 11 5555 0000"))]
        c.emailAddresses = [CNLabeledValue(label: nil, value: "ana@acme.com" as NSString)]
        XCTAssertEqual(ContactsLookup.format(c),
                       "Ana Garcia — org: ACME — phone: +54 11 5555 0000 — email: ana@acme.com")
    }

    func testNewToolsApprovalPolicy() {
        XCTAssertTrue(AssistantToolID.webSearch.alwaysRequiresApproval)
        XCTAssertFalse(AssistantToolID.contacts.alwaysRequiresApproval)
        XCTAssertTrue(AssistantToolID.contacts.requiresApprovalByDefault)
        XCTAssertTrue(AssistantToolID.maps.requiresApprovalByDefault)
        XCTAssertEqual(AssistantToolFactory.makeTools(for: [.contacts, .webSearch, .maps]).map(\.name).sorted(),
                       ["findContact", "getTravelTime", "searchWeb"])
    }
}
