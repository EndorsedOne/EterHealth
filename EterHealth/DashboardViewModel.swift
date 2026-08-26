import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var assessment: TwinAssessment?
    @Published private(set) var plan: WeeklyPlanStatus?
    @Published private(set) var performance: PerformanceSummary?
    @Published private(set) var balance: TrainingBalance?
    @Published private(set) var running: RunningPerformanceSummary?

    // TwinCore's engines no longer read GoalStore/LifestyleFactorStore/
    // InjuryStore/TwinStateStore internally — profile/events/activeInjuries/
    // calibration/personalAnchor join the `reviews` param this already had,
    // all read by ContentView (the caller) from their real stores.
    func refresh(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                profile: AthletePlanProfile, events: [LifestyleEvent], reviews: [WorkoutReview],
                activeInjuries: [InjuryRecord], calibration: TwinCalibration, personalAnchor: PersonalReadinessAnchor) {
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn,
                                           events: events, reviews: reviews, activeInjuries: activeInjuries,
                                           calibration: calibration, personalAnchor: personalAnchor, profile: profile)
        self.assessment = assessment
        plan = TrainingPlanEngine.status(
            health: health, imports: imports, readiness: assessment.score,
            muscles: assessment.muscles, checkIn: checkIn,
            profile: profile, reviews: reviews,
            physiologicalAlert: assessment.physiologicalAlert
        )
        performance = PerformanceEngine.summarize(health: health, imports: imports)
        balance = PerformanceEngine.balance(health: health, imports: imports, goalProfile: profile,
                                            events: events, reviews: reviews, activeInjuries: activeInjuries,
                                            calibration: calibration, personalAnchor: personalAnchor)
        running = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory,
            zones: health.runningHeartRateZones,
            reviews: reviews
        )
    }
}
