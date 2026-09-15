#if os(macOS)
import AppKit
#endif
import Foundation

#if DEBUG
/// Temporary instrumentation for one bug: the timeline jumping a couple of rows towards the top
/// when a refresh lands while the reader is scrolling.
///
/// ## Why this exists rather than another fix
///
/// Three explanations fit that symptom exactly, and each one is repaired in a different place:
///
/// 1. The anchor pin correcting against a stale offset.
/// 2. A remote position being re-adopted. Ruled out — it needs another device to hold the winning
///    mark, and the bug reproduces in a scope the other device has never opened.
/// 3. A `List` re-applying its selection after an insertion and scrolling the selected row back
///    into view. The selected row's *index* shifts every time rows land above it, and AppKit's
///    `scrollRowToVisible` moves the minimum distance — which is what "a couple of items" and not
///    "to the very top" sounds like. Nothing in this app would appear in a stack trace for it.
///
/// The three cannot be told apart by reading the code, so this names whatever moved the list. Every
/// place that scrolls the timeline on purpose says so first through ``attribute(_:)``; the clip
/// view's movement is logged as it happens. **A movement with nothing attributed to it was made by
/// AppKit**, which is the only way to test the third explanation from outside.
///
/// Quiet unless something is arriving: the log opens for a second when items land and closes again,
/// because that is the only window the bug occurs in and every scroll frame would otherwise be a
/// line of output.
///
/// Compiled out of release builds entirely, and meant to be deleted once the cause is settled —
/// `grep -r ScrollDiagnostics`.
@MainActor
final class ScrollDiagnostics {

    static let shared = ScrollDiagnostics()

    /// How long after items arrive a movement is still interesting.
    private static let window: TimeInterval = 1

    /// Movements below this are the scroller settling, not a jump.
    private static let noise: CGFloat = 0.5

    private var openUntil: Date?
    private var cause: String?
    private var lastOrigin: CGFloat?
    private var lastHeight: CGFloat?

    private var isOpen: Bool {
        guard let openUntil else { return false }
        return Date() < openUntil
    }

    /// Starts logging, because items have landed.
    func open(_ reason: String) {
        openUntil = Date(timeIntervalSinceNow: Self.window)
        log("┌─ \(reason)")
    }

    /// Names whatever is about to move the list, so its movement is not reported as unexplained.
    ///
    /// Consumed by the next movement and not before: a scroll requested here arrives as a bounds
    /// change a moment later, and attributing it to the *following* movement instead would blame
    /// the wrong one for the rest of the window.
    func attribute(_ cause: String) {
        guard isOpen else { return }
        self.cause = cause
    }

    /// Drops a pending attribution, because whatever it named has finished moving the list.
    ///
    /// Without this an attribution outlives its cause and is claimed by the *next* movement,
    /// whoever made it — which is how "resize anchor (reflect)" came to be printed against a
    /// string of small movements that were the reader's own scrolling. Nothing was wrong with the
    /// correction; the log was libelling the reader.
    func clearAttribution() {
        cause = nil
    }

    func note(_ text: String) {
        guard isOpen else { return }
        log("│  \(text)")
    }

    /// Runs `work`, and reports how long it blocked for when that is long enough to be felt.
    ///
    /// A main-thread stall is the one thing the rest of this file cannot see: every other entry
    /// records where the list *ended up*, and a freeze is about how long it took to get there.
    ///
    /// Reported through ``open(_:)`` rather than ``note(_:)``, because a stall has no reason to
    /// coincide with a logging window that something else opened — and the interesting one happens
    /// on a scope change, when nothing is scrolling and the window is shut.
    ///
    /// The threshold keeps the ordinary case silent. The point is to catch the call that costs a
    /// tenth of a second, not to narrate every one that costs nothing.
    @discardableResult
    func time<T>(_ label: String, _ work: () -> T) -> T {
        let started = ContinuousClock.now
        let result = work()
        let elapsed = started.duration(to: .now)
        if elapsed > Self.stallThreshold {
            let line = String(format: "%@ blocked %.0f ms", label, elapsed / .milliseconds(1))
            if isOpen { note(line) } else { open(line) }
        }
        return result
    }

    /// Long enough to be seen as a stutter rather than only measured as one.
    private static let stallThreshold = Duration.milliseconds(50)

    private func log(_ text: String) {
        print("[readread-scroll] \(text)")
    }
}

#if os(macOS)
extension ScrollDiagnostics {

    /// Reports the list's content changing size.
    ///
    /// The measurement that was missing, and it is the one the reported symptom needs. A jump does
    /// not require the scroll offset to move: the offset is a distance from the top of the content,
    /// so if the content *above* the viewport changes height — rows above being realised and their
    /// estimated heights replaced by real ones, an item edited in place, the query re-ordering —
    /// then everything below shifts while the offset stays exactly where it was.
    ///
    /// ``movement(to:table:duringLiveScroll:)`` cannot see that, and neither could the log: it
    /// opened only when the item *count* changed, and this needs no count change at all. So a
    /// height change opens the window itself, and every reading of it carries the fold, which is
    /// where a shift with a constant offset becomes visible.
    func content(height: CGFloat, clipOrigin: CGFloat, fold: (row: Int, offset: CGFloat)?) {
        let previous = lastHeight
        lastHeight = height

        if let previous, abs(height - previous) > Self.noise {
            let line = String(format: "content height %.0f → %.0f", previous, height)
            if isOpen { log("│  " + line) } else { open(line) }
        }

        guard isOpen else { return }
        log(String(
            format: "│  geometry clipOrigin=%.1f height=%.0f fold=%@",
            clipOrigin,
            height,
            fold.map { String(format: "row %d at %.1f", $0.row, $0.offset) } ?? "–"
        ))
    }

    /// Reports a movement of the clip view, and who asked for it.
    ///
    /// - Parameter table: Read for context only when a movement is unexplained — the selected row
    ///   and the visible range are what distinguish "AppKit scrolled the selection into view" from
    ///   any other unexplained movement.
    /// - Parameter duringLiveScroll: Whether the reader had hold of the scroller. Without it an
    ///   unexplained movement is ambiguous in the one way that matters — the reader's own scrolling
    ///   arrives here exactly like AppKit's, and the first log could not tell them apart.
    func movement(to origin: CGFloat, table: NSTableView?, duringLiveScroll: Bool) {
        let previous = lastOrigin
        lastOrigin = origin
        let requested = cause
        cause = nil

        guard isOpen, let previous else { return }
        let delta = origin - previous
        guard abs(delta) > Self.noise else { return }

        if let requested {
            log(String(format: "│  moved %+.1f — %@", delta, requested))
            return
        }

        var detail = duringLiveScroll ? "READER" : "APPKIT"
        if let table {
            let visible = table.rows(in: table.visibleRect)
            detail += " selectedRow=\(table.selectedRow)"
                + " visible=\(visible.location)..<\(visible.location + visible.length)"
        }
        log(String(format: "│  moved %+.1f — %@", delta, detail))
    }
}
#endif

#else
/// The same surface, compiled to nothing.
@MainActor
final class ScrollDiagnostics {

    static let shared = ScrollDiagnostics()

    func open(_ reason: String) {}
    func attribute(_ cause: String) {}
    func clearAttribution() {}
    func note(_ text: String) {}

    @discardableResult
    func time<T>(_ label: String, _ work: () -> T) -> T { work() }
}

#if os(macOS)
extension ScrollDiagnostics {
    func content(height: CGFloat, clipOrigin: CGFloat, fold: (row: Int, offset: CGFloat)?) {}
    func movement(to origin: CGFloat, table: NSTableView?, duringLiveScroll: Bool) {}
}
#endif
#endif
