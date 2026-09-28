import Darwin
import Foundation

/// Durable capture state until meta.json marks the session ready for processing.
/// A planned segment is recorded before its audio file is opened; a missing or
/// unreadable file is ignored during recovery.
struct InProgressRecording: Codable, Equatable {
    static let fileName = "in-progress.json"
    static let schemaVersion = 1

    struct Segment: Codable, Equatable {
        var file: String
        var start_offset_ms: Int
        var end_offset_ms: Int?
    }

    struct Track: Codable, Equatable {
        var kind: TrackKind
        var segments: [Segment]
        var interruptions: [Interruption]
        var warnings: [String]
    }

    var schema_version = schemaVersion
    var started: Date
    var tracks: [Track]

    static func read(from dir: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A live process holds this advisory lock for its recording. The kernel drops
/// it on a crash, so startup recovery can distinguish orphaned sessions from
/// another Quill process still writing audio. The lock file stays in place to
/// avoid unlinking an inode another process may have acquired.
final class RecordingLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(in dir: URL) throws -> RecordingLock {
        let path = dir.appendingPathComponent("recording.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return RecordingLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
