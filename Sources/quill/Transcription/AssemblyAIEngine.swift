import Foundation

/// AssemblyAI Universal-2 transcription engine. Uploads the audio file to
/// AssemblyAI, submits a transcript request, polls until complete, and returns
/// word-aligned segments — same shape as ParakeetEngine.
///
/// Audio leaves the local machine. Requires an internet connection and a valid
/// API key stored in ~/.config/quill/config.json under "assemblyai_api_key".
actor AssemblyAIEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case missingAPIKey
        case uploadFailed(String)
        case submitFailed(String)
        case transcriptionFailed(String)
        case unexpectedResponse

        var description: String {
            switch self {
            case .missingAPIKey:
                return "assemblyai_api_key not set in ~/.config/quill/config.json"
            case .uploadFailed(let msg):
                return "AssemblyAI upload failed: \(msg)"
            case .submitFailed(let msg):
                return "AssemblyAI transcript submit failed: \(msg)"
            case .transcriptionFailed(let msg):
                return "AssemblyAI transcription failed: \(msg)"
            case .unexpectedResponse:
                return "AssemblyAI returned an unreadable response"
            }
        }
    }

    nonisolated let name = "assemblyai"
    nonisolated let model = "universal-2"

    private let apiKey: String
    private let baseURL = "https://api.assemblyai.com"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// No model download needed — nothing to do here.
    func prepare() async throws {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        FileHandle.standardError.write(Data(
            "assemblyai: uploading \(audio.lastPathComponent)…\n".utf8
        ))
        let uploadURL = try await upload(audio)

        FileHandle.standardError.write(Data(
            "assemblyai: submitting transcript request…\n".utf8
        ))
        let transcriptID = try await submit(audioURL: uploadURL)

        FileHandle.standardError.write(Data(
            "assemblyai: polling \(transcriptID)…\n".utf8
        ))
        let words = try await poll(id: transcriptID)

        return Self.segments(from: words)
    }

    func release() async {}

    // MARK: - Private helpers

    private struct Word {
        let text: String
        let startSec: TimeInterval
        let endSec: TimeInterval
    }

    /// Upload the audio file as raw bytes. Uses URLSession streaming so large
    /// CAF files are never fully loaded into memory.
    private func upload(_ file: URL) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/v2/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            fromFile: file
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineError.uploadFailed("HTTP \(code)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let uploadURL = json["upload_url"] as? String
        else {
            throw EngineError.uploadFailed("unexpected response shape")
        }
        return uploadURL
    }

    /// Submit the transcript job with Universal-2 and language detection.
    private func submit(audioURL: String) async throws -> String {
        let body: [String: Any] = [
            "audio_url": audioURL,
            "speech_model": "universal",
            "language_detection": true,
        ]
        var request = URLRequest(url: URL(string: "\(baseURL)/v2/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineError.submitFailed("HTTP \(code)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let id = json["id"] as? String
        else {
            throw EngineError.submitFailed("unexpected response shape")
        }
        return id
    }

    /// Poll every 3 seconds until the job reaches a terminal state. Max 2 hours.
    private func poll(id: String) async throws -> [Word] {
        var request = URLRequest(url: URL(string: "\(baseURL)/v2/transcript/\(id)")!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        for _ in 0..<2400 {
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let (responseData, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else { throw EngineError.unexpectedResponse }

            switch json["status"] as? String ?? "" {
            case "completed":
                return parseWords(from: json)
            case "error":
                throw EngineError.transcriptionFailed(
                    json["error"] as? String ?? "unknown error"
                )
            default:
                continue
            }
        }
        throw EngineError.transcriptionFailed("timed out after 2 hours")
    }

    /// Extract word timings from the completed transcript JSON.
    private func parseWords(from json: [String: Any]) -> [Word] {
        guard let words = json["words"] as? [[String: Any]] else { return [] }
        return words.compactMap { w in
            guard
                let text = w["text"] as? String,
                let startMs = w["start"] as? Int,
                let endMs = w["end"] as? Int
            else { return nil }
            return Word(
                text: text,
                startSec: TimeInterval(startMs) / 1000,
                endSec: TimeInterval(endMs) / 1000
            )
        }
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation, a silence gap > 1 s, or a 60-word cap — mirrors the
    /// logic in ParakeetEngine.
    private static func segments(from words: [Word]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startSec,
                end: last.endSec,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startSec - last.endSec > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.text.hasSuffix(".")
                || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
