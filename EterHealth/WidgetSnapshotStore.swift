import Foundation
import WidgetKit

struct EterWidgetSnapshot: Codable, Sendable {
    let updatedAt: Date
    let readiness: Int
    let state: String
    let recommendation: String
    let reason: String
    let readinessConfidence: String?
    let readinessConfidenceScore: Int?
    let readinessConfidenceReason: String?
    let hrv: Int
    let restingHeartRate: Int
    let sleepHours: Double
    let energy: Int
    let energyCurve: [Double]
    let currentHour: Double
    let sleepStartHour: Double?
    let sleepEndHour: Double?
    let energyEvents: [EterWidgetEnergyEvent]
    let energyBasis: String
    let energyConfidence: String?
    let energyConfidenceScore: Int?
    let energyConfidenceReason: String?
    let loadRatio: Double
    let loadState: String
    // Opcional, no `var` con default: el decoder sintetizado de Swift NO usa
    // los valores por defecto de las propiedades, así que un campo nuevo no
    // opcional haría fallar el decode de los snapshots ya guardados y el
    // widget se quedaría en blanco hasta que la app reescribiera uno.
    var loadChannel: String?
    let loadConfidence: String?
    let loadConfidenceScore: Int?
    let loadConfidenceReason: String?
    let dailyLoads: [Double]
    let runningShare: Int
    let strengthShare: Int
}

struct EterWidgetEnergyEvent: Codable, Sendable {
    let startHour: Double
    let endHour: Double
    let symbol: String
    let drain: Double
}

@MainActor
enum WidgetSnapshotStore {
    static let suiteName = "group.com.angelmartinez.eterhealth"
    private static let key = "eter.widget.snapshot.v1"

    static func update(assessment: TwinAssessment, health: HealthStore, imports: ImportStore,
                       checkIn: DailyCheckIn?, lifestyle: LifestyleFactorStore, now: Date = Date()) {
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -10, to: now) ?? now
        let strengthSessions = imports.workouts.filter { $0.start >= start }.count
        let runningSessions = health.recentWorkouts.filter {
            $0.date >= start && $0.activity == "Carrera" && !imports.isHealthKitMirror($0)
        }.count
        let sessionTotal = max(1, strengthSessions + runningSessions)
        let currentHour = hour(of: now, on: now)
        let sleepStart = health.sleepStages.startDate.map { max(0, hour(of: $0, on: now)) }
        let sleepEnd = health.sleepStages.endDate.map { min(currentHour, hour(of: $0, on: now)) }
        let events = energyEvents(health: health, imports: imports, now: now)
        let baseline = PersonalBaselineEngine.profile(health: health, imports: imports, now: now)
        let model = energyModel(
            assessment: assessment, health: health, baseline: baseline,
            checkIn: checkIn, lifestyle: lifestyle.recent(before: now, hours: 30),
            now: now, currentHour: currentHour, sleepStartHour: sleepStart,
            sleepEndHour: sleepEnd, events: events
        )
        let confidence = ConfidenceEngine.energy(
            baselineConfidence: baseline.confidence,
            hasSleep: health.snapshot.sleepHours > 0,
            hasSleepStages: health.sleepStages.deepHours + health.sleepStages.remHours > 0,
            hasHRV: health.snapshot.hrv > 0,
            hasRestingHeartRate: health.snapshot.restingHeartRate > 0,
            hasCheckIn: checkIn != nil,
            activityEvents: events.count,
            updatedAt: health.lastUpdated,
            now: now
        )
        let readinessConfidence = ConfidenceEngine.readiness(
            baselineConfidence: baseline.confidence, signalCount: assessment.signals.count,
            hasCheckIn: checkIn != nil, updatedAt: health.lastUpdated, now: now
        )
        let loadConfidence = ConfidenceEngine.trainingLoad(
            observedDays: performance.observedLoadDays, sessions: performance.sessions
        )
        let snapshot = EterWidgetSnapshot(
            updatedAt: now, readiness: assessment.score, state: assessment.state,
            recommendation: assessment.recommendation, reason: assessment.explanation,
            readinessConfidence: readinessConfidence.level.rawValue,
            readinessConfidenceScore: readinessConfidence.score,
            readinessConfidenceReason: readinessConfidence.reason,
            hrv: health.snapshot.hrv, restingHeartRate: health.snapshot.restingHeartRate,
            sleepHours: health.snapshot.sleepHours, energy: model.energy,
            energyCurve: model.curve, currentHour: currentHour,
            sleepStartHour: sleepStart, sleepEndHour: sleepEnd, energyEvents: events,
            energyBasis: model.basis,
            energyConfidence: confidence.level.rawValue,
            energyConfidenceScore: confidence.score,
            energyConfidenceReason: confidence.reason,
            loadRatio: performance.loadRatio, loadState: performance.loadState,
            loadChannel: performance.loadChannel,
            loadConfidence: loadConfidence.level.rawValue,
            loadConfidenceScore: loadConfidence.score,
            loadConfidenceReason: loadConfidence.reason,
            dailyLoads: performance.daily.map(\.load),
            runningShare: Int((Double(runningSessions) / Double(sessionTotal) * 100).rounded()),
            strengthShare: Int((Double(strengthSessions) / Double(sessionTotal) * 100).rounded())
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private struct EnergyModelResult {
        let energy: Int
        let curve: [Double]
        let basis: String
    }

    private static func energyModel(
        assessment: TwinAssessment, health: HealthStore, baseline: PersonalBaselineProfile,
        checkIn: DailyCheckIn?, lifestyle: [LifestyleEvent], now: Date,
        currentHour: Double, sleepStartHour: Double?, sleepEndHour: Double?,
        events: [EterWidgetEnergyEvent]
    ) -> EnergyModelResult {
        let sleepNeed = max(6, baseline.sleep.expected ?? 7.5)
        let durationFactor = clamp(health.snapshot.sleepHours / sleepNeed, 0.45, 1.15)
        let restorative = health.sleepStages.deepHours + health.sleepStages.remHours
        let restorativeShare = restorative / max(health.snapshot.sleepHours, 0.1)
        let stageFactor = health.snapshot.sleepHours > 0 && restorative > 0
            ? clamp(0.82 + restorativeShare * 0.65, 0.78, 1.10) : 0.94
        let hrvAdjustment = clamp((baseline.hrv.deviation ?? 0) * 4, -8, 8)
        let restingAdjustment = clamp((baseline.restingHeartRate.deviation ?? 0) * 3, -6, 6)
        let subjectiveSleep = Double((checkIn?.sleepFeeling ?? 3) - 3) * 3
        let overnightAlcohol = lifestyle.filter {
            $0.alcoholDrinks > 0 && now.timeIntervalSince($0.date) <= 18 * 3600
        }.reduce(0.0) { $0 + Double($1.alcoholDrinks) * 2.5 }
        let illnessPenalty = checkIn?.illness == true ? 10.0 : 0
        // PR15: aquí había una SEGUNDA penalización de viaje,
        // `Δh × 0.8` sobre la diferencia horaria declarada, sin decaer y sin
        // dirección. Con 9 husos seguía restando 7.2 puntos a la curva de
        // energía del widget el día 30 del viaje, mientras la app —que sí
        // decaía— ya no restaba nada: dos motores diciendo cosas distintas
        // sobre el mismo viaje, exactamente lo que este PR existe para
        // eliminar. El coste del viaje entra ahora por `assessment.score`,
        // que ya lo lleva dentro vía TravelImpact, así que el widget lo hereda
        // sin tener su propia opinión.
        let recharge = clamp(
            48 * durationFactor * stageFactor + hrvAdjustment + restingAdjustment +
            subjectiveSleep - overnightAlcohol - illnessPenalty,
            12, 72
        )
        // Readiness acts as a bounded physiological anchor; the recharge calculation
        // determines how the night reached that morning reserve rather than replacing it.
        let wakeEnergy = clamp(0.58 * (20 + recharge) + 0.42 * Double(assessment.score), 22, 98)
        let midnightEnergy = max(5, wakeEnergy - recharge)

        let endOfSleep = min(currentHour, max(0.5, sleepEndHour ?? min(8, currentHour)))
        let startOfSleep = min(endOfSleep, max(0, sleepStartHour ?? 0))
        let awakeHours = max(0, currentHour - endOfSleep)
        let workoutCalories = health.recentWorkouts.filter {
            Calendar.current.isDate($0.date, inSameDayAs: now)
        }.compactMap(\.calories).reduce(0, +)
        let nonWorkoutEnergy = max(0, Double(health.snapshot.activeEnergy) - workoutCalories)
        var backgroundDrain = awakeHours * 0.72 + nonWorkoutEnergy / 42 + Double(health.snapshot.steps) / 3_500
        if let checkIn {
            backgroundDrain += Double(max(0, checkIn.stress - 3)) * 2.2
            backgroundDrain += Double(max(0, checkIn.fatigue - 3)) * 2.4
            backgroundDrain += Double(max(0, 3 - checkIn.energy)) * 2.0
        }
        for event in lifestyle where Calendar.current.isDate(event.date, inSameDayAs: now) {
            if event.hydration == .low { backgroundDrain += 4 }
            if event.saunaMinutes > 0 { backgroundDrain += min(4, Double(event.saunaMinutes) / 10) }
            if event.digestiveSymptoms.count > 0 { backgroundDrain += 2 }
        }
        backgroundDrain = clamp(backgroundDrain, 0, 42)

        let pointCount = max(2, Int((currentHour * 2).rounded(.up)) + 1)
        let curve = (0..<pointCount).map { index -> Double in
            let representedHour = min(currentHour, Double(index) / 2)
            if representedHour <= startOfSleep { return midnightEnergy }
            if representedHour <= endOfSleep {
                let progress = (representedHour - startOfSleep) / max(0.25, endOfSleep - startOfSleep)
                return min(100, midnightEnergy + recharge * progress)
            }
            let awakeProgress = (representedHour - endOfSleep) / max(0.5, currentHour - endOfSleep)
            let exerciseDrain = events.reduce(0.0) { total, event in
                let duration = max(0.05, event.endHour - event.startHour)
                let completed = clamp((representedHour - event.startHour) / duration, 0, 1)
                return total + event.drain * completed
            }
            return max(5, wakeEnergy - backgroundDrain * awakeProgress - exerciseDrain)
        }
        let exerciseDrain = events.reduce(0) { $0 + $1.drain }
        let basis = "Noche +\(Int(recharge.rounded())) · día −\(Int(backgroundDrain.rounded())) · ejercicio −\(Int(exerciseDrain.rounded()))"
        return EnergyModelResult(
            energy: Int((curve.last ?? wakeEnergy).rounded()),
            curve: curve,
            basis: basis
        )
    }

    private static func energyEvents(health: HealthStore, imports: ImportStore, now: Date) -> [EterWidgetEnergyEvent] {
        let calendar = Calendar.current
        var result = health.recentWorkouts.filter {
            calendar.isDate($0.date, inSameDayAs: now) && $0.date <= now
        }.map { workout in
            let start = hour(of: workout.date, on: now)
            let end = min(hour(of: now, on: now), start + workout.durationMinutes / 60)
            let intensity = workout.averageHeartRate.map { clamp(($0 - 85) / 100, 0.2, 1) } ?? 0.45
            let drain = workout.calories.map { $0 / 24 } ?? workout.durationMinutes * (0.10 + intensity * 0.13)
            return EterWidgetEnergyEvent(
                startHour: max(0, start), endHour: max(start + 0.05, end),
                symbol: workoutSymbol(workout.activity), drain: clamp(drain, 2, 45)
            )
        }
        for workout in imports.workouts where calendar.isDate(workout.start, inSameDayAs: now) && workout.start <= now {
            let mirrored = health.recentWorkouts.contains { abs($0.date.timeIntervalSince(workout.start)) < 5 * 60 }
            guard !mirrored else { continue }
            let start = hour(of: workout.start, on: now)
            let end = min(hour(of: now, on: now), hour(of: workout.end, on: now))
            let duration = max(1, workout.end.timeIntervalSince(workout.start) / 60)
            result.append(EterWidgetEnergyEvent(
                startHour: max(0, start), endHour: max(start + 0.05, end),
                symbol: "dumbbell.fill", drain: clamp(duration * 0.18, 2, 28)
            ))
        }
        return result.sorted { $0.startHour < $1.startHour }
    }

    private static func workoutSymbol(_ activity: String) -> String {
        switch activity {
        case "Carrera": return "figure.run"
        case "Ciclismo": return "figure.outdoor.cycle"
        case "Fuerza", "Fuerza funcional": return "dumbbell.fill"
        case "Natación": return "figure.pool.swim"
        default: return "figure.mixed.cardio"
        }
    }

    private static func hour(of date: Date, on day: Date) -> Double {
        let start = Calendar.current.startOfDay(for: day)
        return date.timeIntervalSince(start) / 3600
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
