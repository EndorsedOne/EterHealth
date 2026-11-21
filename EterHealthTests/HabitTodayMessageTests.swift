import XCTest
@testable import EterHealth

final class HabitTodayMessageTests: XCTestCase {
    func testHighConfidenceNamesTheRealLearnedEffect() {
        let now = Date()
        var event = LifestyleEvent.empty
        event.date = now
        event.saunaMinutes = 20
        let learned = HabitAssociation(kind: .sauna, samples: 20,
            effects: [HabitMetricEffect(name: "HRV", changePercent: -8)], compositeChange: -8,
            direction: .adverse, confidence: .init(score: 80, level: .high, reason: "test"),
            headline: "Tu HRV se mueve después de sauna.")
        let message = HabitAssociationEngine.todayMessage(associations: [learned], events: [event], now: now)
        XCTAssertTrue(message?.text.contains(learned.headline) == true)
    }

    func testCaffeineRequiresYesterdayBedtimeExposureNotJustADose() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let learned = HabitAssociation(kind: .lateCaffeine, samples: 20, effects: [], compositeChange: -8,
            direction: .adverse, confidence: .init(score: 80, level: .high, reason: "test"), headline: "test")
        func message(_ date: Date, _ mg: Double) -> HabitTodayMessage? {
            HabitAssociationEngine.todayMessage(associations: [learned], events: [],
                caffeineExposures: [.init(kind: .lateCaffeine, date: date, overlapsOtherFactors: false, exposureLevel: mg)], now: now)
        }
        XCTAssertNotNil(message(yesterday, 25))
        XCTAssertNil(message(yesterday, 0))
        XCTAssertNil(message(now, 25))
        XCTAssertNil(message(now.addingTimeInterval(-4 * 86400), 25))
    }
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
