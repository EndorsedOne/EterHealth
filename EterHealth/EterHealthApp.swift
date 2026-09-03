import SwiftUI

@main
struct EterHealthApp: App {
    @StateObject private var health = HealthStore()
    @StateObject private var imports = ImportStore()
    @StateObject private var strengthRoutines = StrengthRoutineStore()
    @StateObject private var watchMetrics = WatchMetricsStore()
    @StateObject private var checkIns = DailyCheckInStore()
    @StateObject private var lifestyle = LifestyleFactorStore.shared
    @StateObject private var workoutReviews = WorkoutReviewStore.shared
    @StateObject private var planHistory = PlanHistoryStore.shared
    @StateObject private var goals = GoalStore.shared
    @StateObject private var injuries = InjuryStore.shared
    @StateObject private var twinStates = TwinStateStore.shared
    @StateObject private var temperatureDeviations = TemperatureDeviationStore.shared
    // PR14: sin .shared — el brief prohíbe singletons nuevos y el patrón
    // correcto es este (mismo que health/imports/checkIns).
    @StateObject private var travel = TravelEpisodeStore()
    @StateObject private var workoutEnrichments = WorkoutEnrichmentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(health)
                .environmentObject(imports)
                .environmentObject(strengthRoutines)
                .environmentObject(watchMetrics)
                .environmentObject(checkIns)
                .environmentObject(lifestyle)
                .environmentObject(workoutReviews)
                .environmentObject(planHistory)
                .environmentObject(goals)
                .environmentObject(injuries)
                .environmentObject(twinStates)
                .environmentObject(temperatureDeviations)
                .environmentObject(travel)
                .environmentObject(workoutEnrichments)
                .task {
                    // HealthKit puede despertar el proceso sin que el usuario
                    // abra la ventana. El widget se reescribe desde el store,
                    // no desde onAppear/onChange de ContentView.
                    health.didRefresh = { [weak health, weak imports, weak checkIns, weak lifestyle,
                                           weak workoutReviews, weak goals, weak injuries,
                                           weak twinStates, weak travel] in
                        guard let health, let imports, let checkIns, let lifestyle,
                              let workoutReviews, let goals, let injuries,
                              let twinStates, let travel else { return }
                        let context = TwinContext(
                            profile: goals.profile, events: lifestyle.events,
                            reviews: workoutReviews.reviews, activeInjuries: injuries.active,
                            calibration: twinStates.calibration,
                            personalAnchor: twinStates.personalAnchor(),
                            travel: travel.episodeForEvaluation(), travelHistory: travel.episodes
                        )
                        let assessment = TwinEngine.assess(
                            health: health, imports: imports,
                            checkIn: checkIns.entry(), context: context
                        )
                        WidgetSnapshotStore.update(
                            assessment: assessment, health: health, imports: imports,
                            checkIn: checkIns.entry(), lifestyle: lifestyle,
                            travel: travel.episodeForEvaluation()
                        )
                    }
                    // La primera interacción pertenece a Hoy. Una vez que el
                    // primer frame y sus datos mínimos han aparecido, dejamos
                    // que Salud prepare el histórico para las demás pestañas
                    // sin hacer al usuario esperar a pulsarlas.
                    await health.prepare()
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    await health.loadExtendedHistory()
                }
        }
    }
}
