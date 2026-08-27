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
    // all read by ContentView (the caller) from their real stores. Bundled
    // into one TwinContext (PR1.5) and reused for every TwinCore call below
    // instead of repeating the same six labels three times.
    func refresh(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                profile: AthletePlanProfile, events: [LifestyleEvent], reviews: [WorkoutReview],
                activeInjuries: [InjuryRecord], calibration: TwinCalibration, personalAnchor: PersonalReadinessAnchor,
                travel: TravelEpisode?) {
        let context = TwinContext(profile: profile, events: events, reviews: reviews,
                                  activeInjuries: activeInjuries, calibration: calibration,
                                  personalAnchor: personalAnchor, travel: travel)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context)
        self.assessment = assessment
        plan = TrainingPlanEngine.status(
            health: health, imports: imports, readiness: assessment.score,
            muscles: assessment.muscles, checkIn: checkIn, context: context,
            physiologicalAlert: assessment.physiologicalAlert
        )
        performance = PerformanceEngine.summarize(health: health, imports: imports)
        balance = PerformanceEngine.balance(health: health, imports: imports, context: context)
        running = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory,
            zones: health.runningHeartRateZones,
            reviews: reviews
        )
    }
}
