import Foundation
import Testing

@testable import ReadReadModel

/// The raw form is the wire format for `PositionMark` keys and sync records, so a round-trip bug
/// here would silently orphan reading positions after an update.
@Suite("ScopeID")
struct ScopeIDTests {

    @Test("Every case round-trips through its raw value", arguments: [
        ScopeID.all,
        .readLater,
        .lateArrivals,
        .folder("News"),
        .source("freshrss:E621E1F8-C36C-495A-93FC-0C247A3E6E5F:feed/12"),
        .mastodonHome(accountID: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!),
    ])
    func roundTripsThroughRawValue(scope: ScopeID) {
        #expect(ScopeID(rawValue: scope.rawValue) == scope)
    }

    /// Source ids contain colons (`feed/12`, and the `provider:account:` namespace), and folder
    /// names are free text a user chose. Splitting on the separator would corrupt both.
    @Test("Payloads containing the separator survive intact", arguments: [
        "Tech: Long Reads",
        "a:b:c:d",
        "::",
    ])
    func payloadsContainingColonsSurvive(name: String) {
        let scope = ScopeID.folder(name)

        #expect(ScopeID(rawValue: scope.rawValue) == .folder(name))
    }

    @Test("Malformed raw values are rejected rather than silently becoming a wrong scope", arguments: [
        "",
        "nonsense",
        "folder:",
        "source:",
        "mastodon-home:",
        "mastodon-home:not-a-uuid",
        "Folder:News",
    ])
    func malformedValuesAreRejected(raw: String) {
        #expect(ScopeID(rawValue: raw) == nil)
    }

    @Test("Distinct cases never collide on their raw form")
    func casesDoNotCollide() {
        let scopes: [ScopeID] = [
            .all,
            .readLater,
            .lateArrivals,
            .folder("x"),
            .source("x"),
            .mastodonHome(accountID: UUID()),
        ]

        #expect(Set(scopes.map(\.rawValue)).count == scopes.count)
    }

    @Test("Decoding an unknown scope throws instead of defaulting")
    func decodingUnknownScopeThrows() {
        // Defaulting to `.all` would quietly redirect one scope's saved position onto the unified
        // timeline, which is worse than surfacing the error.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ScopeID.self, from: Data(#""bogus""#.utf8))
        }
    }

    @Test("Codable round-trips")
    func codableRoundTrips() throws {
        let scope = ScopeID.source("freshrss:x:feed/1")

        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(ScopeID.self, from: data) == scope)
    }
}
