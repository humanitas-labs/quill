import Foundation

/// Wall-clock deadline for a "record for a fixed duration" session. Pure
/// value type so the expiry and label logic is unit-testable without a
/// recording session; the AppController polls `isExpired` from its existing
/// 1s ticker, which keeps the deadline correct across system sleep.
struct StopTimer {
    let deadline: Date

    /// Seconds left until the deadline, clamped so it never goes negative.
    func remaining(at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    func isExpired(at now: Date) -> Bool {
        now >= deadline
    }

    /// A new timer with the deadline pushed out by `seconds`, extending from
    /// the existing deadline rather than from now.
    func extended(by seconds: TimeInterval) -> StopTimer {
        StopTimer(deadline: deadline.addingTimeInterval(seconds))
    }

    /// Human label for a duration in seconds ("10 minutes", "1 hour",
    /// "90 minutes", "2 hours"). Used for the menu item titles and the
    /// timer-finished notification.
    static func label(for duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds % 3600 == 0 {
            let h = seconds / 3600
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        return "\(seconds / 60) minutes"
    }
}
