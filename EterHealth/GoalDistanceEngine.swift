import Foundation

enum GoalDistanceState: String {
    case achieved = "Objetivo alcanzado"
    case close = "Cerca del objetivo"
    case progressing = "En construcción"
    case missingTarget = "Falta definir la marca"
    case insufficientData = "Aún no estimable"
}

struct GoalDistance: Identifiable {
    var id: UUID { goal.id }
    let goal: TrainingGoal
    let current: String
    let target: String
    let gap: String
    let progress: Double?
    let state: GoalDistanceState
    let confidence: TrustLevel
    let evidence: String
    let daysRemaining: Int?
}

enum GoalDistanceEngine {
    static func evaluate(goals: [TrainingGoal], running: RunningPerformanceSummary,
                         strength: StrengthProgressSummary, importedWorkouts: [ImportedWorkout] = [],
                         healthWorkouts: [HealthWorkout] = [], now: Date = Date()) -> [GoalDistance] {
        goals.map { goal in
            switch goal.kind {
            case .fiveK:
                return runningDistance(goal, forecast: running.fiveK, now: now)
            case .tenK:
                return runningDistance(goal, forecast: running.tenK, now: now)
            case .halfMarathon:
                return runningDistance(goal, forecast: running.halfMarathon, now: now)
            case .marathon:
                return runningDistance(goal, forecast: running.marathon, now: now)
            case .triathlon, .ironman:
                return triathlonDistance(
                    goal, forecast: TriathlonForecastEngine.forecast(
                        distance: goal.resolvedTriathlonDistance ?? .olympic,
                        running: running, workouts: healthWorkouts, courseDetails: goal.courseDetails, now: now
                    ), now: now
                )
            case .benchPress:
                // "bench press" alone also matches "Incline Bench Press
                // (Dumbbell)" and "Bench Press (Dumbbell)" — different
                // lifts with a completely different load capacity than a
                // flat barbell bench, not interchangeable with a "press
                // banca" 1RM goal. Whichever variation was trained more
                // recently/frequently sorts first in matchingExercise's
                // search and silently wins, which is exactly how a real
                // ~105% (flat barbell) 1RM estimate got replaced by a
                // ~67% one from a dumbbell incline variation nobody meant
                // to track against this goal.
                return strengthDistance(goal, progress: matchingExercise(in: strength, terms: ["bench press (barbell)", "press banca"]), now: now)
            case .squat:
                return strengthDistance(goal, progress: matchingExercise(in: strength, terms: ["squat (barbell)", "sentadilla"]), now: now)
            case .deadlift:
                return strengthDistance(goal, progress: matchingExercise(in: strength, terms: ["deadlift (barbell)", "peso muerto"]), now: now)
            case .hyrox:
                return hyroxDistance(
                    goal, forecast: HyroxForecastEngine.forecast(
                        running: running, workouts: importedWorkouts,
                        division: goal.hyroxDivision ?? .open, now: now
                    ), now: now
                )
            case .hypertrophy:
                return unmodelledDistance(goal, reason: "La hipertrofia se sigue por volumen semanal y medidas, no por una sola marca que forecastar.", now: now)
            case .custom:
                return unmodelledDistance(goal, reason: "Este reto necesita una métrica específica para poder calcular una distancia real.", now: now)
            }
        }
    }

    private static func hyroxDistance(_ goal: TrainingGoal, forecast: HyroxForecast?, now: Date) -> GoalDistance {
        let days = daysRemaining(goal, now: now)
        guard let forecast else {
            return GoalDistance(
                goal: goal, current: "Sin forecast", target: goal.displayTarget ?? "Sin marca",
                gap: "Falta una predicción válida de carrera para construir los 8 km del HYROX.",
                progress: nil, state: .insufficientData, confidence: .low,
                evidence: "Las estaciones no bastan sin una carrera con distancia y duración.", daysRemaining: days
            )
        }
        let range = "\(raceTime(forecast.optimisticSeconds))–\(raceTime(forecast.conservativeSeconds))"
        guard let targetMinutes = goal.targetValue, targetMinutes > 0 else {
            return GoalDistance(
                goal: goal, current: range, target: "Sin marca",
                gap: "Ya hay un intervalo prudente; define una marca objetivo para medir la distancia.",
                progress: nil, state: .missingTarget, confidence: forecast.confidence.level,
                evidence: forecast.basis + " " + forecast.bottleneck, daysRemaining: days
            )
        }
        let target = targetMinutes * 60
        let difference = forecast.seconds - target
        let progress = min(1, max(0, target / max(forecast.seconds, 1)))
        let state: GoalDistanceState = difference <= 0 ? .achieved : difference <= target * 0.05 ? .close : .progressing
        let gap = difference <= 0
            ? "Centro del forecast \(shortDuration(abs(difference))) por delante"
            : "Centro del forecast a \(shortDuration(difference))"
        return GoalDistance(
            goal: goal, current: range, target: raceTime(target), gap: gap,
            progress: progress, state: state, confidence: forecast.confidence.level,
            evidence: forecast.basis + " " + forecast.bottleneck, daysRemaining: days
        )
    }

    private static func triathlonDistance(_ goal: TrainingGoal, forecast: TriathlonForecast?, now: Date) -> GoalDistance {
        let days = daysRemaining(goal, now: now)
        guard let forecast else {
            return GoalDistance(
                goal: goal, current: "Sin forecast", target: goal.displayTarget ?? "Sin marca",
                gap: "Falta una carrera con distancia y duración para construir la pierna de carrera.",
                progress: nil, state: .insufficientData, confidence: .low,
                evidence: "Natación y ciclismo no bastan sin una carrera de referencia.", daysRemaining: days
            )
        }
        let range = "\(raceTime(forecast.optimisticSeconds))–\(raceTime(forecast.conservativeSeconds))"
        guard let targetMinutes = goal.targetValue, targetMinutes > 0 else {
            return GoalDistance(
                goal: goal, current: range, target: "Sin marca",
                gap: "Ya hay un intervalo prudente; define una marca objetivo para medir la distancia.",
                progress: nil, state: .missingTarget, confidence: forecast.confidence.level,
                evidence: forecast.basis + " " + forecast.bottleneck, daysRemaining: days
            )
        }
        let target = targetMinutes * 60
        let difference = forecast.seconds - target
        let progress = min(1, max(0, target / max(forecast.seconds, 1)))
        let state: GoalDistanceState = difference <= 0 ? .achieved : difference <= target * 0.05 ? .close : .progressing
        let gap = difference <= 0
            ? "Centro del forecast \(shortDuration(abs(difference))) por delante"
            : "Centro del forecast a \(shortDuration(difference))"
        return GoalDistance(
            goal: goal, current: range, target: raceTime(target), gap: gap,
            progress: progress, state: state, confidence: forecast.confidence.level,
            evidence: forecast.basis + " " + forecast.bottleneck, daysRemaining: days
        )
    }

    nonisolated static func runningGap(forecastSeconds: Double, targetSeconds: Double) -> Double {
        forecastSeconds - targetSeconds
    }

    nonisolated static func strengthGap(currentKilograms: Double, targetKilograms: Double) -> Double {
        targetKilograms - currentKilograms
    }

    private static func runningDistance(_ goal: TrainingGoal, forecast: RaceForecast?, now: Date) -> GoalDistance {
        let days = daysRemaining(goal, now: now)
        guard let forecast else {
            return GoalDistance(goal: goal, current: "Sin forecast", target: goal.displayTarget ?? "Sin marca",
                                gap: "Necesitamos una carrera válida con distancia y duración.", progress: nil,
                                state: .insufficientData, confidence: .low, evidence: "0 predicciones válidas", daysRemaining: days)
        }
        guard let targetMinutes = goal.targetValue, targetMinutes > 0 else {
            return GoalDistance(goal: goal, current: raceTime(forecast.seconds), target: "Sin marca",
                                gap: "Hay forecast, pero falta indicar el tiempo objetivo.", progress: nil,
                                state: .missingTarget, confidence: forecast.confidence, evidence: forecast.basis, daysRemaining: days)
        }
        let target = targetMinutes * 60
        let difference = runningGap(forecastSeconds: forecast.seconds, targetSeconds: target)
        let progress = min(1, max(0, target / max(forecast.seconds, 1)))
        let state: GoalDistanceState = difference <= 0 ? .achieved : difference <= target * 0.03 ? .close : .progressing
        let gap = difference <= 0
            ? "Forecast \(shortDuration(abs(difference))) por delante de la marca"
            : "Faltan \(shortDuration(difference))"
        return GoalDistance(goal: goal, current: raceTime(forecast.seconds), target: raceTime(target), gap: gap,
                            progress: progress, state: state, confidence: forecast.confidence,
                            evidence: forecast.basis, daysRemaining: days)
    }

    private static func strengthDistance(_ goal: TrainingGoal, progress exercise: ExerciseStrengthProgress?, now: Date) -> GoalDistance {
        let days = daysRemaining(goal, now: now)
        guard let target = goal.targetValue, target > 0 else {
            return GoalDistance(goal: goal, current: exercise?.latestOneRM.map(kilograms) ?? "Sin 1RM",
                                target: "Sin marca", gap: "Define una marca objetivo para medir la distancia.", progress: nil,
                                state: .missingTarget, confidence: .low, evidence: evidence(exercise), daysRemaining: days)
        }
        guard let exercise, let current = exercise.latestOneRM else {
            return GoalDistance(goal: goal, current: "Sin 1RM estimable", target: kilograms(target),
                                gap: "Falta una serie efectiva de 1–12 repeticiones.", progress: nil,
                                state: .insufficientData, confidence: .low, evidence: evidence(exercise), daysRemaining: days)
        }
        let difference = strengthGap(currentKilograms: current, targetKilograms: target)
        let progress = min(1, max(0, current / target))
        let state: GoalDistanceState = difference <= 0 ? .achieved : difference <= target * 0.05 ? .close : .progressing
        let gap = difference <= 0 ? "1RM estimado \(kilograms(abs(difference))) por encima" : "Faltan \(kilograms(difference))"
        let confidence = ConfidenceEngine.samples(exercise.sessions, medium: 3, high: 6, label: "sesiones comparables").level
        return GoalDistance(goal: goal, current: kilograms(current), target: kilograms(target), gap: gap,
                            progress: progress, state: state, confidence: confidence,
                            evidence: "\(exercise.sessions) sesiones comparables · 1RM estimado, no test máximo", daysRemaining: days)
    }

    private static func unmodelledDistance(_ goal: TrainingGoal, reason: String, now: Date) -> GoalDistance {
        GoalDistance(goal: goal, current: "Sin estimación", target: goal.displayTarget ?? "Sin marca",
                     gap: reason, progress: nil, state: .insufficientData, confidence: .low,
                     evidence: "Calendario disponible; rendimiento específico insuficiente", daysRemaining: daysRemaining(goal, now: now))
    }

    private static func matchingExercise(in summary: StrengthProgressSummary, terms: [String]) -> ExerciseStrengthProgress? {
        summary.exercises.first { exercise in
            let name = exercise.name.lowercased()
            return terms.contains { name.contains($0) }
        }
    }

    private static func daysRemaining(_ goal: TrainingGoal, now: Date) -> Int? {
        guard let date = goal.date else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: date)).day ?? 0)
    }

    private static func evidence(_ progress: ExerciseStrengthProgress?) -> String {
        guard let progress else { return "Ejercicio no localizado en el historial importado" }
        return "\(progress.sessions) sesiones · aún sin serie válida para estimar 1RM"
    }

    private static func kilograms(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...1)))) kg" }
    private static func raceTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
    private static func shortDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total) s"
    }
}
