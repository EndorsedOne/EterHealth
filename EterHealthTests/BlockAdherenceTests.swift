import XCTest
@testable import EterHealth

final class BlockAdherenceTests: XCTestCase {
    func testMissedStrengthDayHasOneMismatchNotTwentyEightFailures() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let snapshot = PlanSnapshot(id: UUID(), date: yesterday, recommendation: "Fuerza", rationale: "", sessionKind: .strength)
        let summary = BlockAdherenceEngine.summarize(snapshots: [snapshot], strengthDates: [], aerobicDates: [], now: now)
        XCTAssertEqual(summary.observedDays, 1)
        XCTAssertEqual(summary.matchedDays, 0)
        XCTAssertEqual(summary.days.filter { $0.state == .mismatch }.count, 1)
        XCTAssertEqual(summary.days.filter { $0.state == .unknown }.count, 27)
    }
    func testNoPlanNeverCountsAsFailureEvenWithWorkouts() {
        let result = BlockAdherenceEngine.summarize(snapshots: [], strengthDates: [Date()], aerobicDates: [])
        XCTAssertEqual(result.observedDays, 0)
        XCTAssertEqual(result.matchedDays, 0)
        XCTAssertEqual(result.days.count, 28)
        XCTAssertTrue(result.days.allSatisfy { $0.state == .unknown })
    }
    func testMissingAndLegacyPlansAreUnknownNotMissed() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let legacy = PlanSnapshot(id: UUID(), date: yesterday, recommendation: "Fuerza", rationale: "")
        let result = BlockAdherenceEngine.summarize(snapshots: [legacy], strengthDates: [], aerobicDates: [], now: now)
        XCTAssertEqual(result.observedDays, 0)
    }

    func testOnlyOriginalPreWorkoutPrescriptionCounts() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let snapshot = PlanSnapshot(id: UUID(), date: yesterday, recommendation: "Fuerza", rationale: "", sessionKind: .strength)
        let result = BlockAdherenceEngine.summarize(snapshots: [snapshot],
            strengthDates: [yesterday.addingTimeInterval(600)], aerobicDates: [], now: now)
        XCTAssertEqual(result.observedDays, 1)
        XCTAssertEqual(result.matchedDays, 1)
        XCTAssertEqual(result.days.filter { $0.state == .matched }.count, 1)
        XCTAssertEqual(result.days.filter { $0.state == .unknown }.count, 27)
        let late = BlockAdherenceEngine.summarize(snapshots: [snapshot],
            strengthDates: [yesterday.addingTimeInterval(-600)], aerobicDates: [], now: now)
        XCTAssertEqual(late.observedDays, 0)
    }
}
