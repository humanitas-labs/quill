import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch and `retryPending()` rescans on demand.
/// Failures append to the session's transcribe.log and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    enum RetryResult: Equatable, Sendable {
        case disabled
        /// Number of sessions newly queued, excluding active/queued jobs.
        case queued(Int)
    }

    private var queue: [URL] = []
    private var draining = false
    private var currentDirectory: URL?
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private let engineFactory: @Sendable () -> TranscriptionEngine
    private let transcriptionEnabled: @Sendable () -> Bool
    private let onStop: @Sendable () -> String?
    private let notify: @Sendable (String, String) -> Void

    /// Defaults preserve runtime configuration/notifications. Tests supply
    /// a fake engine and no hooks/notifications, without touching user config
    /// or downloading models.
    init(
        engineFactory: @escaping @Sendable () -> TranscriptionEngine = { defaultEngine() },
        transcriptionEnabled: @escaping @Sendable () -> Bool = { Config.transcriptionEnabled() },
        onStop: @escaping @Sendable () -> String? = { Config.onStop() },
        notify: @escaping @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) }
    ) {
        self.engineFactory = engineFactory
        self.transcriptionEnabled = transcriptionEnabled
        self.onStop = onStop
        self.notify = notify
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        let dir = sessionDir.standardizedFileURL
        guard dir != currentDirectory, !queue.contains(dir), !Self.isCompleted(dir) else { return }
        queue.append(dir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        _ = queuePending(root: root, action: "resuming")
    }

    /// Retry unfinished sessions without restarting quill. A completed JSON
    /// transcript is never overwritten; jobs already running or waiting are
    /// excluded even while this actor is suspended on model work.
    func retryPending(root: URL) -> RetryResult {
        queuePending(root: root, action: "retrying")
    }

    private func queuePending(root: URL, action: String) -> RetryResult {
        guard transcriptionEnabled() else { return .disabled }
        var added = 0
        for dir in Self.pendingSessions(in: root)
        where dir != currentDirectory && !queue.contains(dir) {
            queue.append(dir)
            added += 1
        }
        if added > 0 {
            FileHandle.standardError.write(
                Data("\(action) \(added) untranscribed session(s)\n".utf8)
            )
            if let currentDirectory {
                publish(.transcribing(session: currentDirectory.lastPathComponent, queued: queue.count))
            }
        }
        drainIfIdle()
        return .queued(added)
    }

    /// Launch and manual retry share the same filesystem completion rule.
    nonisolated static func pendingSessions(in root: URL) -> [URL] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return [] }

        let fm = FileManager.default
        return
            entries
            .map(\.standardizedFileURL)
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !isCompleted($0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func isCompleted(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            // A session may have completed elsewhere since the scan. Do not
            // overwrite that transcript or fire its hook a second time.
            guard !Self.isCompleted(dir) else { continue }
            currentDirectory = dir
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                if lastFailure == dir.lastPathComponent { lastFailure = nil }
                notify("quill — transcript ready", dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notify(
                    "quill — transcription failed",
                    "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
            currentDirectory = nil
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        // Both metadata schemas normalize to ordered (file, speaker, offset)
        // inputs — one per segment under v2, one per track under v1. Each
        // segment transcribes independently and shifts onto the session
        // clock, so timing gaps around a capture recovery stay visible.
        let (inputs, captureStatus) = try SessionMeta.readInputs(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for input in inputs {
            let audio = dir.appendingPathComponent(input.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing segment \(input.file)")
                continue
            }
            log(dir, "transcribing \(input.file) (\(engine.name))")
            // One bad segment (empty, truncated) shouldn't cost us the rest —
            // log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(input.file): \(error)")
                continue
            }
            merged += Transcript.shifted(segments, speaker: input.speaker, offsetMs: input.offsetMs)
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir, captureStatus: captureStatus)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let engine = engineFactory()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    private nonisolated static func defaultEngine() -> TranscriptionEngine {
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(
                Data(
                    "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
                ))
        }
        return ParakeetEngine()
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. Internal (not private) so the offset-preserving
/// merge math is unit-testable.
struct Transcript: Codable {
    struct Segment: Codable, Equatable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Shift one audio file's transcript segments onto the session clock by
    /// the file's start offset. Segments are never collapsed against a
    /// previous file's end — a capture gap stays visible as a timestamp gap.
    static func shifted(
        _ segments: [TranscriptSegment], speaker: String, offsetMs: Int
    ) -> [Segment] {
        segments.map {
            Segment(
                speaker: speaker,
                start_ms: Int($0.start * 1000) + offsetMs,
                end_ms: Int($0.end * 1000) + offsetMs,
                text: $0.text
            )
        }
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    /// `captureStatus` (v2 sessions only) is persisted in the readable header
    /// so an incomplete recording stays visibly incomplete after the
    /// transient notification disappears.
    func write(to dir: URL, captureStatus: TrackStatus? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent, captureStatus: captureStatus).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func rendered(title: String, captureStatus: TrackStatus? = nil) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        if let captureStatus, captureStatus != .complete {
            lines.append("capture: \(captureStatus.rawValue)")
        }
        lines.append("")
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
