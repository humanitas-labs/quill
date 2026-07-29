import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port. Models download once into
/// FluidAudio's managed cache (~600 MB); after that, transcription runs
/// entirely on-device at roughly 20 seconds per hour of audio on Apple
/// Silicon. The configured language picks which model runs — see `Variant`.
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

    /// A model version plus the decoder hint it's run with. Each version has
    /// its own cache directory, so switching languages costs another download
    /// but never invalidates the model you were using.
    struct Variant: Sendable {
        let version: AsrModelVersion
        /// Recorded as transcript.json provenance.
        let model: String
        /// Language hint for script-aware token filtering — v3 only, silently
        /// ignored by v2. It drops top-K candidates outside the language's
        /// script, so it earns its keep for Cyrillic or Greek and does close
        /// to nothing for Latin-script languages like Spanish, which share
        /// their alphabet with English. v3 does the real work by itself.
        let hint: Language?
    }

    private static let english = Variant(
        version: .v2, model: "parakeet-tdt-0.6b-v2-coreml", hint: nil
    )

    private static func multilingual(_ hint: Language?) -> Variant {
        Variant(version: .v3, model: "parakeet-tdt-0.6b-v3-coreml", hint: hint)
    }

    /// The 25 languages v3 is trained on. FluidAudio's `Language` is a wider
    /// set — it drives script filtering, not model coverage, so it also
    /// carries Belarusian, Bosnian and Serbian, which NVIDIA doesn't list.
    private static let covered: Set<Language> = [
        .bulgarian, .croatian, .czech, .danish, .dutch, .english, .estonian,
        .finnish, .french, .german, .greek, .hungarian, .italian, .latvian,
        .lithuanian, .maltese, .polish, .portuguese, .romanian, .slovak,
        .slovenian, .spanish, .swedish, .russian, .ukrainian,
    ]

    /// Resolve a configured language code to a model. `"en"` stays on v2,
    /// which is English-only and scores better on English than v3; `"auto"`
    /// runs v3 with no hint and lets it detect; any covered language runs v3
    /// with the hint.
    ///
    /// Both off-ramps say so on stderr. An unknown code falls back to English
    /// rather than transcribing with a model nobody chose; a known but
    /// uncovered one still runs — Bosnian and Serbian are close enough to
    /// covered neighbours to be worth attempting — but never silently, since
    /// a model quietly transcribing a language it was never trained on is the
    /// exact failure this setting exists to prevent.
    static func variant(for language: String) -> Variant {
        let code = language.lowercased()
        if code == "en" { return english }
        if code == "auto" { return multilingual(nil) }
        guard let hint = Language(rawValue: code) else {
            warn("unknown transcription language \"\(language)\" — using en")
            return english
        }
        if !covered.contains(hint) {
            warn("\(hint.rawValue) isn't one of parakeet v3's 25 languages — "
                + "transcribing anyway, but expect a worse transcript")
        }
        return multilingual(hint)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    nonisolated let name = "parakeet"
    nonisolated var model: String { selected.model }

    private nonisolated let selected: Variant
    private var manager: AsrManager?

    init(language: String) {
        selected = Self.variant(for: language)
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: selected.version)
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
        let result = try await manager.transcribe(
            audio, decoderState: &state, language: selected.hint
        )

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
    /// punctuation (parakeet emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps. The suffix test survives
    /// the move to v3: Spanish opens with ¿ and ¡, but those are prefixes.
    /// Observed on Spanish audio, v3 doesn't emit them at all and closes
    /// questions with "." rather than "?", so segments break on the period.
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
