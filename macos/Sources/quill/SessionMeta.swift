import Foundation

/// Session metadata contract. New recordings write schema v2 — a typed
/// `tracks[].segments[]` representation that carries capture completeness,
/// interruptions, and per-segment session-clock offsets. The reader also
/// accepts the v1 shape (`files` + `start_offset_ms`) so every existing
/// recording remains transcribable. Property names are the JSON schema.
struct SessionMeta: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var file: String
        var start_offset_ms: Int
        var end_offset_ms: Int
        var frames_written: Int64
        var sample_rate_hz: Int
        var channels: Int
    }

    struct Track: Codable, Equatable, Sendable {
        var kind: TrackKind
        var speaker: String
        var status: TrackStatus
        var segments: [Segment]
        var interruptions: [Interruption]
        var warnings: [String]
    }

    var schema_version: Int
    var started: String
    var ended: String
    var duration_seconds: Int
    var status: TrackStatus
    var tracks: [Track]
    /// Original file name of imported audio ("New Recording 3.m4a"); absent
    /// for live recordings.
    var source: String? = nil

    /// One transcription input: a segment file, who speaks on it, and where
    /// it starts on the session clock. Both schema versions normalize to an
    /// ordered list of these.
    struct TrackInput: Equatable, Sendable {
        var file: String
        var speaker: String
        var offsetMs: Int
    }

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    /// Write meta.json atomically so the transcription resumer, which treats
    /// the file's presence as "session finished", never reads a partial
    /// document.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Parse a session's meta.json — v1 or v2 — into normalized transcription
    /// inputs plus the session capture status (nil for v1, which predates
    /// completeness tracking).
    static func readInputs(from dir: URL) throws -> (inputs: [TrackInput], captureStatus: TrackStatus?) {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { throw MetaError.unreadable(url) }
        if let meta = try? JSONDecoder().decode(SessionMeta.self, from: data), meta.schema_version >= 2 {
            let inputs = meta.tracks.flatMap { track in
                track.segments.map {
                    TrackInput(file: $0.file, speaker: track.speaker, offsetMs: $0.start_offset_ms)
                }
            }
            return (inputs, meta.status)
        }
        return (try v1Inputs(data: data, url: url), nil)
    }

    /// The imported file name recorded in meta.json, if any. Best-effort: a
    /// missing or v1 meta.json simply has no source.
    static func readSource(from dir: URL) -> String? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["source"] as? String
    }

    // MARK: -

    /// The original shape: `files: {mic, system}` plus optional
    /// `start_offset_ms` per track. Sessions recorded before offsets were
    /// captured default to 0.
    private static func v1Inputs(data: Data, url: URL) throws -> [TrackInput] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var inputs: [TrackInput] = []
        for kind in TrackKind.allCases {
            if let file = files[kind.rawValue] {
                inputs.append(
                    TrackInput(
                        file: file,
                        speaker: kind.speaker,
                        offsetMs: offsets[kind.rawValue] ?? 0
                    ))
            }
        }
        return inputs
    }
}
