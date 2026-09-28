import Foundation

/// Monotonic session clock. All capture offsets and gap calculations derive
/// from one mach host-time baseline captured when the session starts, so a
/// wall-clock adjustment mid-meeting can never move segments relative to one
/// another. `Date` remains only for human-readable metadata fields.
struct SessionClock: Sendable {
    let baseHostTime: UInt64
    private let numer: UInt64
    private let denom: UInt64

    /// Capture the baseline "now" as session time zero.
    static func started() -> SessionClock {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return SessionClock(
            baseHostTime: mach_absolute_time(),
            numer: UInt64(info.numer),
            denom: UInt64(info.denom)
        )
    }

    /// Milliseconds since the session baseline for a mach host timestamp.
    /// Timestamps before the baseline clamp to zero.
    func millis(atHostTime hostTime: UInt64) -> Int {
        guard hostTime > baseHostTime else { return 0 }
        let elapsed = hostTime - baseHostTime
        return Int(elapsed * numer / (denom * 1_000_000))
    }

    /// Milliseconds elapsed since the session baseline.
    func nowMs() -> Int {
        millis(atHostTime: mach_absolute_time())
    }
}

/// Which capture path a track records. The two live tracks are deliberately
/// independent: one can recover or degrade while the other stays healthy.
/// `memo` is an imported recording (e.g. an AirDropped Voice Memo): one
/// room microphone, so it has no me/them split.
enum TrackKind: String, Codable, CaseIterable, Sendable {
    case mic
    case system
    case memo

    /// Speaker label used in transcripts.
    var speaker: String {
        switch self {
        case .mic: return "me"
        case .system: return "them"
        case .memo: return "memo"
        }
    }

    /// Human-readable name for menu and notification text.
    var label: String {
        switch self {
        case .mic: return "microphone"
        case .system: return "system audio"
        case .memo: return "voice memo"
        }
    }

    /// Base file name of the track's first segment ("mic.caf"); later
    /// segments append a counter ("mic-002.caf").
    func segmentFile(index: Int) -> String {
        index <= 1 ? "\(rawValue).caf" : String(format: "%@-%03d.caf", rawValue, index)
    }
}

/// Every timing threshold the health machinery uses, kept in one value so
/// tests can substitute short deterministic durations instead of real-time
/// sleeps. All values are milliseconds on the session clock.
struct CapturePolicy: Sendable {
    /// Grace period after a segment starts before missing callbacks count as
    /// a stall — engine/tap construction and TCC checks take real time.
    var startupGraceMs = 5000
    /// A track whose last successful write is older than this is stalled.
    /// Far above the ~85 ms callback cadence, small next to a meeting.
    var staleThresholdMs = 3000
    /// One physical device transition emits a burst of route notifications;
    /// coalesce them and evaluate once the burst settles.
    var routeDebounceMs = 750
    /// Restart attempt delays per episode; count is the retry budget.
    var retryDelaysMs = [0, 500, 2000]
    /// A replacement segment must write continuously this long before the
    /// episode counts as recovered and the retry budget resets.
    var stabilityWindowMs = 5000
    /// Gap allowed between the last written buffer end and session stop
    /// before the track is marked incomplete.
    var finalTailToleranceMs = 3000
    /// Exact digital silence longer than this records a diagnostic warning.
    /// Silence never triggers recovery — it may be legitimate.
    var silenceWarningMs = 15000

    static let production = CapturePolicy()
}

/// Live transport state of one track. `recovered` is deliberately absent:
/// it is a historical/final result, not a live state — a successful restart
/// returns the track to `healthy` with `didRecover` retained.
enum CaptureState: Equatable, Sendable {
    case starting
    case healthy
    case suspect
    case recovering
    case degraded
    case stopped
}

/// Final per-track result persisted in metadata. A recovered session is
/// usable but never represented as uninterrupted.
enum TrackStatus: String, Codable, Sendable {
    case complete
    case recovered
    case incomplete

    /// Ordering for deriving session status as the worst track result.
    var severity: Int {
        switch self {
        case .complete: return 0
        case .recovered: return 1
        case .incomplete: return 2
        }
    }
}

/// One detected capture interruption. Property names are the metadata v2
/// JSON schema. `recovered_offset_ms` is nil while unrecovered.
struct Interruption: Codable, Equatable, Sendable {
    var detected_offset_ms: Int
    var recovered_offset_ms: Int?
    var reason: String
    var attempts: Int
    var error: String?
}

/// Callback-owned counters read by the watchdog. All times are session-clock
/// milliseconds; write fields reset at each segment boundary.
struct TelemetrySnapshot: Equatable, Sendable {
    var firstWriteMs: Int?
    var lastWriteMs: Int?
    var lastBufferEndMs: Int?
    var framesWritten: Int64 = 0
    var zeroRunMs: Int = 0
    var lastError: String?
}

/// Lock-protected store the real-time audio callbacks update and the
/// main-actor watchdog polls. Updates are fixed-size counter writes so the
/// lock is held for nanoseconds; no allocation happens under it.
final class TrackTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var state = TelemetrySnapshot()

    /// Record one successfully written buffer. `allZero` feeds the silence
    /// diagnostic; it never affects transport health.
    func recordWrite(nowMs: Int, bufferEndMs: Int, frames: Int, durationMs: Int, allZero: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if state.firstWriteMs == nil { state.firstWriteMs = nowMs }
        state.lastWriteMs = nowMs
        state.lastBufferEndMs = max(state.lastBufferEndMs ?? 0, bufferEndMs)
        state.framesWritten += Int64(frames)
        state.zeroRunMs = allZero ? state.zeroRunMs + durationMs : 0
    }

    /// Record a write failure. The error is surfaced as a health event by the
    /// recorder; this keeps the latest summary for metadata.
    func recordError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        state.lastError = message
    }

    /// Reset per-segment counters when a new segment starts.
    func resetForSegment() {
        lock.lock()
        defer { lock.unlock() }
        state = TelemetrySnapshot()
    }

    func snapshot() -> TelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

/// Pure per-track health state machine. The session owner feeds it events and
/// watchdog ticks; it returns the commands to execute. It performs no I/O and
/// holds no references, so every transition is unit-testable without audio
/// hardware or real-time waits.
struct TrackHealthMachine: Sendable {
    /// What the session must do next. `restart` includes the schedule delay;
    /// attempt numbers are 1-based within the current episode.
    enum Command: Equatable, Sendable {
        case restart(attempt: Int, delayMs: Int)
        case declareDegraded
    }

    let kind: TrackKind
    let policy: CapturePolicy

    private(set) var state: CaptureState = .starting
    private(set) var didRecover = false
    private(set) var interruptions: [Interruption] = []
    private(set) var warnings: [String] = []
    /// True while the silence diagnostic is active; cleared by signal.
    private(set) var signalWarningActive = false

    private var segmentStartMs: Int
    /// Last route/config event awaiting its debounce window; each new event
    /// in a burst pushes the evaluation later.
    private var suspectSinceMs: Int?
    /// Attempts made in the open episode; nil when no episode is open.
    private var episodeAttempts: Int?
    /// Set after a restart succeeded; recovery is confirmed only once the new
    /// segment has written continuously for the stability window.
    private var awaitingStabilitySinceMs: Int?
    /// True between issuing a restart command and hearing its result, so
    /// watchdog ticks cannot start a second concurrent recovery.
    private var restartInFlight = false

    init(kind: TrackKind, policy: CapturePolicy, startMs: Int) {
        self.kind = kind
        self.policy = policy
        self.segmentStartMs = startMs
    }

    /// A route or configuration notification: mark the track suspect and
    /// (re)start the debounce window. Not proof of failure — callbacks that
    /// continue through the debounce return the track to healthy.
    mutating func routeEvent(atMs now: Int) {
        guard state == .healthy || state == .starting || state == .suspect else { return }
        suspectSinceMs = now
        if state == .healthy { state = .suspect }
    }

    /// A recorder fault (engine stopped, write failure): suspect immediately
    /// with the debounce already elapsed, so the next tick evaluates staleness.
    mutating func fault(atMs now: Int) {
        guard state == .healthy || state == .starting || state == .suspect else { return }
        suspectSinceMs = now - policy.routeDebounceMs
        if state == .healthy { state = .suspect }
    }

    /// A rotation that is not an interruption (voice-processing fallback):
    /// keep the current lifecycle phase but restart segment timing.
    mutating func segmentRotated(atMs now: Int, warning: String?) {
        segmentStartMs = now
        if let warning { warnings.append(warning) }
    }

    /// Watchdog tick: reduce elapsed time and telemetry into at most one
    /// command. Call once per second with the current segment's telemetry.
    mutating func tick(nowMs now: Int, telemetry: TelemetrySnapshot) -> Command? {
        tickSilence(telemetry: telemetry)
        switch state {
        case .starting, .healthy, .suspect:
            return tickLive(nowMs: now, telemetry: telemetry)
        case .recovering:
            return tickRecovering(nowMs: now, telemetry: telemetry)
        case .degraded, .stopped:
            return nil
        }
    }

    /// The session restarted the recorder onto a fresh segment.
    mutating func restartSucceeded(atMs now: Int) {
        guard state == .recovering else { return }
        restartInFlight = false
        segmentStartMs = now
        awaitingStabilitySinceMs = now
    }

    /// A restart attempt failed before capture began.
    mutating func restartFailed(atMs now: Int, error: String) -> Command? {
        guard state == .recovering else { return nil }
        restartInFlight = false
        if var open = interruptions.last, open.recovered_offset_ms == nil {
            open.error = error
            interruptions[interruptions.count - 1] = open
        }
        return nextAttemptOrDegrade(nowMs: now)
    }

    /// The user stopped the session; no further commands are issued.
    mutating func stopped() {
        state = .stopped
    }

    /// Close the machine at stop time and derive the final track status.
    /// `sessionLastBufferEndMs` spans all of the track's segments.
    mutating func finalize(stopMs: Int, telemetry: TelemetrySnapshot, sessionLastBufferEndMs: Int?) -> TrackStatus {
        let wasDegraded = state == .degraded
        state = .stopped
        // A restart that was still inside its stability window when the user
        // stopped counts as recovered if its segment was actually writing.
        if !wasDegraded, hasUnrecoveredInterruption {
            if let first = telemetry.firstWriteMs, tail(stopMs: stopMs, lastEndMs: telemetry.lastBufferEndMs) {
                closeEpisode(recoveredAtMs: first)
            }
        }
        guard !wasDegraded, !hasUnrecoveredInterruption else { return .incomplete }
        guard sessionLastBufferEndMs != nil else { return .incomplete }
        guard tail(stopMs: stopMs, lastEndMs: sessionLastBufferEndMs) else { return .incomplete }
        return interruptions.isEmpty ? .complete : .recovered
    }

    // MARK: -

    private var hasUnrecoveredInterruption: Bool {
        interruptions.contains { $0.recovered_offset_ms == nil }
    }

    private func tail(stopMs: Int, lastEndMs: Int?) -> Bool {
        guard let lastEndMs else { return false }
        return stopMs - lastEndMs <= policy.finalTailToleranceMs
    }

    private func isStale(nowMs now: Int, telemetry: TelemetrySnapshot) -> Bool {
        if let last = telemetry.lastWriteMs { return now - last > policy.staleThresholdMs }
        return now - segmentStartMs > policy.startupGraceMs
    }

    private mutating func tickSilence(telemetry: TelemetrySnapshot) {
        if telemetry.zeroRunMs >= policy.silenceWarningMs {
            if !signalWarningActive {
                signalWarningActive = true
                warnings.append("exact digital silence for \(telemetry.zeroRunMs / 1000)s")
            }
        } else if telemetry.zeroRunMs == 0 {
            signalWarningActive = false
        }
    }

    private mutating func tickLive(nowMs now: Int, telemetry: TelemetrySnapshot) -> Command? {
        if state == .starting, telemetry.firstWriteMs != nil {
            state = .healthy
        }
        if state == .suspect, let since = suspectSinceMs {
            guard now - since >= policy.routeDebounceMs else { return nil }
            suspectSinceMs = nil
            if isStale(nowMs: now, telemetry: telemetry) {
                return openEpisodeAndRestart(nowMs: now, reason: "route_change")
            }
            state = .healthy
            return nil
        }
        if isStale(nowMs: now, telemetry: telemetry) {
            let reason = telemetry.lastError != nil ? "write_failed" : "callback_stalled"
            return openEpisodeAndRestart(nowMs: now, reason: reason)
        }
        return nil
    }

    private mutating func tickRecovering(nowMs now: Int, telemetry: TelemetrySnapshot) -> Command? {
        guard !restartInFlight else { return nil }
        guard let stabilizingSince = awaitingStabilitySinceMs else { return nil }
        if isStale(nowMs: now, telemetry: telemetry) {
            awaitingStabilitySinceMs = nil
            return nextAttemptOrDegrade(nowMs: now)
        }
        if let first = telemetry.firstWriteMs, now - max(first, stabilizingSince) >= policy.stabilityWindowMs {
            awaitingStabilitySinceMs = nil
            closeEpisode(recoveredAtMs: first)
            state = .healthy
        }
        return nil
    }

    private mutating func openEpisodeAndRestart(nowMs now: Int, reason: String) -> Command {
        state = .recovering
        suspectSinceMs = nil
        episodeAttempts = 1
        restartInFlight = true
        interruptions.append(
            Interruption(
                detected_offset_ms: now,
                recovered_offset_ms: nil,
                reason: reason,
                attempts: 1
            ))
        return .restart(attempt: 1, delayMs: policy.retryDelaysMs[0])
    }

    private mutating func nextAttemptOrDegrade(nowMs now: Int) -> Command {
        let attempts = (episodeAttempts ?? 0)
        guard attempts < policy.retryDelaysMs.count else {
            episodeAttempts = nil
            state = .degraded
            return .declareDegraded
        }
        episodeAttempts = attempts + 1
        restartInFlight = true
        if var open = interruptions.last, open.recovered_offset_ms == nil {
            open.attempts = attempts + 1
            interruptions[interruptions.count - 1] = open
        }
        return .restart(attempt: attempts + 1, delayMs: policy.retryDelaysMs[attempts])
    }

    private mutating func closeEpisode(recoveredAtMs: Int) {
        episodeAttempts = nil
        didRecover = true
        if var open = interruptions.last, open.recovered_offset_ms == nil {
            open.recovered_offset_ms = recoveredAtMs
            interruptions[interruptions.count - 1] = open
        }
    }
}
