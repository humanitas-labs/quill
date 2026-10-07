import AVFoundation
import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}

struct UnreadableTranscriptionInput: Error, CustomStringConvertible {
    let description: String

    init(audio: URL, underlyingError: (any Error)? = nil) {
        description =
            "unreadable or empty audio \(audio.lastPathComponent)"
            + (underlyingError.map { ": \($0)" } ?? "")
    }

    init(description: String) {
        self.description = description
    }

    static func classify(_ error: any Error, audio: URL) -> any Error {
        let underlying = error as NSError
        let malformedAVErrors: Set<Int> = [
            AVError.fileFormatNotRecognized.rawValue,
            AVError.fileFailedToParse.rawValue,
            AVError.invalidSourceMedia.rawValue,
            AVError.decodeFailed.rawValue,
            AVError.undecodableMediaData.rawValue,
        ]
        let malformedAudioFileErrors: Set<Int> = [
            Int(kAudioFileUnsupportedFileTypeError),
            Int(kAudioFileUnsupportedDataFormatError),
            Int(kAudioFileInvalidFileError),
        ]
        let malformed =
            (underlying.domain == AVFoundationErrorDomain && malformedAVErrors.contains(underlying.code))
            || malformedAudioFileErrors.contains(underlying.code)
        guard malformed else { return error }
        return UnreadableTranscriptionInput(audio: audio, underlyingError: error)
    }
}
