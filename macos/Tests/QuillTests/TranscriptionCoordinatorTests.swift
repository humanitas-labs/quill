import XCTest

@testable import quill

/// Offset-preserving merge: each segment file's transcript shifts by its
/// session-clock offset, and recovery gaps stay visible as timestamp gaps.
final class TranscriptionCoordinatorTests: XCTestCase {
    func testShiftedPreservesSegmentOffsets() {
        let raw = [
            TranscriptSegment(start: 0.5, end: 2.0, text: "hello"),
            TranscriptSegment(start: 3.0, end: 4.5, text: "world"),
        ]
        let shifted = Transcript.shifted(raw, speaker: "me", offsetMs: 1_691_120)
        XCTAssertEqual(
            shifted,
            [
                Transcript.Segment(speaker: "me", start_ms: 1_691_620, end_ms: 1_693_120, text: "hello"),
                Transcript.Segment(speaker: "me", start_ms: 1_694_120, end_ms: 1_695_620, text: "world"),
            ])
    }

    func testMergeInterleavesSegmentsAndRetainsGap() {
        // First mic segment ends at 10 s; the second starts at 25 s after a
        // 15 s capture gap. The system track spans the whole session.
        var merged: [Transcript.Segment] = []
        merged += Transcript.shifted(
            [TranscriptSegment(start: 1, end: 9, text: "before the gap")],
            speaker: "me", offsetMs: 0
        )
        merged += Transcript.shifted(
            [TranscriptSegment(start: 0, end: 5, text: "after the gap")],
            speaker: "me", offsetMs: 25000
        )
        merged += Transcript.shifted(
            [
                TranscriptSegment(start: 12, end: 14, text: "they talk"),
                TranscriptSegment(start: 31, end: 33, text: "they answer"),
            ],
            speaker: "them", offsetMs: 0
        )
        merged.sort { $0.start_ms < $1.start_ms }

        XCTAssertEqual(
            merged.map(\.text),
            [
                "before the gap", "they talk", "after the gap", "they answer",
            ])
        // The gap survives the merge: nothing from "me" between 10 s and 25 s,
        // and the second segment is not collapsed against the first's end.
        XCTAssertEqual(merged[2].start_ms, 25000)
    }

    func testRenderedHeaderCarriesCaptureStatus() {
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-08-03T20:09:35Z",
            segments: [
                Transcript.Segment(speaker: "me", start_ms: 0, end_ms: 1000, text: "hi")
            ]
        )
        XCTAssertTrue(
            transcript.rendered(title: "t", captureStatus: .recovered)
                .contains("capture: recovered")
        )
        XCTAssertTrue(
            transcript.rendered(title: "t", captureStatus: .incomplete)
                .contains("capture: incomplete")
        )
        XCTAssertFalse(
            transcript.rendered(title: "t", captureStatus: .complete).contains("capture:")
        )
        XCTAssertFalse(transcript.rendered(title: "t").contains("capture:"))
    }

    func testMarkdownWriteFailureLeavesSessionPending() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-transcript-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        let markdown = dir.appendingPathComponent("transcript.md")
        try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: true)

        let transcript = Transcript(
            engine: "test", model: "test", created_at: "2026-09-28T00:00:00Z",
            segments: []
        )
        XCTAssertThrowsError(try transcript.write(to: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertEqual(
            TranscriptionCoordinator.pendingSessions(in: root).map { $0.resolvingSymlinksInPath() },
            [dir.resolvingSymlinksInPath()]
        )

        try FileManager.default.removeItem(at: markdown)
        try transcript.write(to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(TranscriptionCoordinator.pendingSessions(in: root).isEmpty)
    }
}
