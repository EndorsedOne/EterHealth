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

@MainActor
enum WidgetSnapshotStore {
    static let suiteName = "group.com.angelmartinez.eterhealth"
    private static let key = "eter.widget.snapshot.v1"

    static func update(assessment: TwinAssessment, health: HealthStore, imports: ImportStore,
                       checkIn: DailyCheckIn?, lifestyle: LifestyleFactorStore,
                       travel: TravelEpisode? = nil, now: Date = Date()) {
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -10, to: now) ?? now
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
            restingHeartRateBaseline: baseline.restingHeartRate.expected
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
