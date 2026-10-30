import Foundation

/// Who is moving the timeline right now, and therefore what else may touch it.
///
/// ## The rule this enforces
///
/// The reader and the app never move the list at the same time, and only the reader's movement is
/// ever written down as a position.
///
/// - While the reader has hold of the list (``Phase/interacting``) nothing programmatic happens:
///   no new rows, no restore, no adopting another device's position. That is what keeps the list
///   from jumping under the finger.
/// - Programmatic moves (``Phase/positioning``, ``Phase/programmatic``) never produce a position.
///   They reproduce one that is already on record, and writing it again would give a stale place a
///   fresh timestamp, which then wins on every device.
/// - A position is written only when an interaction ends — see ``userEnded(at:)`` — so a fold read
///   from a list that is empty, still laying out or being repositioned is never recorded.
///
/// A value type with the clock passed in, so every rule here can be tested without a list.
public struct ViewportGate: Sendable {

    public enum Phase: Equatable, Sendable {

        /// The list is being placed at its stored position and is not yet visible.
        case positioning

        /// Nobody is moving the list.
        case idle

        /// The reader is: dragging, flinging, using the scroller or the keyboard.
        case interacting

        /// The app is: applying a snapshot or adopting a position.
        case programmatic
    }

    /// How long the list has to be left alone before the app may touch it.
    public static let quietDelay = Duration.milliseconds(500)

    public private(set) var phase: Phase = .positioning

    /// When the reader last stopped moving the list, or `nil` before they ever have.
    public private(set) var lastInteractionEnd: ContinuousClock.Instant?

    /// When the list was first shown, which counts as the start of being left alone.
    public private(set) var shownAt: ContinuousClock.Instant?

    /// Whether the app is in the foreground. Nothing programmatic happens in the background, where
    /// the reader cannot see what it did.
    public var isAppActive = true

    /// Whether the list has a size. A zero-sized list has no fold, and laying one out produces
    /// readings that mean nothing.
    public var hasViewport = false

    public init() {}

    // MARK: - Transitions

    /// The list has been placed and is about to become visible.
    public mutating func positioned(at now: ContinuousClock.Instant) {
        guard phase == .positioning else { return }
        phase = .idle
        shownAt = now
    }

    /// The reader has taken hold of the list.
    ///
    /// Accepted in every phase: the reader always wins. A restore or an apply in progress is
    /// abandoned by its owner when it sees the phase change.
    public mutating func userBegan() {
        phase = .interacting
    }

    /// The reader has let go and the list has come to rest.
    ///
    /// - Returns: Whether the fold should now be read and recorded. `false` when no interaction was
    ///   in progress, which is what keeps a programmatic settle from being written down.
    @discardableResult
    public mutating func userEnded(at now: ContinuousClock.Instant) -> Bool {
        guard phase == .interacting else { return false }
        phase = .idle
        lastInteractionEnd = now
        if shownAt == nil { shownAt = now }
        return hasViewport
    }

    /// Asks to move the list programmatically.
    ///
    /// - Returns: Whether it may. On `true` the caller must call ``endProgrammatic()`` when done,
    ///   synchronously — an apply or an adoption is one layout pass, not an animation.
    public mutating func beginProgrammatic(at now: ContinuousClock.Instant) -> Bool {
        guard isQuiet(at: now) else { return false }
        phase = .programmatic
        return true
    }

    /// Starts a move the reader asked for, such as a menu command.
    ///
    /// Skips the quiet period — the reader is the one asking — but is still programmatic, so it
    /// writes nothing: going back to a stored position is not a new report of it.
    public mutating func beginRequested() -> Bool {
        guard phase == .idle || phase == .interacting, hasViewport else { return false }
        phase = .programmatic
        return true
    }

    public mutating func endProgrammatic() {
        guard phase == .programmatic else { return }
        phase = .idle
    }

    // MARK: - Questions

    /// Whether the app may touch the list now.
    public func isQuiet(at now: ContinuousClock.Instant) -> Bool {
        guard phase == .idle, isAppActive, hasViewport else { return false }
        guard let since = lastInteractionEnd ?? shownAt else { return true }
        return since.duration(to: now) >= Self.quietDelay
    }

    /// How long the reader has left the list alone, or `nil` while they have hold of it.
    public func timeLeftAlone(at now: ContinuousClock.Instant) -> Duration? {
        guard phase != .interacting else { return nil }
        guard let since = lastInteractionEnd ?? shownAt else { return nil }
        return since.duration(to: now)
    }

    /// Whether a fold read from the screen right now is the reader's own doing.
    ///
    /// True while they scroll, so the count follows them live, and when nobody is moving the list.
    /// False while it is being positioned or moved by the app, whose fold is known in advance and is
    /// set rather than read.
    public var mayReadFold: Bool {
        phase == .interacting || phase == .idle
    }
}
