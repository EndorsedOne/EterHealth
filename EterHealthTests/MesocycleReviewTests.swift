import XCTest
@testable import EterHealth

final class MesocycleReviewTests: XCTestCase {
    func testNoReviewBeforeFourWeeksOrWithoutAnchor() {
        let now = Date()
        XCTAssertNil(MesocycleReviewEngine.review(anchor: nil, now: now, exercises: [], deloadActive: false))
        XCTAssertNil(MesocycleReviewEngine.review(anchor: now.addingTimeInterval(-20 * 86400), now: now, exercises: [], deloadActive: false))
    }
    func testCalendarDoesNotImposeDeloadOrInventLiftTrend() {
        let now = Date()
        let review = MesocycleReviewEngine.review(anchor: now.addingTimeInterval(-29 * 86400), now: now,
                                                  exercises: [], deloadActive: false)
        XCTAssertNotNil(review)
        XCTAssertTrue(review?.lifts.isEmpty == true)
        XCTAssertTrue(review?.detail.contains("No se impone") == true)
    }
}
