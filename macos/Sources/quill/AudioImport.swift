import AVFoundation
import Foundation

/// Turns an existing audio file — typically a Voice Memos recording
/// AirDropped from an iPhone — into an ordinary quill session, so it flows
/// through the same transcription queue and produces the same
/// transcript.json / transcript.md as a live recording.
///
/// The session is one `memo` track with a single segment at offset 0. The
/// source file is copied, never moved or modified. Formats AVAudioFile can't
/// read directly (QuickTime `.qta` from newer Voice Memos, video containers)
/// are converted to AAC `.m4a` first. meta.json is written last and
/// atomically, so a crash mid-import leaves a folder the transcription
/// resumer ignores rather than a half-copied session it would try to read.
enum AudioImport {
    enum ImportError: Error, CustomStringConvertible {
        case unsupported(URL)
        case unreadable(URL, Error?)
        case conversionFailed(URL, Error)

        var description: String {
            switch self {
            case .unsupported(let url):
                return "\(url.lastPathComponent) isn't an audio file quill can import"
            case .unreadable(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            case .conversionFailed(let url, let e):
                return "couldn't convert \(url.lastPathComponent) to m4a: \(e)"
            }
        }
    }

    /// Extensions accepted by drag and drop and the open panel. Voice Memos
    /// shares `.m4a` (older recordings) or `.qta` (iOS 17+).
    static let supportedExtensions: Set<String> = [
        "m4a", "qta", "caf", "wav", "aif", "aiff", "aifc", "mp3", "aac", "mp4", "mov", "m4v",
    ]

    static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Stage `source` as a new session under `root` and return its folder,
    /// ready for `TranscriptionCoordinator.enqueue`. The folder is named for
    /// when the memo was recorded, so imports sort alongside meetings.
    static func stage(_ source: URL, root: URL) async throws -> URL {
        guard isSupported(source) else { throw ImportError.unsupported(source) }
        let recordedAt = await recordingDate(of: source)
        let dir = try SessionFolder.create(in: root, date: recordedAt)
        do {
            let file = try await ingest(source, into: dir)
            let audio: AVAudioFile
            do {
                audio = try AVAudioFile(forReading: dir.appendingPathComponent(file))
            } catch {
                throw ImportError.unreadable(source, error)
            }
            guard audio.length > 0 else { throw ImportError.unreadable(source, nil) }
            try meta(
                file: file,
                recordedAt: recordedAt,
                frames: audio.length,
                sampleRate: audio.fileFormat.sampleRate,
                channels: Int(audio.fileFormat.channelCount),
                source: source.lastPathComponent
            ).write(to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    /// Schema v2 metadata for an imported file: one complete `memo` track,
    /// one segment spanning the whole file on the session clock.
    static func meta(
        file: String, recordedAt: Date, frames: Int64, sampleRate: Double, channels: Int, source: String
    ) -> SessionMeta {
        let durationMs = sampleRate > 0 ? Int(Double(frames) / sampleRate * 1000) : 0
        let iso = ISO8601DateFormatter()
        return SessionMeta(
            schema_version: 2,
            started: iso.string(from: recordedAt),
            ended: iso.string(from: recordedAt.addingTimeInterval(Double(durationMs) / 1000)),
            duration_seconds: durationMs / 1000,
            status: .complete,
            tracks: [
                SessionMeta.Track(
                    kind: .memo,
                    speaker: TrackKind.memo.speaker,
                    status: .complete,
                    segments: [
                        SessionMeta.Segment(
                            file: file,
                            start_offset_ms: 0,
                            end_offset_ms: durationMs,
                            frames_written: frames,
                            sample_rate_hz: Int(sampleRate),
                            channels: channels
                        )
                    ],
                    interruptions: [],
                    warnings: []
                )
            ],
            source: source
        )
    }

    // MARK: -

    /// Copy the file in as `memo.<ext>` when AVAudioFile — what the engine
    /// reads with — can open it; otherwise export its audio as `memo.m4a`.
    private static func ingest(_ source: URL, into dir: URL) async throws -> String {
        if let probe = try? AVAudioFile(forReading: source), probe.length > 0 {
            let name = "memo.\(source.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
            return name
        }

        let name = "memo.m4a"
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.unreadable(source, nil)
        }
        do {
            try await export.export(to: dir.appendingPathComponent(name), as: .m4a)
        } catch {
            throw ImportError.conversionFailed(source, error)
        }
        return name
    }

    /// When the memo was recorded: the container's creation-date metadata
    /// (Voice Memos sets it), else the file's creation date, else now.
    /// AirDrop stamps the file with its arrival time, so the metadata wins.
    private static func recordingDate(of url: URL) async -> Date {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
            let date = try? await item.load(.dateValue)
        {
            return date
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    }
}
