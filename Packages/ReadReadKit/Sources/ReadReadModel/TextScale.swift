import Foundation

/// How large one kind of text should be drawn, relative to the system's own size for it.
///
/// A multiplier rather than a point size, and that is the whole design. Every place this is applied
/// starts from a Dynamic Type–resolved measurement and scales *that*, so someone who has already
/// set a system-wide text size keeps it — this shifts their baseline rather than replacing it.
/// Storing points instead would silently override an accessibility setting, which is the one thing
/// a text-size preference must not do.
public enum TextScale: String, Codable, Sendable, CaseIterable, Identifiable {

    case extraSmall
    case small
    case standard
    case large
    case extraLarge

    public var id: String { rawValue }

    /// What to multiply a resolved size by.
    ///
    /// Deliberately gentle at the ends. A range wide enough to be dramatic would let a heading
    /// come out smaller than the body text beneath it, and the steps are uniform-ish in ratio so
    /// each click of the picker feels like the same amount of change.
    public var multiplier: Double {
        switch self {
        case .extraSmall: 0.85
        case .small: 0.92
        case .standard: 1.0
        case .large: 1.12
        case .extraLarge: 1.25
        }
    }

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .extraSmall: String(localized: "Extra Small")
        case .small: String(localized: "Small")
        case .standard: String(localized: "Standard")
        case .large: String(localized: "Large")
        case .extraLarge: String(localized: "Extra Large")
        }
    }
}
