import AVFoundation
import XCTest

@testable import quill

final class SessionRecoveryTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recovery-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("2026.09.28-1200", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecoversEverySegmentAfterRouteRotation() throws {
        let routeGap = Interruption(
            detected_offset_ms: 1500, recovered_offset_ms: 3000,
            reason: "callback_stalled", attempts: 1, error: nil
        )
        try record(
            mic: [segment("mic.caf", at: 100), segment("mic-002.caf", at: 3000)],
            system: [segment("system.caf", at: 0)],
            micInterruptions: [routeGap]
        )
        try writeAudio("mic.caf", frames: 16_000)
        try writeAudio("mic-002.caf", frames: 8_000)
        try writeAudio("system.caf", frames: 64_000)

        let recovered = SessionRecovery.recoverInterrupted(in: root)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.dir.resolvingSymlinksInPath(), dir.resolvingSymlinksInPath())
        XCTAssertFalse(fileExists(InProgressRecording.fileName))
        let meta = try readMeta()
        XCTAssertEqual(meta.schema_version, 2)
        XCTAssertEqual(meta.status, .incomplete)
        XCTAssertEqual(meta.duration_seconds, 4)
        let mic = try XCTUnwrap(meta.tracks.first { $0.kind == .mic })
        XCTAssertEqual(mic.status, .incomplete)
        XCTAssertEqual(mic.segments.map(\.file), ["mic.caf", "mic-002.caf"])
        XCTAssertEqual(mic.segments.map(\.start_offset_ms), [100, 3000])
        XCTAssertEqual(mic.segments.map(\.end_offset_ms), [1100, 3500])
        XCTAssertEqual(mic.segments.map(\.frames_written), [16_000, 8_000])
        XCTAssertEqual(mic.interruptions.first, routeGap)
        XCTAssertEqual(mic.interruptions.last?.reason, "process_exited")
        XCTAssertNil(mic.interruptions.last?.recovered_offset_ms)
        XCTAssertEqual(meta.tracks.first { $0.kind == .system }?.segments.map(\.file), ["system.caf"])

        let (inputs, status) = try SessionMeta.readInputs(from: dir)
        XCTAssertEqual(status, .incomplete)
        XCTAssertEqual(inputs.map(\.file), ["mic.caf", "mic-002.caf", "system.caf"])
        XCTAssertEqual(inputs.map(\.offsetMs), [100, 3000, 0])
        XCTAssertTrue(SessionRecovery.recoverInterrupted(in: root).isEmpty)
    }

    func testMissingAndTruncatedSegmentsAreExcluded() throws {
        try record(
            mic: [segment("mic.caf", at: 100), segment("mic-002.caf", at: 3000)],
            system: [segment("system.caf", at: 0)]
        )
        try writeAudio("mic.caf", frames: 16_000)
        try Data("not a CAF".utf8).write(to: dir.appendingPathComponent("system.caf"))

        XCTAssertEqual(SessionRecovery.recoverInterrupted(in: root).count, 1)
        let meta = try readMeta()
        XCTAssertEqual(meta.status, .incomplete)
        let mic = try XCTUnwrap(meta.tracks.first { $0.kind == .mic })
        XCTAssertEqual(mic.segments.map(\.file), ["mic.caf"])
        XCTAssertTrue(mic.warnings.contains { $0.contains("mic-002.caf") })
        let system = try XCTUnwrap(meta.tracks.first { $0.kind == .system })
        XCTAssertTrue(system.segments.isEmpty)
        XCTAssertTrue(system.warnings.contains { $0.contains("system.caf") })
    }

    func testLiveRecordingIsNotRecovered() throws {
        try record(mic: [segment("mic.caf", at: 0)], system: [])
        try writeAudio("mic.caf", frames: 16_000)
        let lock = try RecordingLock.acquire(in: dir)
        defer { lock.release() }

        XCTAssertTrue(SessionRecovery.recoverInterrupted(in: root).isEmpty)
        XCTAssertTrue(fileExists(InProgressRecording.fileName))
        XCTAssertFalse(fileExists("meta.json"))
    }

    func testNoReadableAudioKeepsRecordForLaterInspection() throws {
        try record(mic: [segment("mic.caf", at: 0)], system: [])
        XCTAssertTrue(SessionRecovery.recoverInterrupted(in: root).isEmpty)
        XCTAssertTrue(fileExists(InProgressRecording.fileName))
        XCTAssertFalse(fileExists("meta.json"))
    }

    private func segment(_ file: String, at offset: Int) -> InProgressRecording.Segment {
        InProgressRecording.Segment(file: file, start_offset_ms: offset, end_offset_ms: nil)
    }

    private func record(
        mic: [InProgressRecording.Segment],
        system: [InProgressRecording.Segment],
        micInterruptions: [Interruption] = []
    ) throws {
        try InProgressRecording(
            started: started,
            tracks: [
                .init(kind: .mic, segments: mic, interruptions: micInterruptions, warnings: []),
                .init(kind: .system, segments: system, interruptions: [], warnings: []),
            ]
        ).write(to: dir)
    }

    private func writeAudio(_ name: String, frames: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
            ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.1 }
        let audio = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings)
        try audio.write(from: buffer)
    }

    private func readMeta() throws -> SessionMeta {
        try JSONDecoder().decode(SessionMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }
}
