import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var assessment: TwinAssessment?
    @Published private(set) var plan: WeeklyPlanStatus?
    @Published private(set) var performance: PerformanceSummary?
    @Published private(set) var balance: TrainingBalance?
    @Published private(set) var running: RunningPerformanceSummary?
    @Published private(set) var goalDistances: [GoalDistance] = []
    @Published private(set) var isLoadingPerformance = false
    // Reto 1 · curva de tendencias del día ya calculada. Se computa aquí, en el
    // refresco debounced del gemelo, y NUNCA dentro de body: build() recorre el
    // histórico y llama a PersonalBaselineEngine, justo el trabajo caro que el
    // reto 3 saca del primer render.
    @Published private(set) var energyTimeline: EnergyTimelineEngine.Result?
    // La lectura de Salud contra la que se calculó Rendimiento. Mientras no
    // cambie, la caché es válida y no se recomputa — antes se tiraba a la basura
    // en CADA refresh() del gemelo (check-in, estilo de vida, foreground...),
    // así que volver a Rendimiento siempre lo recargaba desde cero.
    private struct PerformanceStamp: Equatable {
        let healthUpdated: Date?
        let importCount: Int
        let latestImport: Date?
        let reviewCount: Int
        let latestReview: Date?
        let goalSignature: String
    }
    private var performanceStamp: PerformanceStamp?

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
        // Rendimiento NO se invalida aquí. Se calcula la primera vez que se
        // entra en esa pestaña y se conserva mientras la lectura de Salud no
        // cambie (performanceStamp). Antes se ponía a nil en cada refresh() del
        // gemelo, así que un check-in, un factor de estilo de vida o simplemente
        // volver a la app forzaban a recargar Rendimiento entero.
    }

    func refreshPerformance(health: HealthStore, imports: ImportStore, reviews: [WorkoutReview],
                            context: TwinContext) async {
        // Ya calculado para esta misma lectura de Salud: nada que hacer. Sólo se
        // recomputa cuando health.lastUpdated cambia (datos nuevos) o si nunca
        // se calculó.
        let stamp = PerformanceStamp(
            healthUpdated: health.lastUpdated,
            importCount: imports.workoutCount,
            latestImport: imports.workouts.map(\.start).max(),
            reviewCount: reviews.count,
            latestReview: reviews.map(\.recordedAt).max(),
            goalSignature: context.profile.goals.map {
                "\($0.id.uuidString)|\($0.kind.rawValue)|\($0.targetValue ?? -1)|\($0.date?.timeIntervalSince1970 ?? -1)|\($0.isActive)"
            }.sorted().joined(separator: ";")
        )
        if performance != nil, balance != nil, running != nil,
           performanceStamp == stamp { return }
        guard !isLoadingPerformance else { return }
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
        await Task.yield()
        if let running {
            let strength = StrengthProgressEngine.summarize(imports.workouts)
            goalDistances = GoalDistanceEngine.evaluate(
                goals: context.profile.goals, running: running, strength: strength,
                importedWorkouts: imports.workouts, healthWorkouts: health.workoutHistory
            )
        }
        performanceStamp = stamp
        isLoadingPerformance = false
    }
}
