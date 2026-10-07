import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private let engineFactory: @Sendable () throws -> any TranscriptionEngine

    init(engineFactory: @escaping @Sendable () throws -> any TranscriptionEngine = { try TranscriptionProvider().makeEngine() }) {
        self.engineFactory = engineFactory
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )
        else { return }

        let fm = FileManager.default
        let pending =
            entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "resuming \(pending.count) untranscribed session(s)\n".utf8
                ))
        }
        drainIfIdle()
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
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    // Internal for exercising the entire persistence path without UI notifications.
    func transcribe(_ dir: URL) async throws {
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
                throw TranscriptionCommandError("session audio file is missing: \(audio.path)")
            }
            log(dir, "transcribing \(input.file) (\(engine.name))")
            // One bad segment (empty, truncated) shouldn't cost us the rest —
            // log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch let error as UnreadableTranscriptionInput {
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
        let engine = try engineFactory()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
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
