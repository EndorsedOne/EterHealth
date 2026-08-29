import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var assessment: TwinAssessment?
    @Published private(set) var plan: WeeklyPlanStatus?
    @Published private(set) var performance: PerformanceSummary?
    @Published private(set) var balance: TrainingBalance?
    @Published private(set) var running: RunningPerformanceSummary?
    @Published private(set) var isLoadingPerformance = false
    // Reto 1 · curva de tendencias del día ya calculada. Se computa aquí, en el
    // refresco debounced del gemelo, y NUNCA dentro de body: build() recorre el
    // histórico y llama a PersonalBaselineEngine, justo el trabajo caro que el
    // reto 3 saca del primer render.
    @Published private(set) var energyTimeline: EnergyTimelineEngine.Result?

    // TwinCore's engines no longer read GoalStore/LifestyleFactorStore/
    // InjuryStore/TwinStateStore internally — profile/events/activeInjuries/
    // calibration/personalAnchor join the `reviews` param this already had,
    // all read by ContentView (the caller) from their real stores. Bundled
    // into one TwinContext (PR1.5) and reused for every TwinCore call below
    // instead of repeating the same six labels three times.
    func refresh(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                profile: AthletePlanProfile, events: [LifestyleEvent], reviews: [WorkoutReview],
                activeInjuries: [InjuryRecord], calibration: TwinCalibration, personalAnchor: PersonalReadinessAnchor,
                travel: TravelEpisode?, travelHistory: [TravelEpisode]) {
        let context = TwinContext(profile: profile, events: events, reviews: reviews,
                                  activeInjuries: activeInjuries, calibration: calibration,
                                  personalAnchor: personalAnchor, travel: travel, travelHistory: travelHistory)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context)
        self.assessment = assessment
        energyTimeline = EnergyTimelineEngine.build(
            assessment: assessment, health: health, imports: imports,
            checkIn: checkIn, lifestyle: events, travel: travel
        )
        plan = TrainingPlanEngine.status(
            health: health, imports: imports, readiness: assessment.score,
            muscles: assessment.muscles, checkIn: checkIn, context: context,
            physiologicalAlert: assessment.physiologicalAlert
        )
        // Rendimiento no es necesario para responder la primera pregunta de la
        // app ("¿cómo estoy hoy?"). Invalidamos su caché y lo calculamos sólo
        // al entrar en esa pestaña; antes se hacía aquí, bloqueando el primer
        // render y cada actualización de Salud con tres análisis adicionales.
        performance = nil
        balance = nil
        running = nil
    }

    func refreshPerformance(health: HealthStore, imports: ImportStore, reviews: [WorkoutReview],
                            context: TwinContext) async {
        guard performance == nil, balance == nil, running == nil, !isLoadingPerformance else { return }
        isLoadingPerformance = true
        // Cede el primer frame al indicador de carga antes de recorrer el
        // histórico. Los motores son síncronos por diseño, así que dividirlos
        // evita una única pausa larga al navegar a Rendimiento.
        await Task.yield()
        running = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory,
            zones: health.runningHeartRateZones,
            reviews: reviews
        )
        await Task.yield()
        performance = PerformanceEngine.summarize(health: health, imports: imports)
        await Task.yield()
        balance = PerformanceEngine.balance(health: health, imports: imports, context: context)
        isLoadingPerformance = false
    }
}
