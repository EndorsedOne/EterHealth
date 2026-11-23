import Foundation

struct MesocycleReview {
    let title: String
    let detail: String
    let lifts: [String]
}

enum MesocycleReviewEngine {
    /// Stable observed anchor, not maintenanceBlock's moving start date.
    /// Review is informational: no calendar-only fatigue or automatic deload.
    static func review(anchor: Date?, now: Date, exercises: [ExerciseStrengthProgress],
                       deloadActive: Bool, calendar: Calendar = .current) -> MesocycleReview? {
        guard let anchor, anchor <= now,
              let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor),
                                                    to: calendar.startOfDay(for: now)).day,
              elapsed >= 28 else { return nil }
        let completedBlocks = elapsed / 28
        let end = calendar.date(byAdding: .day, value: completedBlocks * 28, to: calendar.startOfDay(for: anchor)) ?? now
        let middle = calendar.date(byAdding: .day, value: -14, to: end) ?? end
        let start = calendar.date(byAdding: .day, value: -28, to: end) ?? end
        let lifts = exercises.compactMap { exercise -> String? in
            let early = exercise.points.filter { $0.date >= start && $0.date < middle }
            let late = exercise.points.filter { $0.date >= middle && $0.date < end }
            guard early.count >= 2, late.count >= 2,
                  let first = early.map(\.estimatedOneRM).max(), first > 0,
                  let last = late.map(\.estimatedOneRM).max(), last.isFinite else { return nil }
            let change = (last / first - 1) * 100
            return "\(exercise.name): 1RM estimado \(change.formatted(.number.precision(.fractionLength(0...1))))% entre mitades del bloque."
        }
        return MesocycleReview(title: "Revisión del bloque \(completedBlocks) · 4 semanas",
            detail: deloadActive
                ? "Descarga activa por carga/recuperación: el plan ya reduce la dosis. No se añade otra reducción por calendario."
                : "No se impone descarga por calendario. Revisa recuperación y evolución antes de cambiar la dosis; una bajada aislada no demuestra fatiga.",
            lifts: lifts)
    }
}
