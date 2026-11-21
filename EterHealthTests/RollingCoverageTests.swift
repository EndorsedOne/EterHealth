import XCTest
@testable import EterHealth

final class RollingCoverageTests: XCTestCase {
    func testCoveredStrengthExpiresDuringForecast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sixDaysAgo = now.addingTimeInterval(-6 * 86400)
        XCTAssertTrue(TrainingPlanEngine.isInsideCoverageWindow(sixDaysAgo, at: now))
        XCTAssertFalse(TrainingPlanEngine.isInsideCoverageWindow(sixDaysAgo, at: now.addingTimeInterval(2 * 86400)))
    }

    func testProjectedSessionOnlyCountsAfterItsDateAndAlsoExpires() {
        let session = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(TrainingPlanEngine.isInsideCoverageWindow(session, at: session.addingTimeInterval(-86400)))
        XCTAssertTrue(TrainingPlanEngine.isInsideCoverageWindow(session, at: session.addingTimeInterval(6 * 86400)))
        XCTAssertFalse(TrainingPlanEngine.isInsideCoverageWindow(session, at: session.addingTimeInterval(8 * 86400)))
    }
}
