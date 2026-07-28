import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port. Models download once into
/// FluidAudio's managed cache (~600 MB); after that, transcription runs
/// entirely on-device at roughly 20 seconds per hour of audio on Apple
/// Silicon.
///
/// Two model versions, selected with `transcription.model`: v3 is multilingual
/// (25 European languages plus Japanese) and detects the spoken language
/// itself; v2 is English-only with marginally higher recall on English.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    /// The configured model version, warning and falling back rather than
    /// silently transcribing with one the user didn't ask for. Shared with
    /// `quill doctor` so the cache check can't drift from what we download.
    static func configuredVersion() -> AsrModelVersion {
        switch Config.transcriptionModel() {
        case "v3": return .v3
        case "v2": return .v2
        case let other:
            FileHandle.standardError.write(Data(
                "warning: unknown parakeet model \"\(other)\" — using v3\n".utf8
            ))
            return .v3
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model: String
    private let version: AsrModelVersion

    private var manager: AsrManager?

    init(version: AsrModelVersion = ParakeetEngine.configuredVersion()) {
        self.version = version
        self.model = version == .v2
            ? "parakeet-tdt-0.6b-v2-coreml"
            : "parakeet-tdt-0.6b-v3-coreml"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (both parakeet versions emit it), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
