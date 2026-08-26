import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var assessment: TwinAssessment?
    @Published private(set) var plan: WeeklyPlanStatus?
    @Published private(set) var performance: PerformanceSummary?
    @Published private(set) var balance: TrainingBalance?
    @Published private(set) var running: RunningPerformanceSummary?

    func refresh(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?, reviews: [WorkoutReview]) {
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn)
        self.assessment = assessment
        plan = TrainingPlanEngine.status(
            health: health, imports: imports, readiness: assessment.score,
            muscles: assessment.muscles, checkIn: checkIn,
            physiologicalAlert: assessment.physiologicalAlert
        )
        performance = PerformanceEngine.summarize(health: health, imports: imports)
        balance = PerformanceEngine.balance(health: health, imports: imports)
        running = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory,
            zones: health.runningHeartRateZones,
            reviews: reviews
        )
    }
}
