import XCTest
@testable import EterHealth

final class TrainingDecisionInsightsTests: XCTestCase {
    func testSofterWeekRequiresAllSignalsAndNeverDuplicatesActiveDeload() {
        let trends = [AnchorLiftTrend(name: "Banca", changePercent: 0), AnchorLiftTrend(name: "Sentadilla", changePercent: -5)]
        let missedRest = BlockAdherenceSummary(observedDays: 5, matchedDays: 3,
            plannedStrengthDays: 2, completedStrengthDays: 2, restDaysWithTraining: 2)
        XCTAssertNotNil(TrainingDecisionInsights.softerWeekSuggestion(ratio: 1.4, trends: trends, adherence: missedRest, deloadActive: false))
        XCTAssertNil(TrainingDecisionInsights.softerWeekSuggestion(ratio: 1.1, trends: trends, adherence: missedRest, deloadActive: false))
        XCTAssertNil(TrainingDecisionInsights.softerWeekSuggestion(ratio: 1.4, trends: [], adherence: missedRest, deloadActive: false))
        XCTAssertNil(TrainingDecisionInsights.softerWeekSuggestion(ratio: 1.4, trends: trends, adherence: missedRest, deloadActive: true))
        let noPlan = BlockAdherenceSummary(observedDays: 0, matchedDays: 0, plannedStrengthDays: 0, completedStrengthDays: 0)
        XCTAssertNil(TrainingDecisionInsights.softerWeekSuggestion(ratio: 1.4, trends: trends, adherence: noPlan, deloadActive: false))
    }

    func testArrowBandsAndUnknown() {
        XCTAssertEqual(AnchorLiftTrend(name: "x", changePercent: nil).arrow, "—")
        XCTAssertEqual(AnchorLiftTrend(name: "x", changePercent: 3).arrow, "↑")
        XCTAssertEqual(AnchorLiftTrend(name: "x", changePercent: 0).arrow, "→")
        XCTAssertEqual(AnchorLiftTrend(name: "x", changePercent: -5).arrow, "↓")
    }
}
