import Foundation

/// A daily, one-directional export of the Apple Salud data éter already reads
/// into HealthStore for its own UI — added to the automatic daily backup so
/// the web dashboard (and anything else reading that backup) gets it every
/// day, instead of depending on a one-time manual Apple Health XML export
/// that never refreshes. Purely additive: nothing here is restored back into
/// HealthKit (HealthKit itself is always the source of truth on-device).
///
/// Deliberately excludes anything HealthStore itself never reads: no GPS
/// workout routes, no ECG voltage waveform — only the ECG classification and
/// date HealthStore.loadECGHistory already reads (see `ecg` below), never the
/// per-sample voltage signal.
struct HealthExportSnapshot: Codable {
    let capturedAt: Date
    let vo2Max: [HealthTrendExport]
    let hrv: [HealthTrendExport]
    let restingHeartRate: [HealthTrendExport]
    let sleepHours: [HealthTrendExport]
    let steps: [HealthTrendExport]
    let bodyWeightKg: [HealthTrendExport]
    let bodyFatPercent: [HealthTrendExport]
    let leanMassKg: [HealthTrendExport]
    let systolicBloodPressure: [HealthTrendExport]
    let diastolicBloodPressure: [HealthTrendExport]
    let respiratoryRate: [HealthTrendExport]
    let oxygenSaturationPercent: [HealthTrendExport]
    let wristTemperatureCelsius: [HealthTrendExport]
    let walkingHeartRate: [HealthTrendExport]
    let heartRateRecovery: [HealthTrendExport]
    let workouts: [HealthWorkoutExport]
    // Classification and date only — see HealthStore.loadECGHistory.
    let ecg: [ECGReadingExport]

    @MainActor
    static func capture(from health: HealthStore) -> HealthExportSnapshot {
        HealthExportSnapshot(
            capturedAt: Date(),
            vo2Max: health.vo2MaxHistory.map(HealthTrendExport.init),
            hrv: health.hrvHistory.map(HealthTrendExport.init),
            restingHeartRate: health.restingHeartRateHistory.map(HealthTrendExport.init),
            sleepHours: health.sleepHistory.map(HealthTrendExport.init),
            steps: health.stepsHistory.map(HealthTrendExport.init),
            bodyWeightKg: health.bodyWeightHistory.map(HealthTrendExport.init),
            bodyFatPercent: health.bodyFatHistory.map(HealthTrendExport.init),
            leanMassKg: health.leanMassHistory.map(HealthTrendExport.init),
            systolicBloodPressure: health.systolicBloodPressureHistory.map(HealthTrendExport.init),
            diastolicBloodPressure: health.diastolicBloodPressureHistory.map(HealthTrendExport.init),
            respiratoryRate: health.respiratoryRateHistory.map(HealthTrendExport.init),
            oxygenSaturationPercent: health.oxygenSaturationHistory.map(HealthTrendExport.init),
            wristTemperatureCelsius: health.wristTemperatureHistory.map(HealthTrendExport.init),
            walkingHeartRate: health.walkingHeartRateHistory.map(HealthTrendExport.init),
            heartRateRecovery: health.heartRateRecoveryHistory.map(HealthTrendExport.init),
            workouts: health.workoutHistory.map(HealthWorkoutExport.init),
            ecg: health.ecgHistory.map(ECGReadingExport.init)
        )
    }
}

struct ECGReadingExport: Codable {
    let date: Date
    let classification: String
    let averageHeartRate: Double?

    init(_ reading: ECGReading) {
        date = reading.date; classification = reading.classification; averageHeartRate = reading.averageHeartRate
    }
}

struct HealthTrendExport: Codable {
    let date: Date
    let value: Double

    init(date: Date, value: Double) { self.date = date; self.value = value }
    init(_ point: TrendPoint) { date = point.date; value = point.value }
}

/// Aggregate-only, same fields HealthWorkout already exposes elsewhere in the
/// app — no route/location data exists on HealthWorkout to begin with.
struct HealthWorkoutExport: Codable {
    // Matches WorkoutReview.workoutID's own format for a HealthKit-sourced
    // workout (see RunningPerformanceEngine.forecast's reviewsByID lookup) —
    // without this, the dashboard could see every run and every review but
    // never which review belongs to which run, and had to guess "effortful"
    // from pace alone instead of using the real reviews at all.
    let reviewID: String
    let date: Date
    let durationMinutes: Double
    let calories: Double?
    let distanceKilometers: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let elevationMeters: Double?
    let activity: String
    let muscleGroups: [String: Double]
    let source: String
    let averagePowerWatts: Double?
    let averageGroundContactMs: Double?
    let averageVerticalOscillationCm: Double?
    let averageStrideLengthM: Double?

    init(_ workout: HealthWorkout) {
        reviewID = "health-\(workout.id.uuidString)"
        date = workout.date; durationMinutes = workout.durationMinutes; calories = workout.calories
        distanceKilometers = workout.distanceKilometers; averageHeartRate = workout.averageHeartRate
        maxHeartRate = workout.maxHeartRate; elevationMeters = workout.elevationMeters; activity = workout.activity
        muscleGroups = workout.muscleGroups; source = workout.source
        averagePowerWatts = workout.averagePowerWatts; averageGroundContactMs = workout.averageGroundContactMs
        averageVerticalOscillationCm = workout.averageVerticalOscillationCm; averageStrideLengthM = workout.averageStrideLengthM
    }
}
