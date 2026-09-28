import AVFoundation
import Foundation

/// Turns orphaned in-progress recordings into incomplete v2 sessions before
/// the transcription queue scans for meta.json files.
enum SessionRecovery {
    struct RecoveredSession {
        let dir: URL
        let startedAt: Date
    }

    static func recoverInterrupted(in root: URL) -> [RecoveredSession] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return [] }

        var recovered: [RecoveredSession] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(InProgressRecording.fileName).path
                )
            else { continue }
            do {
                if let result = try recover(dir) { recovered.append(result) }
            } catch {
                FileHandle.standardError.write(
                    Data("\(dir.lastPathComponent): recovery skipped: \(error)\n".utf8)
                )
            }
        }
        return recovered
    }

    private static func recover(_ dir: URL) throws -> RecoveredSession? {
        // A second running Quill process may own this session. A crash drops
        // the kernel lock without needing to update the manifest.
        guard let lock = try? RecordingLock.acquire(in: dir) else { return nil }
        defer { lock.release() }

        let manifestURL = dir.appendingPathComponent(InProgressRecording.fileName)
        if (try? SessionMeta.readInputs(from: dir)) != nil {
            try? FileManager.default.removeItem(at: manifestURL)
            return nil
        }

        let record = try InProgressRecording.read(from: dir)
        guard record.schema_version == InProgressRecording.schemaVersion else { return nil }

        var tracks: [SessionMeta.Track] = []
        for track in record.tracks {
            var segments: [SessionMeta.Segment] = []
            var warnings = track.warnings
            for entry in track.segments {
                guard safeFileName(entry.file),
                    let audio = try? AVAudioFile(forReading: dir.appendingPathComponent(entry.file)),
                    audio.length > 0,
                    audio.processingFormat.sampleRate > 0
                else {
                    warnings.append("missing or unreadable segment \(entry.file)")
                    continue
                }
                let rate = audio.processingFormat.sampleRate
                let start = max(0, entry.start_offset_ms)
                let durationMs = Int(Double(audio.length) * 1000 / rate)
                segments.append(
                    SessionMeta.Segment(
                        file: entry.file,
                        start_offset_ms: start,
                        end_offset_ms: start + durationMs,
                        frames_written: audio.length,
                        sample_rate_hz: Int(rate),
                        channels: Int(audio.processingFormat.channelCount)
                    )
                )
            }
            tracks.append(
                SessionMeta.Track(
                    kind: track.kind,
                    speaker: track.kind.speaker,
                    status: .incomplete,
                    segments: segments,
                    interruptions: track.interruptions,
                    warnings: warnings
                ))
        }

        let lastAudioMs = tracks.flatMap(\.segments).map(\.end_offset_ms).max() ?? 0
        guard lastAudioMs > 0 else { return nil }
        let crash = Interruption(
            detected_offset_ms: lastAudioMs,
            recovered_offset_ms: nil,
            reason: "process_exited",
            attempts: 0,
            error: nil
        )
        for index in tracks.indices {
            tracks[index].interruptions.append(crash)
            tracks[index].warnings.append("recording ended before a clean stop")
        }

        let endedAt = record.started.addingTimeInterval(Double(lastAudioMs) / 1000)
        let iso = ISO8601DateFormatter()
        let meta = SessionMeta(
            schema_version: 2,
            started: iso.string(from: record.started),
            ended: iso.string(from: endedAt),
            duration_seconds: lastAudioMs / 1000,
            status: .incomplete,
            tracks: tracks
        )
        try meta.write(to: dir)
        try? FileManager.default.removeItem(at: manifestURL)
        FileHandle.standardError.write(Data("recovered interrupted recording: \(dir.path)\n".utf8))
        return RecoveredSession(dir: dir, startedAt: record.started)
    }

    private static func safeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && URL(fileURLWithPath: name).lastPathComponent == name
    }
}
