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
                .task { await health.prepare() }
        }
    }
}
