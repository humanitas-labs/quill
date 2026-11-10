import XCTest

@testable import quill

final class RecordingTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRemainingBeforeDeadline() {
        let timer = StopTimer(deadline: now.addingTimeInterval(600))
        XCTAssertEqual(timer.remaining(at: now), 600, accuracy: 0.001)
        XCTAssertEqual(
            timer.remaining(at: now.addingTimeInterval(599.5)), 0.5, accuracy: 0.001)
    }

    func testRemainingAtDeadlineIsZero() {
        let timer = StopTimer(deadline: now)
        XCTAssertEqual(timer.remaining(at: now), 0)
    }

    func testRemainingAfterDeadlineClampsToZero() {
        let timer = StopTimer(deadline: now)
        XCTAssertEqual(timer.remaining(at: now.addingTimeInterval(30)), 0)
    }

    func testIsExpiredBoundary() {
        let timer = StopTimer(deadline: now.addingTimeInterval(600))
        XCTAssertFalse(timer.isExpired(at: now))
        XCTAssertTrue(timer.isExpired(at: now.addingTimeInterval(600)))
        XCTAssertTrue(timer.isExpired(at: now.addingTimeInterval(601)))
    }

    func testExtendedMovesDeadline() {
        let timer = StopTimer(deadline: now.addingTimeInterval(600))
        let extended = timer.extended(by: 300)
        XCTAssertEqual(
            extended.deadline.timeIntervalSince(timer.deadline), 300, accuracy: 0.001)
        XCTAssertEqual(extended.remaining(at: now), 900, accuracy: 0.001)
    }

    func testExtendedTimerIsNotExpiredWhereOriginalWas() {
        let timer = StopTimer(deadline: now)
        let extended = timer.extended(by: 300)
        XCTAssertTrue(timer.isExpired(at: now.addingTimeInterval(1)))
        XCTAssertFalse(extended.isExpired(at: now.addingTimeInterval(1)))
    }

    func testLabel() {
        XCTAssertEqual(StopTimer.label(for: 300), "5 minutes")
        XCTAssertEqual(StopTimer.label(for: 600), "10 minutes")
        XCTAssertEqual(StopTimer.label(for: 900), "15 minutes")
        XCTAssertEqual(StopTimer.label(for: 1800), "30 minutes")
        XCTAssertEqual(StopTimer.label(for: 3600), "1 hour")
        XCTAssertEqual(StopTimer.label(for: 5400), "90 minutes")
        XCTAssertEqual(StopTimer.label(for: 7200), "2 hours")
    }
}
