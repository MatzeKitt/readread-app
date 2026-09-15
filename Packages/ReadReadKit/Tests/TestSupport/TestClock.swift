import Foundation

/// A `Clock` that returns from `sleep` immediately and records what it was asked to wait for.
///
/// Backoff and refresh cadences are behaviour worth asserting on — an exponential curve that
/// silently isn't exponential is a real bug — but waiting through them would make the suite take
/// minutes and turn timing into a source of flakiness. Recording the requested durations tests the
/// *decision* rather than the sleeping.
public final class TestClock: Clock, @unchecked Sendable {

    public struct Instant: InstantProtocol {

        public var offset: Duration

        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// Every duration passed to `sleep`, in order.
    ///
    /// `@unchecked Sendable` with a lock rather than an actor because `Clock` conformance requires
    /// synchronous `now` and `minimumResolution`, which an actor cannot provide.
    private let lock = NSLock()
    private var _sleeps: [Duration] = []
    private var _now = Instant()
    private var _sleepLimit: Int?

    public init() {}

    /// After this many sleeps, further sleeps **park** until the task is cancelled.
    ///
    /// Needed for repeating timer loops. A clock that always returns instantly turns
    /// `while true { sleep; work }` into a tight loop that runs thousands of iterations and swamps
    /// whatever the test was actually measuring. Setting a limit lets a test allow a known number
    /// of ticks and then hold time still.
    public var sleepLimit: Int? {
        get { lock.withLock { _sleepLimit } }
        set { lock.withLock { _sleepLimit = newValue } }
    }

    public var sleeps: [Duration] {
        lock.withLock { _sleeps }
    }

    public var sleepCount: Int {
        lock.withLock { _sleeps.count }
    }

    /// Total time the code under test believes has passed.
    public var elapsed: Duration {
        lock.withLock { _now.offset }
    }

    public func reset() {
        lock.withLock {
            _sleeps.removeAll()
            _now = Instant()
        }
    }

    // MARK: - Clock

    public var now: Instant {
        lock.withLock { _now }
    }

    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // Honour cancellation: retry loops must stop when their task is cancelled, and a clock
        // that ignores that would hide the bug where they don't.
        try Task.checkCancellation()

        let shouldPark: Bool = lock.withLock {
            let requested = _now.duration(to: deadline)
            if requested > .zero {
                _sleeps.append(requested)
                _now = deadline
            }
            guard let limit = _sleepLimit else { return false }
            return _sleeps.count > limit
        }

        if shouldPark {
            // Hold time still until the caller is cancelled. A real sleep rather than a
            // yield-loop so a parked timer costs nothing while the test does its work.
            try await Task.sleep(for: .seconds(30))
            return
        }

        // Yield so cancellation and other tasks still get a chance to run, without real delay.
        await Task.yield()
    }
}
