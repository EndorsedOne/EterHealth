import Foundation

struct PersonalMetricBaseline {
    let name: String
    let current: Double?
    let expected: Double?
    let lowerNormal: Double?
    let upperNormal: Double?
    let deviation: Double?
    let samples: Int
    let confidence: Int
    let context: String
    let measuredAt: Date?
}

struct PersonalBaselineProfile {
    let hrv: PersonalMetricBaseline
    let restingHeartRate: PersonalMetricBaseline
    let sleep: PersonalMetricBaseline
    let wristTemperature: PersonalMetricBaseline
    // Wasn't part of this profile at all before — meaning PhysiologicalAlertEngine's
    // illness/overreaching detector never saw it, despite an elevated overnight
    // respiratory rate being one of the more validated early-warning signals in
    // wearable recovery science (it's the flagship signal Oura/Whoop lead with).
    let respiratoryRate: PersonalMetricBaseline
    let muscleRecoveryHours: [String: Double]

    var confidence: Int {
        Int((Double(hrv.confidence + restingHeartRate.confidence + sleep.confidence) / 3).rounded())
    }
}

@MainActor
enum PersonalBaselineEngine {
    static func profile(health: HealthStore, imports: ImportStore, now: Date = Date()) -> PersonalBaselineProfile {
        PersonalBaselineProfile(
            hrv: metric(name: "HRV", points: health.hrvHistory, now: now, favorableHigh: true),
            restingHeartRate: metric(name: "Pulso en reposo", points: health.restingHeartRateHistory, now: now, favorableHigh: false),
            sleep: metric(name: "Sueño", points: health.sleepHistory, now: now, favorableHigh: true),
            // A rise is potentially adverse; a fall is not used as evidence of improved readiness.
            wristTemperature: metric(name: "Temperatura de muñeca", points: health.wristTemperatureHistory, now: now, favorableHigh: false),
            respiratoryRate: metric(name: "Frecuencia respiratoria", points: health.respiratoryRateHistory, now: now, favorableHigh: false),
            muscleRecoveryHours: learnedRecovery(imports: imports)
        )
    }

    private static func metric(name: String, points: [TrendPoint], now: Date, favorableHigh: Bool) -> PersonalMetricBaseline {
        let calendar = Calendar.current
        let current = points.last?.value
        let historical = Array(points.dropLast().suffix(84))
        let weekday = calendar.component(.weekday, from: now)
        let sameWeekday = historical.filter { calendar.component(.weekday, from: $0.date) == weekday }
        // The recent rolling baseline is primary. A mature weekday pattern only
        // nudges it slightly; Thursday is not treated as a physiological category.
        let reference = Array(historical.suffix(56))
        let values = reference.map(\.value)
        let rollingCenter = median(values)
        let weekdayCenter = sameWeekday.count >= 6 ? median(sameWeekday.map(\.value)) : nil
        let center = rollingCenter.map { rolling in weekdayCenter.map { rolling * 0.75 + $0 * 0.25 } ?? rolling }
        let deviations = center.map { c in values.map { abs($0 - c) } } ?? []
        let mad = median(deviations)
        let robustSigma = max((mad ?? 0) * 1.4826, (center ?? 1) * 0.035)
        let rawZ = current.flatMap { value in center.map { (value - $0) / robustSigma } }
        let favorableZ = rawZ.map { favorableHigh ? $0 : -$0 }
        let confidence = min(100, Int((Double(values.count) / 28 * 100).rounded()))
        let context = weekdayCenter == nil
            ? "Referencia móvil · \(values.count) días válidos recientes"
            : "Referencia móvil de 6–12 semanas · ajuste semanal ligero"
        return PersonalMetricBaseline(
            name: name, current: current, expected: center,
            lowerNormal: center.map { $0 - 1.5 * robustSigma },
            upperNormal: center.map { $0 + 1.5 * robustSigma },
            deviation: favorableZ, samples: values.count, confidence: confidence, context: context,
            measuredAt: points.last?.date
        )
    }

    private static func learnedRecovery(imports: ImportStore) -> [String: Double] {
        let muscles = ["Cuádriceps", "Glúteos", "Isquios", "Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Core", "Gemelos"]
        let sorted = imports.workouts.sorted { $0.start < $1.start }
        var observations: [String: [(hours: Double, ratio: Double)]] = [:]
        var previousPerformance: [String: (date: Date, value: Double)] = [:]
        for workout in sorted {
            for exercise in workout.exercises {
                guard let best = estimatedOneRepMax(exercise), best > 0 else { continue }
                for muscle in MuscleMap.groups(for: exercise.name) where muscles.contains(muscle) {
                    if let previous = previousPerformance[exercise.name], previous.value > 0 {
                        let hours = workout.start.timeIntervalSince(previous.date) / 3600
                        if hours > 4 && hours < 240 { observations[muscle, default: []].append((hours, best / previous.value)) }
                    }
                    previousPerformance[exercise.name] = (workout.start, best)
                }
            }
        }
        var result: [String: Double] = [:]
        for muscle in muscles {
            let items = observations[muscle] ?? []
            guard items.count >= 5 else { continue }
            let successful = items.filter { $0.ratio >= 0.98 }.map(\.hours).sorted()
            guard !successful.isEmpty else { continue }
            // Conservative lower quartile of gaps followed by maintained performance.
            let index = min(successful.count - 1, max(0, successful.count / 4))
            result[muscle] = min(96, max(24, successful[index]))
        }
        return result
    }

    private static func estimatedOneRepMax(_ exercise: ImportedExercise) -> Double? {
        let sets = exercise.setDetails ?? []
        let estimates = sets.filter { $0.weight > 0 && $0.reps > 0 && $0.reps <= 15 }
            .map { $0.weight * (1 + Double($0.reps) / 30) }
        return estimates.max()
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

}
