import Foundation

/// Shared host for Handy and user-configured local transcription adapters.
actor CommandEngine: TranscriptionEngine {
    nonisolated let name: String
    nonisolated let model: String
    private let adapter: any TranscriptionCommandAdapter
    private var prepared = false

    init(adapter: any TranscriptionCommandAdapter) {
        self.adapter = adapter
        name = adapter.name
        model = adapter.model
    }

    func prepare() async throws {
        guard !prepared else { return }
        try adapter.prepare()
        prepared = true
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard prepared else { throw TranscriptionCommandError("command engine used before prepare()") }
        do {
            return try transcribeChunks(audio)
        } catch let error as UnreadableTranscriptionInput {
            throw error
        } catch let error as TranscriptionCommandError {
            throw error
        } catch {
            throw TranscriptionCommandError("command transcription failed: \(error)")
        }
    }

    private func transcribeChunks(_ audio: URL) throws -> [TranscriptSegment] {
        try CommandProcess.withTemporaryDirectory { directory in
            let chunks = try CommandAudio.chunks(from: audio, in: directory, maxDuration: adapter.chunkDuration)
            var segments: [TranscriptSegment] = []
            for chunk in chunks {
                try Task.checkCancellation()
                let output = try CommandProcess.run(
                    executable: adapter.executable, arguments: adapter.arguments(for: chunk.url), timeout: adapter.timeout
                )
                segments += try adapter.decode(output, duration: chunk.duration).map {
                    TranscriptSegment(start: chunk.start + $0.start, end: chunk.start + $0.end, text: $0.text)
                }
                try FileManager.default.removeItem(at: chunk.url)
            }
            return segments
        }
    }

    func release() async {
        prepared = false
    }
}
