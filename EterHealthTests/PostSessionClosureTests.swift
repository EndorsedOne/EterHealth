import XCTest
@testable import EterHealth

final class PostSessionClosureTests: XCTestCase {
    func testMissingEvidenceAndCaloriesDoNotProduceConclusion() {
        XCTAssertNil(PostSessionClosure.strength([:]))
        XCTAssertNil(PostSessionClosure.cardio(verdict: .init(isQuality: false, basis: .insufficient)))
        XCTAssertNil(PostSessionClosure.cardio(verdict: .init(isQuality: true, basis: .legacyCalories)))
    }

    func testEffectiveStimulusAndDetectedIntervals() {
        XCTAssertTrue(PostSessionClosure.strength(["Pecho": 3.5, "Core": 1])?.counted.contains("Pecho") == true)
        let result = PostSessionClosure.cardio(verdict: .init(isQuality: true, basis: .detectedStructure))
        XCTAssertTrue(result?.counted.contains("Intervalos") == true)
        XCTAssertTrue(result?.tomorrow.contains("recuperación") == true)
    }
}
