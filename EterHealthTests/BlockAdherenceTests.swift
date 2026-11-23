import XCTest
@testable import EterHealth

final class BlockAdherenceTests: XCTestCase {
    func testNoPlanNeverCountsAsFailureEvenWithWorkouts() {
        let result = BlockAdherenceEngine.summarize(snapshots: [], strengthDates: [Date()], aerobicDates: [])
        XCTAssertEqual(result.observedDays, 0)
        XCTAssertEqual(result.matchedDays, 0)
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
        let late = BlockAdherenceEngine.summarize(snapshots: [snapshot],
            strengthDates: [yesterday.addingTimeInterval(-600)], aerobicDates: [], now: now)
        XCTAssertEqual(late.observedDays, 0)
    }
}
