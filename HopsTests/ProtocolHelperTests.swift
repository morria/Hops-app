import XCTest
import MeshtasticProtobufs
@testable import Hops

@MainActor
final class ProtocolHelperTests: XCTestCase {

    func testMeshNameClampsByBytesNotCharacters() {
        XCTAssertEqual(MeshName.clampShort("ABCDE"), "ABCD")
        XCTAssertEqual(MeshName.clampShort("🐇A"), "🐇")
        XCTAssertEqual(MeshName.clampShort("🇺🇸"), "", "a flag is 8 bytes")
        XCTAssertEqual(MeshName.clampLong(String(repeating: "x", count: 45)).utf8.count, 39)
    }

    func testMeshURLAddModeRoundTrip() {
        let url = MeshURL.encodeSingle(name: "Collapse", psk: Data([1]))!
        XCTAssertTrue(url.contains("?add=true#"))
        let link = MeshURL.parseLink(url)!
        XCTAssertTrue(link.add)
        XCTAssertEqual(link.channelSet.settings.count, 1)
        XCTAssertEqual(link.channelSet.settings[0].name, "Collapse")
        // A full link with LoRa config is a replace, not an add.
        var set = ChannelSet()
        set.settings = [ChannelSettings()]
        set.loraConfig = Config.LoRaConfig()
        set.loraConfig.region = .us
        let full = MeshURL.encode(set)!
        XCTAssertFalse(MeshURL.parseLink(full)!.add)
    }

    func testRoutingFailureWordsKnownCodes() {
        XCTAssertTrue(RoutingFailure.short(code: 35, isDM: true).contains("didn't have your key"))
        XCTAssertTrue(RoutingFailure.short(code: 39, isDM: true).contains("doesn't have their key"))
        XCTAssertEqual(RoutingFailure.short(code: -1, isDM: true), "No response")
    }

    #if MESHSITES
    func testPartialPageDecodesPrefixAndWithholdsOpenForm() {
        let page = "# Title\n\nHello there, this is a page.\n\n[form post /reply]\n[field name Name]\n[submit Send]\n[/form]\n\nAfter.\n"
        let compressed = MeshsitesWire.deflate(Data(page.utf8))
        XCTAssertFalse(compressed.isEmpty)
        // Whole stream decodes fully.
        XCTAssertEqual(MeshsitesManager.inflatePrefix(compressed).map { String(decoding: $0, as: UTF8.self) }, page)
        // A truncated stream decodes to a prefix of the page.
        let half = compressed.prefix(compressed.count / 2)
        if let prefix = MeshsitesManager.inflatePrefix(half), !prefix.isEmpty {
            let text = MeshsitesManager.utf8Prefix(prefix)!
            XCTAssertTrue(page.hasPrefix(text))
            let lines = MeshsitesManager.wholeLines(text)
            XCTAssertTrue(lines.isEmpty || lines.hasSuffix("\n"))
        }
        // Partial parse drops a form left open at the bottom edge.
        let cut = "# Title\n\n[form post /reply]\n[field name Name]\n"
        XCTAssertFalse(MeshdownDocument.parse(cut, partial: true).items.contains { if case .form = $0.block { return true }; return false })
        XCTAssertTrue(MeshdownDocument.parse(cut, partial: false).items.contains { if case .form = $0.block { return true }; return false })
    }
    #endif
}
