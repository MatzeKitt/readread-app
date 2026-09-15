import Foundation
import Testing

@testable import FreshRSSAPI

@Suite("GReaderItemID")
struct GReaderItemIDTests {

    @Test("Parses the tag-URI form emitted by stream/contents")
    func parsesTagURI() {
        let id = GReaderItemID("tag:google.com,2005:reader/item/0005fd1e3a2b4c10")

        #expect(id?.value == 1_685_681_150_315_536)
        #expect(id?.hexString == "0005fd1e3a2b4c10")
    }

    @Test("Parses the bare decimal form emitted by items/ids")
    func parsesDecimal() {
        #expect(GReaderItemID("1685681150315536")?.value == 1_685_681_150_315_536)
    }

    /// The reason this type exists. `stream/contents` and `items/ids` spell the same entry
    /// differently; if they do not converge, the reconciliation pass sees every item as missing and
    /// re-inserts the entire stream on each sync.
    @Test("Both endpoint spellings of one entry resolve to the same id")
    func spellingsConverge() {
        let fromContents = GReaderItemID("tag:google.com,2005:reader/item/0005fd1e3a2b4c10")
        let fromItemIDs = GReaderItemID("1685681150315536")

        #expect(fromContents == fromItemIDs)
        #expect(fromContents?.storageString == fromItemIDs?.storageString)
    }

    /// A decimal string is also syntactically valid hex, so parse order matters: reading `"10"` as
    /// hex would make it 16 and silently corrupt every short id, including the continuation cursor.
    @Test("An ambiguous numeric string is read as decimal, not hex", arguments: [
        ("10", UInt64(10)),
        ("11", UInt64(11)),
        ("99", UInt64(99)),
        ("1000", UInt64(1_000)),
    ])
    func ambiguousStringsReadAsDecimal(raw: String, expected: UInt64) {
        #expect(GReaderItemID(raw)?.value == expected)
    }

    @Test("Hex with letters is still recognised without the tag prefix")
    func bareHexWithLettersParses() {
        // Unambiguous: `abc` cannot be decimal, so falling through to hex is correct.
        #expect(GReaderItemID("abc")?.value == 0xabc)
    }

    @Test("Renders all three wire forms")
    func rendersWireForms() {
        let id = GReaderItemID(value: 1_685_681_150_315_536)

        #expect(id.hexString == "0005fd1e3a2b4c10")
        #expect(id.decimalString == "1685681150315536")
        #expect(id.tagURI == "tag:google.com,2005:reader/item/0005fd1e3a2b4c10")
    }

    @Test("Hex is always padded to 16 digits so ids sort consistently")
    func hexIsPadded() {
        #expect(GReaderItemID(value: 1).hexString == "0000000000000001")
        #expect(GReaderItemID(value: 1).hexString.count == 16)
    }

    /// Google Reader emitted signed decimal for ids above `Int64.max`, with hex as the
    /// two's-complement. FreshRSS never does, but honouring it keeps this usable against other
    /// Reader-compatible servers.
    @Test("Signed decimal above Int64.max round-trips through the hex form")
    func signedDecimalRoundTrips() {
        let signed = GReaderItemID("-1")
        let hex = GReaderItemID("tag:google.com,2005:reader/item/ffffffffffffffff")

        #expect(signed == hex)
        #expect(signed?.value == UInt64.max)
    }

    @Test("Whitespace is tolerated")
    func toleratesWhitespace() {
        #expect(GReaderItemID("  1685681150315536\n")?.value == 1_685_681_150_315_536)
    }

    @Test("Rejects input that is not an id", arguments: [
        "",
        "   ",
        "not-an-id",
        "tag:google.com,2005:reader/item/",
        "tag:google.com,2005:reader/item/zzzz",
        "12.5",
    ])
    func rejectsGarbage(raw: String) {
        #expect(GReaderItemID(raw) == nil)
    }

    @Test("Codable round-trips through the decimal form")
    func codableRoundTrips() throws {
        let id = GReaderItemID(value: 1_685_681_150_315_536)

        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"1685681150315536\"")
        #expect(try JSONDecoder().decode(GReaderItemID.self, from: data) == id)
    }

    @Test("Decoding an unparseable id throws rather than defaulting to zero")
    func decodingGarbageThrows() {
        // Defaulting would collapse every malformed id onto one key, so a single bad item would
        // start overwriting a real one.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GReaderItemID.self, from: Data(#""nonsense""#.utf8))
        }
    }

    @Test("Ordering follows numeric value, matching the server's id-descending walk")
    func orderingIsNumeric() {
        let ids = ["10", "1685680000000000", "1685681150315536"].compactMap(GReaderItemID.init)

        #expect(ids == ids.sorted())
    }
}
