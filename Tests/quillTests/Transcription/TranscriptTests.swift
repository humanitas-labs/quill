import Foundation
import Testing

@testable import quill

struct TranscriptTests {
    @Test("A failed Markdown write does not leave the completion marker")
    func failedMarkdownWriteDoesNotLeaveCompletionMarker() throws {
        let fileManager = FileManager.default
        let session = fileManager.temporaryDirectory
            .appendingPathComponent("quill-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: session) }

        try fileManager.createDirectory(
            at: session.appendingPathComponent("transcript.md", isDirectory: true),
            withIntermediateDirectories: true
        )

        let transcript = Transcript(
            engine: "parakeet",
            model: "test-model",
            created_at: "2026-07-28T00:00:00Z",
            segments: []
        )

        do {
            try transcript.write(to: session)
            Issue.record("Expected writing transcript.md over a directory to fail.")
        } catch {
            // Expected: transcript.md is a directory.
        }

        let completionMarker = session.appendingPathComponent("transcript.json")
        #expect(
            fileManager.fileExists(atPath: completionMarker.path) == false,
            "A failed transcript.md write must leave the session pending."
        )
    }
}
