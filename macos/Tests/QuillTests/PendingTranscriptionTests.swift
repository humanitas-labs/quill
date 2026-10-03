import Foundation
import XCTest

@testable import quill

/// Filesystem and actor reentrancy checks, using synthetic metadata and a
/// fake engine. No actual audio, models, notifications, hooks, or user config.
@MainActor
final class PendingTranscriptionTests: XCTestCase {
    func testDiscoveryIncludesOnlyFinishedUntranscribedSessionsInNameOrder() throws {
        let root = try temporaryRoot()
        let newer = try session("2026.10.03-1100", in: root)
        let older = try session("2026.10.03-1000", in: root)
        let completed = try session("2026.10.03-0900", in: root)
        let original = Data("existing completed transcript".utf8)
        try original.write(to: completed.appendingPathComponent("transcript.json"))
        let live = root.appendingPathComponent("2026.10.03-1200", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: live.appendingPathComponent("in-progress.json"))
        try Data().write(to: root.appendingPathComponent("not-a-session"))

        XCTAssertEqual(TranscriptionCoordinator.pendingSessions(in: root), [older, newer])
        XCTAssertEqual(
            try Data(contentsOf: completed.appendingPathComponent("transcript.json")), original
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("meta.json").path))
    }

    func testDiscoveryOfMissingRootIsEmpty() throws {
        let missing = try temporaryRoot().appendingPathComponent("missing", isDirectory: true)
        XCTAssertEqual(TranscriptionCoordinator.pendingSessions(in: missing), [])
    }

    func testDisabledTranscriptionDoesNotStartRetryOrStartupJobs() async throws {
        let root = try temporaryRoot()
        let dir = try session("session", in: root)
        let engine = RetryTestEngine()
        let coordinator = coordinator(engine: engine, enabled: false)

        let result = await coordinator.retryPending(root: root)
        await coordinator.resumePending(root: root)
        await coordinator.enqueue(dir)

        XCTAssertEqual(result, .disabled)
        let counts = await engine.counts()
        XCTAssertEqual(counts.preparations, 0)
        XCTAssertTrue(counts.inputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
    }

    func testRepeatedScansAndEnqueuesExcludeActiveAndQueuedJobs() async throws {
        let root = try temporaryRoot()
        let first = try session("2026.10.03-1000", in: root)
        let second = try session("2026.10.03-1100", in: root)
        let preparing = expectation(description: "first job suspended during prepare")
        let drained = expectation(description: "queue drained")
        let gate = RetryTestGate()
        let engine = RetryTestEngine(gate: gate, onPrepare: { preparing.fulfill() })
        let coordinator = coordinator(engine: engine)
        await coordinator.setStatusHandler { status in
            if case .idle = status { drained.fulfill() }
        }

        let initial = await coordinator.retryPending(root: root)
        XCTAssertEqual(initial, .queued(2))
        await wait(for: preparing)
        let repeated = await coordinator.retryPending(root: root)
        XCTAssertEqual(repeated, .queued(0))
        await coordinator.resumePending(root: root)
        await coordinator.enqueue(first)
        await coordinator.enqueue(second)
        // Equivalent lexical paths must not bypass the same-directory guard.
        await coordinator.enqueue(first.appendingPathComponent(".", isDirectory: true))
        await gate.open()
        await wait(for: drained)

        let counts = await engine.counts()
        XCTAssertEqual(counts.preparations, 1)
        XCTAssertEqual(counts.releases, 1)
        XCTAssertEqual(counts.inputs, [first, second].map { $0.appendingPathComponent("mic.caf") })
        XCTAssertTrue(TranscriptionCoordinator.pendingSessions(in: root).isEmpty)
    }

    func testPrepareFailureDoesNotBlockLaterSessionAndCanBeRetried() async throws {
        let root = try temporaryRoot()
        let first = try session("2026.10.03-1000", in: root)
        let second = try session("2026.10.03-1100", in: root)
        let failed = expectation(description: "failure remains visible after later job")
        let retried = expectation(description: "retry drained successfully")
        let engine = RetryTestEngine(failedPreparations: [1])
        let coordinator = coordinator(engine: engine)
        await coordinator.setStatusHandler { status in
            if case .failed(let name) = status, name == first.lastPathComponent { failed.fulfill() }
        }

        let initial = await coordinator.retryPending(root: root)
        XCTAssertEqual(initial, .queued(2))
        await wait(for: failed)
        XCTAssertEqual(TranscriptionCoordinator.pendingSessions(in: root), [first])
        let completedURL = second.appendingPathComponent("transcript.json")
        let completed = try Data(contentsOf: completedURL)

        await coordinator.setStatusHandler { status in
            if case .idle = status { retried.fulfill() }
        }
        let retry = await coordinator.retryPending(root: root)
        XCTAssertEqual(retry, .queued(1))
        await wait(for: retried)
        XCTAssertEqual(try Data(contentsOf: completedURL), completed)
        let nothing = await coordinator.retryPending(root: root)
        XCTAssertEqual(nothing, .queued(0))
        let counts = await engine.counts()
        XCTAssertEqual(counts.preparations, 3)
        XCTAssertEqual(counts.releases, 2)
        XCTAssertEqual(counts.inputs, [second, first].map { $0.appendingPathComponent("mic.caf") })
    }

    func testRetryOfEarlierFailureWhileLaterJobIsActiveClearsResolvedFailure() async throws {
        let root = try temporaryRoot()
        let first = try session("2026.10.03-1000", in: root)
        let second = try session("2026.10.03-1100", in: root)
        let preparing = expectation(description: "both preparation attempts observed")
        preparing.expectedFulfillmentCount = 2
        let queueUpdated = expectation(description: "active progress reflects the added retry")
        let drained = expectation(description: "in-flight retry resolves old failure")
        let gate = RetryTestGate()
        let engine = RetryTestEngine(
            gate: gate, gatedPreparation: 2, failedPreparations: [1],
            onPrepare: { preparing.fulfill() }
        )
        let coordinator = coordinator(engine: engine)
        await coordinator.setStatusHandler { status in
            if case .idle = status { drained.fulfill() }
            if case .transcribing(let name, let queued) = status,
                name == second.lastPathComponent, queued == 1
            {
                queueUpdated.fulfill()
            }
        }

        let initial = await coordinator.retryPending(root: root)
        XCTAssertEqual(initial, .queued(2))
        await wait(for: preparing)
        let retry = await coordinator.retryPending(root: root)
        XCTAssertEqual(retry, .queued(1))
        await wait(for: queueUpdated)
        let repeated = await coordinator.retryPending(root: root)
        XCTAssertEqual(repeated, .queued(0))
        await gate.open()
        await wait(for: drained)

        let counts = await engine.counts()
        XCTAssertEqual(counts.preparations, 2)
        XCTAssertEqual(counts.releases, 1)
        XCTAssertEqual(counts.inputs, [second, first].map { $0.appendingPathComponent("mic.caf") })
        XCTAssertTrue(TranscriptionCoordinator.pendingSessions(in: root).isEmpty)
    }

    func testCompletedAfterScanIsNotOverwrittenOrTranscribed() async throws {
        let root = try temporaryRoot()
        let first = try session("2026.10.03-1000", in: root)
        let second = try session("2026.10.03-1100", in: root)
        let preparing = expectation(description: "first job held before transcription")
        let drained = expectation(description: "queue drained")
        let gate = RetryTestGate()
        let engine = RetryTestEngine(gate: gate, onPrepare: { preparing.fulfill() })
        let coordinator = coordinator(engine: engine)
        await coordinator.setStatusHandler { status in
            if case .idle = status { drained.fulfill() }
        }

        let initial = await coordinator.retryPending(root: root)
        XCTAssertEqual(initial, .queued(2))
        await wait(for: preparing)
        let completedURL = second.appendingPathComponent("transcript.json")
        let original = Data("finished by another worker after scan".utf8)
        try original.write(to: completedURL)
        await gate.open()
        await wait(for: drained)

        XCTAssertEqual(try Data(contentsOf: completedURL), original)
        let counts = await engine.counts()
        XCTAssertEqual(counts.inputs, [first.appendingPathComponent("mic.caf")])
    }

    private func coordinator(engine: RetryTestEngine, enabled: Bool = true) -> TranscriptionCoordinator {
        TranscriptionCoordinator(
            engineFactory: { engine }, transcriptionEnabled: { enabled },
            onStop: { nil }, notify: { _, _ in }
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-retry-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func session(_ name: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files":{"mic":"mic.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        // The fake engine never decodes this placeholder or produces speech.
        try Data([0]).write(to: dir.appendingPathComponent("mic.caf"))
        return dir
    }

    private func wait(for expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
}

private actor RetryTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RetryTestEngine: TranscriptionEngine {
    struct Counts: Sendable {
        var preparations = 0
        var releases = 0
        var inputs: [URL] = []
    }

    struct PrepareFailure: Error {}

    nonisolated let name = "fake"
    nonisolated let model = "no-model"
    private let gate: RetryTestGate?
    private let gatedPreparation: Int?
    private let failedPreparations: Set<Int>
    private let onPrepare: @Sendable () -> Void
    private var activity = Counts()

    init(
        gate: RetryTestGate? = nil, gatedPreparation: Int? = nil,
        failedPreparations: Set<Int> = [],
        onPrepare: @escaping @Sendable () -> Void = {}
    ) {
        self.gate = gate
        self.gatedPreparation = gatedPreparation
        self.failedPreparations = failedPreparations
        self.onPrepare = onPrepare
    }

    func prepare() async throws {
        activity.preparations += 1
        onPrepare()
        if gatedPreparation == nil || gatedPreparation == activity.preparations {
            await gate?.wait()
        }
        if failedPreparations.contains(activity.preparations) { throw PrepareFailure() }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        activity.inputs.append(audio)
        return []
    }

    func release() async {
        activity.releases += 1
    }

    func counts() -> Counts { activity }
}
