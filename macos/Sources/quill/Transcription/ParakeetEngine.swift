import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v2 (English) via FluidAudio's Core ML port. Models
/// download once into FluidAudio's managed cache (~600 MB); after that,
/// transcription runs entirely on-device at roughly 20 seconds per hour of
/// audio on Apple Silicon.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared

        var description: String {
            "parakeet engine used before prepare()"
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model = "parakeet-tdt-0.6b-v2-coreml"

    private var manager: AsrManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
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
            guard probe.length > 0 else { throw UnreadableTranscriptionInput(audio: audio) }
        } catch let error as UnreadableTranscriptionInput {
            throw error
        } catch {
            throw UnreadableTranscriptionInput.classify(error, audio: audio)
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
    /// punctuation (parakeet v2 emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(
                TranscriptSegment(
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
            let endsSentence =
                word.word.hasSuffix(".")
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
