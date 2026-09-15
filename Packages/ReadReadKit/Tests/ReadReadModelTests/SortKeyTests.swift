import Foundation
import Testing

@testable import ReadReadModel

@Suite("SortKey")
struct SortKeyTests {

    /// The whole point of the type: string ordering must agree with numeric ordering, because the
    /// threshold count is a string comparison inside a SwiftData predicate.
    @Test("String order agrees with numeric order across digit-count boundaries")
    func stringOrderMatchesNumericOrder() {
        // Deliberately spans 1-, 4-, 10- and 13-digit values: unpadded, "999" > "1000"
        // lexicographically, which is exactly the bug the fixed width prevents.
        let millis: [Int64] = [0, 1, 9, 10, 99, 100, 999, 1_000, 1_700_000_000_000, 9_999_999_999_999]

        let keys = millis.map { SortKey(millis: $0, id: "x") }

        for (earlier, later) in zip(keys, keys.dropFirst()) {
            #expect(earlier < later, "\(earlier) should sort below \(later)")
        }
    }

    @Test("Same millisecond is disambiguated by id")
    func sameMillisecondTiesBreakOnID() {
        let first = SortKey(millis: 1_700_000_000_000, id: "aaa")
        let second = SortKey(millis: 1_700_000_000_000, id: "bbb")

        #expect(first < second)
        #expect(first != second)
    }

    @Test("Sentinels bracket every real key")
    func sentinelsBracketRealKeys() {
        let realKeys = [
            SortKey(millis: 0, id: ""),
            SortKey(millis: 1, id: "a"),
            SortKey(millis: 1_700_000_000_000, id: "zzzzzzzz"),
            SortKey(millis: SortKey.maxMillis, id: "zzzzzzzz"),
        ]

        for key in realKeys {
            #expect(SortKey.distantPast < key, "distantPast should sort below \(key)")
            #expect(key < SortKey.distantFuture, "\(key) should sort below distantFuture")
        }
        #expect(SortKey.distantPast < SortKey.distantFuture)
    }

    @Test("Components round-trip")
    func componentsRoundTrip() {
        let key = SortKey(millis: 1_700_000_000_123, id: "feed-item-7")

        #expect(key.millis == 1_700_000_000_123)
        #expect(key.id == "feed-item-7")
        #expect(SortKey(rawValue: key.rawValue) == key)
    }

    @Test("Date round-trips without drifting downward")
    func dateRoundTripsWithoutDrift() {
        // Truncating instead of rounding would walk a stored marker backwards a millisecond at a
        // time across repeated encode/decode cycles, slowly resurfacing already-read items.
        let date = Date(timeIntervalSince1970: 1_700_000_000.4567)
        let key = SortKey(date: date, id: "x")

        let recovered = SortKey(date: key.date!, id: "x")
        #expect(recovered == key)
    }

    /// Out-of-range input must degrade, not throw: one feed serving a broken date should not fail
    /// the ingest of the whole page it arrived in.
    @Test("Out-of-range milliseconds clamp instead of corrupting the key width", arguments: [
        (Int64(-1), Int64(0)),
        (Int64.min, Int64(0)),
        (SortKey.maxMillis + 1, SortKey.maxMillis),
        (Int64.max, SortKey.maxMillis),
    ])
    func outOfRangeMillisClamp(input: Int64, expected: Int64) {
        let key = SortKey(millis: input, id: "x")

        #expect(key.millis == expected)
        // Width must be preserved or ordering silently breaks for every other key.
        #expect(key.rawValue.prefix(while: { $0 != "|" }).count == SortKey.millisDigits)
    }

    @Test("Codable round-trips as a plain string")
    func codableRoundTrip() throws {
        let key = SortKey(millis: 1_700_000_000_000, id: "abc")

        let data = try JSONEncoder().encode(key)
        #expect(String(data: data, encoding: .utf8) == "\"\(key.rawValue)\"")
        #expect(try JSONDecoder().decode(SortKey.self, from: data) == key)
    }
}
