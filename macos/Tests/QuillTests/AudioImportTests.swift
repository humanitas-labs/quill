import AVFoundation
import XCTest

@testable import quill

/// Imported audio (an AirDropped Voice Memo) becomes an ordinary v2 session:
/// one `memo` track, one segment at offset 0, source file name preserved.
final class AudioImportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSupportedExtensions() {
        XCTAssertTrue(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/New Recording 3.m4a")))
        XCTAssertTrue(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/Main Street.QTA")))
        XCTAssertFalse(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(AudioImport.isSupported(URL(string: "https://example.com/a.m4a")!))
    }

    func testMetaIsOneCompleteMemoTrack() throws {
        let meta = AudioImport.meta(
            file: "memo.m4a",
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            frames: 48000 * 90,
            sampleRate: 48000,
            channels: 1,
            source: "New Recording 3.m4a"
        )
        XCTAssertEqual(meta.schema_version, 2)
        XCTAssertEqual(meta.status, .complete)
        XCTAssertEqual(meta.duration_seconds, 90)
        XCTAssertEqual(meta.tracks.count, 1)
        XCTAssertEqual(meta.tracks[0].kind, .memo)
        XCTAssertEqual(meta.tracks[0].segments[0].end_offset_ms, 90_000)

        try meta.write(to: dir)
        let (inputs, status) = try SessionMeta.readInputs(from: dir)
        XCTAssertEqual(status, .complete)
        XCTAssertEqual(inputs, [SessionMeta.TrackInput(file: "memo.m4a", speaker: "memo", offsetMs: 0)])
        XCTAssertEqual(SessionMeta.readSource(from: dir), "New Recording 3.m4a")
    }

    func testLiveRecordingMetaOmitsSource() throws {
        let meta = SessionMeta(
            schema_version: 2, started: "", ended: "", duration_seconds: 0,
            status: .complete, tracks: []
        )
        try meta.write(to: dir)
        let json = try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("source"))
        XCTAssertNil(SessionMeta.readSource(from: dir))
    }

    func testStageCopiesAudioAndWritesMeta() async throws {
        let source = dir.appendingPathComponent("New Recording.wav")
        try writeTone(to: source, seconds: 2)
        let root = dir.appendingPathComponent("Recordings", isDirectory: true)

        let session = try await AudioImport.stage(source, root: root)

        XCTAssertEqual(session.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source must not be moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("memo.wav").path))
        let meta = try JSONDecoder().decode(
            SessionMeta.self, from: Data(contentsOf: session.appendingPathComponent("meta.json"))
        )
        XCTAssertEqual(meta.source, "New Recording.wav")
        XCTAssertEqual(meta.tracks[0].segments[0].frames_written, 32000)
        XCTAssertEqual(meta.tracks[0].segments[0].end_offset_ms, 2000)

        // A second import of the same memo never reuses the first folder.
        let again = try await AudioImport.stage(source, root: root)
        XCTAssertNotEqual(again, session)
    }

    func testStageRejectsUnreadableAudioAndCleansUp() async throws {
        let source = dir.appendingPathComponent("broken.m4a")
        try Data("not audio".utf8).write(to: source)
        let root = dir.appendingPathComponent("Recordings", isDirectory: true)

        do {
            _ = try await AudioImport.stage(source, root: root)
            XCTFail("expected import to fail")
        } catch {}
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    private func writeTone(to url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frames = AVAudioFrameCount(16000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 16000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
