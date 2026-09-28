import AVFoundation
import XCTest

@testable import quill

/// A recorder the session can start, stop, and poll without audio devices.
/// Tests drive its telemetry by hand and can make starts fail on demand.
final class FakeRecorder: TrackRecorder, @unchecked Sendable {
    let kind: TrackKind
    var current = TelemetrySnapshot()
    var startedFiles: [String] = []
    var startAttempts = 0
    var failStarts = false
    private var active = false

    init(kind: TrackKind) {
        self.kind = kind
    }

    struct StartError: Error {}

    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        startAttempts += 1
        if failStarts { throw StartError() }
        active = true
        current = TelemetrySnapshot()
        startedFiles.append(url.lastPathComponent)
    }

    func stop() -> SegmentStats? {
        guard active else { return nil }
        active = false
        return SegmentStats(
            file: startedFiles.last ?? "?",
            firstWriteMs: current.firstWriteMs,
            lastBufferEndMs: current.lastBufferEndMs,
            framesWritten: current.framesWritten,
            sampleRateHz: 48000,
            channels: 1
        )
    }

    func telemetry() -> TelemetrySnapshot {
        current
    }

    /// Mark the fake as continuously writing from `first` through `last`.
    func writes(first: Int, last: Int) {
        current.firstWriteMs = first
        current.lastWriteMs = last
        current.lastBufferEndMs = last
        current.framesWritten = Int64(max(1, last - first)) * 48
    }
}

/// Recovery orchestration and stop-race tests with fake recorders and a
/// manual clock — no microphone, AirPods, TCC, or real-time sleeps.
@MainActor
final class RecordingSessionTests: XCTestCase {
    private final class TimeBox: @unchecked Sendable {
        var ms = 0
    }

    private var root: URL!
    private var time: TimeBox!
    private var mic: FakeRecorder!
    private var system: FakeRecorder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        time = TimeBox()
        mic = FakeRecorder(kind: .mic)
        system = FakeRecorder(kind: .system)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession() throws -> RecordingSession {
        let time = time!
        return try RecordingSession(
            root: root,
            recorders: [system, mic],
            policy: .production,
            nowMs: { time.ms }
        )
    }

    /// Advance the manual clock, refresh both fakes' "still writing" state
    /// unless a track is deliberately stalled, and run one watchdog pass.
    private func tick(_ session: RecordingSession, at ms: Int, micStalled: Bool = false) {
        time.ms = ms
        if !micStalled {
            mic.writes(first: mic.current.firstWriteMs ?? 500, last: ms - 100)
        }
        system.writes(first: system.current.firstWriteMs ?? 0, last: ms - 100)
        session.tick()
    }

    private func readMeta(_ session: RecordingSession) throws -> SessionMeta {
        try JSONDecoder().decode(
            SessionMeta.self,
            from: Data(contentsOf: session.dir.appendingPathComponent("meta.json"))
        )
    }

    func testUninterruptedSessionWritesCompleteV2Metadata() throws {
        let session = try makeSession()
        try session.start()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.dir.appendingPathComponent(InProgressRecording.fileName).path
            ))
        tick(session, at: 1000)
        tick(session, at: 60000)

        time.ms = 61000
        let result = session.stop()
        XCTAssertEqual(result.status, .complete)

        let meta = try readMeta(session)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: session.dir.appendingPathComponent(InProgressRecording.fileName).path
            ))
        XCTAssertEqual(meta.schema_version, 2)
        XCTAssertEqual(meta.status, .complete)
        XCTAssertEqual(meta.tracks.map(\.kind), [.mic, .system])
        XCTAssertEqual(meta.tracks[0].segments.map(\.file), ["mic.caf"])
        XCTAssertTrue(meta.tracks[0].interruptions.isEmpty)
    }

    func testStallRotatesOnceAndRecoversWithoutTouchingOtherTrack() throws {
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)

        // Mic stalls; system keeps writing. Detection rotates the mic once.
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        XCTAssertEqual(mic.startedFiles, ["mic.caf", "mic-002.caf"])
        XCTAssertEqual(system.startedFiles, ["system.caf"])
        let inProgress = try InProgressRecording.read(from: session.dir)
        let micRecord = try XCTUnwrap(inProgress.tracks.first { $0.kind == .mic })
        XCTAssertEqual(micRecord.segments.map(\.file), ["mic.caf", "mic-002.caf"])
        XCTAssertEqual(micRecord.segments.first?.end_offset_ms, 1000)

        // Replacement segment stabilizes; later stop is a recovered session.
        for ms in stride(from: 7000, through: 13000, by: 1000) {
            tick(session, at: ms)
        }
        time.ms = 14000
        mic.writes(first: mic.current.firstWriteMs ?? 6900, last: 13900)
        system.writes(first: 0, last: 13900)
        let result = session.stop()
        XCTAssertEqual(result.status, .recovered)

        let meta = try readMeta(session)
        let micTrack = meta.tracks.first { $0.kind == .mic }!
        XCTAssertEqual(micTrack.status, .recovered)
        XCTAssertEqual(micTrack.segments.map(\.file), ["mic.caf", "mic-002.caf"])
        XCTAssertEqual(micTrack.segments[0].end_offset_ms, 1000)
        XCTAssertEqual(micTrack.interruptions.count, 1)
        XCTAssertNotNil(micTrack.interruptions[0].recovered_offset_ms)
        let systemTrack = meta.tracks.first { $0.kind == .system }!
        XCTAssertEqual(systemTrack.status, .complete)
        XCTAssertEqual(systemTrack.segments.map(\.file), ["system.caf"])
    }

    func testExhaustedRetriesDegradeOnceAndFinalizeIncomplete() throws {
        var degradedTracks: [TrackKind] = []
        let session = try makeSession()
        session.onDegraded = { degradedTracks.append($0) }
        try session.start()
        tick(session, at: 1000)

        // Every restart fails: attempt 1 immediately, 2 after 500 ms, 3 after
        // 2 s more. Exactly one degraded notification.
        mic.failStarts = true
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        tick(session, at: 7000, micStalled: true)
        tick(session, at: 9500, micStalled: true)
        XCTAssertEqual(degradedTracks, [.mic])
        XCTAssertEqual(mic.startAttempts, 4)  // initial + 3 recovery attempts

        // Repeated watchdog ticks stay quiet.
        tick(session, at: 10500, micStalled: true)
        tick(session, at: 11500, micStalled: true)
        XCTAssertEqual(degradedTracks, [.mic])
        XCTAssertEqual(mic.startAttempts, 4)

        time.ms = 12000
        let result = session.stop()
        XCTAssertEqual(result.status, .incomplete)
        let meta = try readMeta(session)
        let micTrack = meta.tracks.first { $0.kind == .mic }!
        XCTAssertEqual(micTrack.status, .incomplete)
        XCTAssertEqual(micTrack.interruptions[0].attempts, 3)
        XCTAssertNil(micTrack.interruptions[0].recovered_offset_ms)
        // The healthy track still finishes complete.
        XCTAssertEqual(meta.tracks.first { $0.kind == .system }!.status, .complete)
    }

    func testStopDuringRetryDelayCreatesNoPostStopSegment() throws {
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)

        // Attempt 1 fails; attempt 2 is pending 500 ms out when stop lands.
        mic.failStarts = true
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        let attemptsAtStop = mic.startAttempts

        time.ms = 6200
        let result = session.stop()
        XCTAssertEqual(result.status, .incomplete)

        // The delayed retry firing after stop must not start a recorder.
        time.ms = 7000
        session.tick()
        XCTAssertEqual(mic.startAttempts, attemptsAtStop)

        // Metadata is still parseable and truthful.
        let meta = try readMeta(session)
        XCTAssertEqual(meta.tracks.first { $0.kind == .mic }!.segments.map(\.file), ["mic.caf"])
    }

    func testStartupFailureRollsBackStartedTracks() throws {
        mic.failStarts = true
        let session = try makeSession()
        XCTAssertThrowsError(try session.start())
        // System started first and must be torn down again.
        XCTAssertEqual(system.startedFiles, ["system.caf"])
        XCTAssertNil(system.stop())  // already stopped by rollback
    }

    func testOrphanedRotatedSessionFeedsV2Recovery() throws {
        var session: RecordingSession? = try makeSession()
        try session!.start()
        tick(session!, at: 1000)
        mic.writes(first: 500, last: 1000)
        tick(session!, at: 6000, micStalled: true)
        let dir = session!.dir
        try writeAudio("mic.caf", in: dir)
        try writeAudio("mic-002.caf", in: dir)
        try writeAudio("system.caf", in: dir)

        // Releasing the owner models a dead process: its kernel lock drops,
        // while the in-progress record and CAF files remain on disk.
        session = nil
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(InProgressRecording.fileName).path
            ))
        XCTAssertEqual(SessionRecovery.recoverInterrupted(in: root).count, 1)
        let meta = try JSONDecoder().decode(
            SessionMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))
        )
        XCTAssertEqual(meta.status, .incomplete)
        let micTrack = try XCTUnwrap(meta.tracks.first { $0.kind == .mic })
        XCTAssertEqual(micTrack.segments.map(\.file), ["mic.caf", "mic-002.caf"])
        XCTAssertEqual(micTrack.interruptions.map(\.reason), ["callback_stalled", "process_exited"])
    }

    private func writeAudio(_ name: String, in dir: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
            ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0.1 }
        let audio = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings)
        try audio.write(from: buffer)
    }
}
