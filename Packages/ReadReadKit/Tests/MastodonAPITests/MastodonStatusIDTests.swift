import Foundation
import Testing

@testable import MastodonAPI

/// Ordering is the whole reason this type exists. The stop line compares ids to decide when a walk
/// has reached already-known statuses, so getting the comparison wrong either re-ingests the
/// timeline every refresh or skips most of a page.
@Suite("MastodonStatusID")
struct MastodonStatusIDTests {

    /// The bug the guidelines' length-first rule prevents: plain lexicographic order puts `"9999"`
    /// above `"10000"`, so a stop line of `"10000"` would treat older statuses as newer and stop
    /// the walk immediately.
    @Test("Longer numeric ids sort above shorter ones")
    func lengthDominatesLexicalOrder() {
        let shorter = MastodonStatusID("9999")
        let longer = MastodonStatusID("10000")

        #expect(shorter < longer)
        // Confirm the naive comparison really would have been wrong.
        #expect(longer.rawValue < shorter.rawValue)
    }

    @Test("Equal-length ids sort lexically")
    func equalLengthSortsLexically() {
        #expect(MastodonStatusID("110451234567890001") < MastodonStatusID("110451234567890002"))
    }

    @Test("A snowflake sequence sorts ascending")
    func snowflakeSequenceSorts() {
        let ids = ["1", "9", "10", "99", "100", "110451234567890001", "110451234567890002"]
            .map(MastodonStatusID.init)

        #expect(ids == ids.sorted())
    }

    /// Not every implementation of this API uses numbers. GoToSocial and Akkoma use ULIDs and
    /// base-62 values, which is exactly why ids are never parsed as integers.
    @Test("Non-numeric ids still order deterministically")
    func nonNumericIDsOrder() {
        let ulids = ["01H8Q0AAAAAAAAAAAAAAAAAAAA", "01H8Q0BBBBBBBBBBBBBBBBBBBB"]
            .map(MastodonStatusID.init)

        #expect(ulids[0] < ulids[1])
        // Same length, so lexical order decides — which is correct for ULIDs by construction.
        #expect(ulids[0].rawValue.count == ulids[1].rawValue.count)
    }

    /// An empty id is how "no stop line yet" is expressed, so it must sort below every real id or
    /// a first-ever walk would stop before fetching anything.
    @Test("An empty id sorts below everything")
    func emptyIDSortsLowest() {
        let empty = MastodonStatusID("")

        #expect(empty.isEmpty)
        for raw in ["0", "1", "110451234567890001", "01H8Q0AAAAAAAAAAAAAAAAAAAA"] {
            #expect(empty < MastodonStatusID(raw))
        }
    }

    @Test("Comparison is a strict weak ordering")
    func comparisonIsConsistent() {
        let a = MastodonStatusID("100")
        let b = MastodonStatusID("100")

        #expect(!(a < b))
        #expect(!(b < a))
        #expect(a == b)
    }

    @Test("Codable round-trips as a plain string")
    func codableRoundTrips() throws {
        let id = MastodonStatusID("110451234567890001")

        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"110451234567890001\"")
        #expect(try JSONDecoder().decode(MastodonStatusID.self, from: data) == id)
    }
}
