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
    // Reto 1 · gráfica de tendencias del día. Opcionales, no `var` con default,
    // por el mismo motivo que loadChannel arriba: el decoder sintetizado de
    // Swift no aplica defaults, así que un campo nuevo NO opcional dejaría el
    // widget en blanco con los snapshots ya guardados hasta que la app
    // reescribiera uno. `hrvPoints` son las muestras reales de HRV de hoy;
    // `inputMarkers` los eventos de estilo de vida (sauna, frío, café, alcohol,
    // suplementos) con su hora, para superponerlos sobre la curva modelada.
    var hrvPoints: [EterWidgetHRVPoint]?
    var inputMarkers: [EterWidgetInputMarker]?
    var hrvBaseline: Double?
    var restingHeartRateBaseline: Double?
    // Optional to keep snapshots written by older app versions decodable.
    var caffeineCurve: [EterWidgetCaffeinePoint]?
    var caffeineNowMg: Double?
    var caffeineBedtimeMg: Double?
    var caffeineBedtimeHour: Double?
    var heartRatePoints: [EterWidgetHeartRatePoint]?
    var restorativeWindows: [EterWidgetTimeWindow]?
    var strainWindows: [EterWidgetTimeWindow]?
    // Compact muscle matrix. Optional so snapshots written by older builds
    // remain decodable until the app produces the first refreshed snapshot.
    var muscleCurrent: [Double]?
    var musclePrevious: [Double]?
    var muscleCardio: [Double]?
    var muscleTargets: [Double]?
}

struct EterWidgetEnergyEvent: Codable, Sendable {
    let startHour: Double
    let endHour: Double
    let symbol: String
    let drain: Double
}

struct EterWidgetHRVPoint: Codable, Sendable {
    let hour: Double
    let value: Double
}

struct EterWidgetInputMarker: Codable, Sendable {
    let hour: Double
    let symbol: String
    /// "sauna" | "cold" | "coffee" | "alcohol" | "supplement" — decide el tinte.
    let kind: String
    let label: String
}

struct EterWidgetCaffeinePoint: Codable, Sendable {
    let hour: Double
    let remainingMg: Double
}

struct EterWidgetHeartRatePoint: Codable, Sendable {
    let hour: Double
    let bpm: Double
    let segment: Int
}

struct EterWidgetTimeWindow: Codable, Sendable {
    let startHour: Double
    let endHour: Double
}

/// Canal pequeño y barato para las señales que cambian durante el día. No debe
/// esperar a que se reconstruyan plan, carga y distribución muscular para que
/// el widget deje de mostrar una medición fisiológica anterior.
private struct EterWidgetVitalsSnapshot: Codable {
    let updatedAt: Date
    let hrv: Int
    let restingHeartRate: Int
    let heartRatePoints: [EterWidgetHeartRatePoint]
}

@MainActor
enum WidgetSnapshotStore {
    static let suiteName = "group.com.angelmartinez.eterhealth"
    private static let key = "eter.widget.snapshot.v1"
    private static let vitalsKey = "eter.widget.vitals.v1"

    static func updateVitals(health: HealthStore, now: Date = Date()) {
        let currentHour = EnergyTimelineEngine.hour(of: now, on: now)
        updateVitals(
            hrv: health.snapshot.hrv,
            restingHeartRate: health.snapshot.restingHeartRate,
            heartRatePoints: EnergyTimelineEngine.heartRatePoints(
                samples: health.todayHeartRateSamples, day: now, through: currentHour
            ).map { EterWidgetHeartRatePoint(hour: $0.hour, bpm: $0.bpm, segment: $0.segment) },
            now: now
        )
    }

    static func updateVitals(hrv: Int?, restingHeartRate: Int?,
                             heartRatePoints: [EterWidgetHeartRatePoint],
                             now: Date = Date()) {
        let defaults = UserDefaults(suiteName: suiteName)
        let previous = defaults?.data(forKey: vitalsKey)
            .flatMap { try? JSONDecoder().decode(EterWidgetVitalsSnapshot.self, from: $0) }
        let sameDay = previous.map { Calendar.current.isDate($0.updatedAt, inSameDayAs: now) } ?? false
        let resolvedHRV = (hrv ?? 0) > 0 ? hrv! : (sameDay ? previous?.hrv ?? 0 : 0)
        let resolvedResting = (restingHeartRate ?? 0) > 0
            ? restingHeartRate! : (previous?.restingHeartRate ?? 0)
        let resolvedPulse = !heartRatePoints.isEmpty
            ? heartRatePoints : (sameDay ? previous?.heartRatePoints ?? [] : [])
        guard resolvedHRV > 0 || resolvedResting > 0 || !resolvedPulse.isEmpty else { return }
        let vitals = EterWidgetVitalsSnapshot(
            updatedAt: now, hrv: resolvedHRV,
            restingHeartRate: resolvedResting, heartRatePoints: resolvedPulse
        )
        guard let data = try? JSONEncoder().encode(vitals) else { return }
        defaults?.set(data, forKey: vitalsKey)
        defaults?.synchronize()
        WidgetCenter.shared.reloadTimelines(ofKind: "EterDecisionWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "EterEnergyWidget")
    }

    static func update(assessment: TwinAssessment, health: HealthStore, imports: ImportStore,
                       checkIn: DailyCheckIn?, lifestyle: LifestyleFactorStore,
                       travel: TravelEpisode? = nil, now: Date = Date()) {
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -14, to: now) ?? start
        let muscleAxes = ["Espalda", "Pecho", "Core", "Hombros", "Brazos", "Piernas"]
        let muscleCurrent = MuscleVolumeSection.combinedMuscleDistribution(
            imports: imports, health: health, from: start, to: now
        )
        let musclePrevious = MuscleVolumeSection.combinedMuscleDistribution(
            imports: imports, health: health, from: previousStart, to: start
        )
        let muscleCardio = MuscleVolumeSection.cardioMuscleStimulus(
            imports: imports, health: health, from: start, to: now
        )
        let muscleTargets = MuscleVolumeSection.cycleTargets(workouts: imports.workouts, now: now)
        let strengthSessions = imports.workouts.filter { $0.start >= start }.count
        let runningSessions = health.recentWorkouts.filter {
            $0.date >= start && $0.activity == "Carrera" && !imports.isHealthKitMirror($0)
        }.count
        let sessionTotal = max(1, strengthSessions + runningSessions)
        let lifestyleWindow = lifestyle.recent(before: now, hours: 30)
        let currentHour = EnergyTimelineEngine.hour(of: now, on: now)
        let sleepStart = health.sleepStages.startDate.map { max(0, EnergyTimelineEngine.hour(of: $0, on: now)) }
        let sleepEnd = health.sleepStages.endDate.map { min(currentHour, EnergyTimelineEngine.hour(of: $0, on: now)) }
        let events = EnergyTimelineEngine.energyEvents(health: health, imports: imports, now: now)
        let baseline = PersonalBaselineEngine.profile(health: health, imports: imports, now: now)
        let model = EnergyTimelineEngine.energyModel(
            assessment: assessment, health: health, baseline: baseline,
            checkIn: checkIn, lifestyle: lifestyleWindow,
            now: now, currentHour: currentHour, sleepStartHour: sleepStart,
            sleepEndHour: sleepEnd, events: events
        )
        let inputMarkers = EnergyTimelineEngine.inputMarkers(
            from: lifestyleWindow, checkIn: checkIn, travel: travel,
            sleepHours: health.snapshot.sleepHours, sleepEndHour: sleepEnd, now: now
        )
        let caffeine = EnergyTimelineEngine.caffeineTimeline(
            lifestyle: lifestyleWindow, sleepSchedule: health.sleepScheduleHistory,
            now: now, currentHour: currentHour
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
            strengthShare: Int((Double(strengthSessions) / Double(sessionTotal) * 100).rounded()),
            hrvPoints: nil, inputMarkers: inputMarkers,
            hrvBaseline: baseline.hrv.expected,
            restingHeartRateBaseline: baseline.restingHeartRate.expected,
            caffeineCurve: caffeine.points, caffeineNowMg: caffeine.currentMg,
            caffeineBedtimeMg: caffeine.bedtimeMg, caffeineBedtimeHour: caffeine.bedtimeHour,
            heartRatePoints: EnergyTimelineEngine.heartRatePoints(
                samples: health.todayHeartRateSamples, day: now, through: currentHour
            ).map { EterWidgetHeartRatePoint(hour: $0.hour, bpm: $0.bpm, segment: $0.segment) },
            restorativeWindows: model.restWindows.map {
                EterWidgetTimeWindow(startHour: $0.startHour, endHour: $0.endHour)
            },
            strainWindows: model.autonomicStrainWindows.map {
                EterWidgetTimeWindow(startHour: $0.startHour, endHour: $0.endHour)
            },
            muscleCurrent: muscleAxes.map { muscleCurrent[$0] ?? 0 },
            musclePrevious: muscleAxes.map { musclePrevious[$0] ?? 0 },
            muscleCardio: muscleAxes.map { muscleCardio[$0] ?? 0 },
            muscleTargets: muscleAxes.map { muscleTargets[$0] ?? 1 }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // El widget vive en otro proceso. Si pedimos la recarga justo después
        // de `set`, WidgetKit puede abrir su proceso antes de que cfprefsd haya
        // propagado el nuevo valor del App Group y construir otra timeline con
        // la instantánea anterior (se veía, por ejemplo, HRV 30 en el widget y
        // 55 en la app). Forzamos primero la entrega al contenedor compartido y
        // recargamos explícitamente cada kind que consume esta instantánea.
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(data, forKey: key)
        defaults?.synchronize()
        for kind in ["EterDecisionWidget", "EterEnergyWidget", "EterLoadWidget", "EterMuscleMatrixWidget"] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
