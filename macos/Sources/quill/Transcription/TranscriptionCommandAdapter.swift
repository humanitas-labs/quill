import Foundation

/// Provider-specific CLI conventions. Audio conversion, chunk offsets, process
/// lifecycle and JSON validation belong to CommandEngine and CommandProcess.
protocol TranscriptionCommandAdapter: Sendable {
    var name: String { get }
    var model: String { get }
    var executable: URL { get }
    var timeout: TimeInterval { get }
    var chunkDuration: TimeInterval { get }
    func prepare() throws
    func arguments(for audio: URL) -> [String]
    func decode(_ output: Data, duration: TimeInterval) throws -> [TranscriptSegment]
}

extension TranscriptionCommandAdapter {
    func decode(_ output: Data, duration: TimeInterval) throws -> [TranscriptSegment] {
        try CommandTranscript.decode(output, duration: duration)
    }
}

struct ConfiguredCommandAdapter: Decodable, TranscriptionCommandAdapter {
    let name: String
    let model: String
    let executable: URL
    let argumentTemplate: [String]
    let timeout: TimeInterval
    let chunkDuration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case name, model, executable, arguments, timeout_seconds, chunk_seconds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "command"
        model = try values.decode(String.self, forKey: .model)
        let path = try values.decode(String.self, forKey: .executable)
        executable = try CommandProcess.executable(at: path)
        argumentTemplate = try values.decode([String].self, forKey: .arguments)
        timeout = try values.decodeIfPresent(Double.self, forKey: .timeout_seconds) ?? 600
        chunkDuration = try values.decodeIfPresent(Double.self, forKey: .chunk_seconds) ?? 300
    }

    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TranscriptionCommandError("command name and model must be nonempty") }
        guard argumentTemplate.contains(where: { $0.contains("{audio}") }) else {
            throw TranscriptionCommandError("command arguments must contain {audio}")
        }
        guard timeout.isFinite, (1...3600).contains(timeout),
            chunkDuration.isFinite, (1...300).contains(chunkDuration)
        else {
            throw TranscriptionCommandError("timeout_seconds must be 1–3600 and chunk_seconds must be 1–300")
        }
        return self
    }

    func prepare() throws {
        try CommandProcess.checkExecutable(executable)
    }

    func arguments(for audio: URL) -> [String] {
        // Replace the template once, so braces in a model/path stay literal.
        argumentTemplate.map { template in
            template.components(separatedBy: "{audio}")
                .map { $0.replacingOccurrences(of: "{model}", with: model) }
                .joined(separator: audio.path)
        }
    }
}

/// The standard local command response: timed segments in seconds, or one
/// plain-text segment covering the input chunk. Empty text/segments mean silence.
private struct CommandTranscript: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    let text: String?
    let segments: [Segment]?

    static func decode(_ data: Data, duration: TimeInterval) throws -> [TranscriptSegment] {
        let result: Self
        do {
            result = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw TranscriptionCommandError("command must return JSON with text or timed segments: \(error)")
        }
        if let segments = result.segments {
            return try segments.compactMap { segment in
                guard segment.start.isFinite, segment.end.isFinite,
                    segment.start >= 0, segment.end >= segment.start,
                    segment.end <= duration + 0.05
                else { throw TranscriptionCommandError("command segment timestamps fall outside the input chunk") }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty
                    ? nil
                    : TranscriptSegment(
                        start: min(segment.start, duration), end: min(segment.end, duration), text: text
                    )
            }.sorted { $0.start < $1.start }
        }
        guard let text = result.text else {
            throw TranscriptionCommandError("command JSON is missing text or segments")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [TranscriptSegment(start: 0, end: duration, text: trimmed)]
    }
}
