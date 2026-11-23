import XCTest
@testable import EterHealth

final class QualityLoadTests: XCTestCase {
    func testPaceAndHeartRateQualityDoNotActivateStructuredLoadBonus() {
        for basis: RunQualityBasis in [.pace, .heartRate] {
            let verdict = RunQualityVerdict(isQuality: true, basis: basis)
            XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(verdict: verdict), 1)
            XCTAssertFalse(PostSessionClosure.cardio(verdict: verdict)?.tomorrow.contains("×1,20") == true)
        }
        for basis: RunQualityBasis in [.detectedStructure, .review] {
            let verdict = RunQualityVerdict(isQuality: true, basis: basis)
            XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(verdict: verdict), 1.20)
            XCTAssertTrue(PostSessionClosure.cardio(verdict: verdict)?.tomorrow.contains("×1,20") == true)
        }
    }
    private func makeRun() -> HealthWorkout {
        HealthWorkout(id: UUID(), date: Date(), durationMinutes: 45, calories: nil,
                      distanceKilometers: nil, averageHeartRate: nil, elevationMeters: nil,
                      activity: "Carrera", muscleGroups: [:], source: "Watch")
    }

    func testMissingSignalsAndSteadyRunStayNeutral() {
        let workout = makeRun()
        XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(workout), 1)
        let steady = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 45, calories: 600,
            distanceKilometers: 8, averageHeartRate: 125, elevationMeters: nil,
            activity: "Carrera", muscleGroups: [:], source: "Watch")
        XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(steady), 1)
    }

    func testRepeatedStructureIncreasesLoadWithinBound() {
        var workout = makeRun()
        workout.runningStructure = RunningSessionStructure(kind: .sprintIntervals,
            repetitions: 6, workSeconds: 120, recoverySeconds: 120, confidence: .medium,
            evidence: "test", intervals: [])
        let factor = PerformanceEngine.structuredQualityLoadMultiplier(workout)
        XCTAssertEqual(factor, 1.20)
        XCTAssertLessThanOrEqual(factor * PerformanceEngine.workoutEffortMultiplier(10), 1.50)
        let easyReview = WorkoutReview(workoutID: "health-\(workout.id.uuidString)",
            workoutDate: workout.date, effort: 3, outcome: .asPlanned,
            muscleFeeling: 3, repsInReserve: 2, pain: false, note: "",
            purpose: .easy, recordedAt: workout.date)
        XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(workout, review: easyReview), 1)
        let qualityReview = WorkoutReview(workoutID: "health-\(workout.id.uuidString)",
            workoutDate: workout.date, effort: 8, outcome: .asPlanned,
            muscleFeeling: 3, repsInReserve: 2, pain: false, note: "",
            purpose: .quality, recordedAt: workout.date)
        XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(makeRun(), review: qualityReview), 1.20)
        workout.runningStructure = RunningSessionStructure(kind: .sprintIntervals,
            repetitions: 6, workSeconds: 120, recoverySeconds: 120, confidence: .low,
            evidence: "test", intervals: [])
        XCTAssertEqual(PerformanceEngine.structuredQualityLoadMultiplier(workout), 1)
    }
}
