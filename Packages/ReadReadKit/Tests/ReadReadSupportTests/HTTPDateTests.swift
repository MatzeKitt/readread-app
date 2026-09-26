import Foundation
import Testing

@testable import ReadReadSupport

/// RFC 9110 requires a recipient to accept all three date formats, and two of the three are the
/// obsolete ones — which is exactly the kind of requirement that gets skipped because every server
/// anyone tests against sends the first.
@Suite("HTTP dates")
struct HTTPDateTests {

    /// The reference instant from RFC 9110's own examples, expressed three ways.
    private let reference = Date(timeIntervalSince1970: 784_111_777)

    @Test("The preferred format parses")
    func imfFixdate() {
        #expect(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT") == reference)
    }

    @Test("The obsolete RFC 850 format parses")
    func rfc850() {
        #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT") == reference)
    }

    @Test("The obsolete asctime format parses")
    func asctime() {
        #expect(HTTPDate.parse("Sun Nov  6 08:49:37 1994") == reference)
    }

    @Test("Surrounding whitespace is ignored")
    func trimsWhitespace() {
        #expect(HTTPDate.parse("  Sun, 06 Nov 1994 08:49:37 GMT ") == reference)
    }

    @Test("Anything else is not a date")
    func rejectsTheRest() {
        #expect(HTTPDate.parse("") == nil)
        #expect(HTTPDate.parse("120") == nil)
        #expect(HTTPDate.parse("tomorrow") == nil)
        #expect(HTTPDate.parse("1994-11-06T08:49:37Z") == nil, "ISO 8601 is not an HTTP date")
    }
}
