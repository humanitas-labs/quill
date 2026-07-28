import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    // Track-liveness watchdog. Both .caf files grow continuously while their
    // capture is healthy; a track whose file freezes mid-session (a call app
    // reconfiguring the input device, a died tap — anything) is a recording
    // silently going wrong, and the user should hear about it now, not after
    // the meeting (2026.07.28: a 19min call yielded a 1.7s mic track with no
    // visible symptom until the transcript came out one-sided).
    private var watchdog: Timer?
    private var trackSize: [String: Int64] = [:]
    private var trackLastGrew: [String: Date] = [:]
    private var trackStalled: Set<String> = []
    private static let watchdogInterval: TimeInterval = 15
    private static let stallThreshold: TimeInterval = 45

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
        watchdog = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval, repeats: true
        ) { [weak self] _ in
            self?.checkTrackLiveness()
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    // MARK: -

    /// Compare each track file's size against the last poll. Growth clears any
    /// stall state (and announces recovery); a freeze past the threshold
    /// notifies once per stall episode, so a track that dies, recovers, and
    /// dies again alerts both times without spamming in between.
    private func checkTrackLiveness() {
        let now = Date()
        for name in ["mic", "system"] {
            let path = dir.appendingPathComponent("\(name).caf").path
            guard let size = (try? FileManager.default
                .attributesOfItem(atPath: path))?[.size] as? Int64 else { continue }

            if size != trackSize[name] {
                trackSize[name] = size
                trackLastGrew[name] = now
                if trackStalled.remove(name) != nil {
                    notifyUser(
                        title: "quill: \(name) track recovered",
                        body: "\(name) audio is being written again."
                    )
                }
            } else if let last = trackLastGrew[name], !trackStalled.contains(name),
                      now.timeIntervalSince(last) >= Self.stallThreshold {
                trackStalled.insert(name)
                notifyUser(
                    title: "quill: \(name) track stalled",
                    body: "No \(name) audio written for \(Int(now.timeIntervalSince(last)))s"
                        + " — the recording may be incomplete."
                )
            }
        }
    }
}
