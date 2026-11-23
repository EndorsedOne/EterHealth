import Foundation

struct AnchorLiftTrend: Identifiable {
    let name: String
    let changePercent: Double?
    var id: String { name }
    var arrow: String {
        guard let changePercent else { return "—" }
        return changePercent >= 2 ? "↑" : changePercent <= -4 ? "↓" : "→"
    }
}

enum TrainingDecisionInsights {
    static func trends(_ exercises: [ExerciseStrengthProgress], now: Date = Date(),
                       calendar: Calendar = .current) -> [AnchorLiftTrend] {
        let middle = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let start = calendar.date(byAdding: .day, value: -28, to: now) ?? now
        return exercises.sorted { $0.name < $1.name }.prefix(3).map { exercise in
            let early = exercise.points.filter { $0.date >= start && $0.date < middle && $0.estimatedOneRM.isFinite && $0.estimatedOneRM > 0 }
            let late = exercise.points.filter { $0.date >= middle && $0.date <= now && $0.estimatedOneRM.isFinite && $0.estimatedOneRM > 0 }
            let enough = Set(early.map { calendar.startOfDay(for: $0.date) }).count >= 2
                && Set(late.map { calendar.startOfDay(for: $0.date) }).count >= 2
            let change: Double?
            if enough, let first = early.map(\.estimatedOneRM).max(), let last = late.map(\.estimatedOneRM).max() {
                change = (last / first - 1) * 100
            } else { change = nil }
            return AnchorLiftTrend(name: exercise.name, changePercent: change)
        }
    }

    /// Conservative conjunction, not an automatic prescription. Thresholds
    /// follow existing high-load (1.3) and stable-lift (-4...2%) bands.
    static func softerWeekSuggestion(ratio: Double, trends: [AnchorLiftTrend],
                                     adherence: BlockAdherenceSummary, deloadActive: Bool) -> String? {
        let measured = trends.compactMap(\.changePercent)
        guard !deloadActive, ratio.isFinite, ratio >= 1.3,
              measured.count >= 2, measured.allSatisfy({ $0 < 2 }),
              adherence.restDaysWithTraining >= 2 else { return nil }
        return "Tiene sentido valorar una semana más suave: coinciden carga elevada, lifts sin progreso claro y entrenamientos en días previstos de recuperación. Es una sugerencia; el calendario no se ha modificado."
    }
}
