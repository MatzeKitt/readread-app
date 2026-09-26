import Foundation

/// The date formats an HTTP header may carry.
///
/// RFC 9110 names three and requires a recipient to accept all of them: the preferred
/// `IMF-fixdate`, and two obsolete forms that are still produced in the wild. Parsing only the
/// first is the kind of shortcut that works against every server anyone tests with and then fails
/// against the one somebody actually runs.
///
/// Its own type because two callers need it — `Retry-After`, which may be a date instead of a
/// delay, and the `Date` a response carries, which is the only shared reference this app has for
/// checking its own clock.
public enum HTTPDate {

    /// The formats, in the order RFC 9110 lists them.
    private static let formats = [
        // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        // RFC 850, obsolete: Sunday, 06-Nov-94 08:49:37 GMT
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        // asctime, obsolete: Sun Nov  6 08:49:37 1994
        "EEE MMM d HH:mm:ss yyyy",
    ]

    /// Parses an HTTP date, or answers `nil` for anything that is not one.
    ///
    /// The formatter is built per call rather than cached in a `static`. It is used once per
    /// network response at most, and a shared `DateFormatter` is mutable state that would have to
    /// be made safe to reach from several tasks at once — a cost with nothing to show for it at
    /// this rate.
    ///
    /// `en_US_POSIX` and GMT, both required: an HTTP date is always English and always UTC, and a
    /// formatter that takes the device's locale would fail to parse it on a phone set to German.
    public static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
