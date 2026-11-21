import XCTest
@testable import EterHealth

final class HabitTodayMessageTests: XCTestCase {
    private func association(_ level: TrustLevel, samples: Int = 12) -> HabitAssociation {
        HabitAssociation(kind: .sauna, samples: samples, effects: [], compositeChange: -8,
                         direction: .adverse,
                         confidence: ConfidenceAssessment(score: level == .high ? 80 : 50, level: level, reason: "test"),
                         headline: "test")
    }

    func testRecentHabitWithMediumOrHighEvidenceProducesMessage() {
        let now = Date()
        var event = LifestyleEvent.empty
        event.date = now.addingTimeInterval(-12 * 3600)
        event.saunaMinutes = 20
        for level: TrustLevel in [.medium, .high] {
            XCTAssertNotNil(HabitAssociationEngine.todayMessage(associations: [association(level)], events: [event], now: now))
        }
    }

    func testLowMissingAndExpiredEvidenceRemainSilent() {
        let now = Date()
        var event = LifestyleEvent.empty
        event.date = now
        event.saunaMinutes = 20
        XCTAssertNil(HabitAssociationEngine.todayMessage(associations: [association(.low)], events: [event], now: now))
        XCTAssertNil(HabitAssociationEngine.todayMessage(associations: [association(.high, samples: 0)], events: [event], now: now))
        XCTAssertNil(HabitAssociationEngine.todayMessage(associations: [], events: [event], now: now))
        event.date = now.addingTimeInterval(-37 * 3600)
        XCTAssertNil(HabitAssociationEngine.todayMessage(associations: [association(.high)], events: [event], now: now))
        event.date = now.addingTimeInterval(3600)
        XCTAssertNil(HabitAssociationEngine.todayMessage(associations: [association(.high)], events: [event], now: now))
    }
}
