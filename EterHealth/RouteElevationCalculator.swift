import Foundation

// Pulled out of HealthStore's async route query for the same reason
// HeartRateZoneClassifier was: the actual math is pure and testable, the
// HealthKit route-fetching around it isn't. HealthKit's own workout
// metadata only ever carries ASCENT (HKMetadataKeyElevationAscended has
// no descended counterpart) — this is the one elevation figure the app
// has to derive itself from a route rather than just read.
enum RouteElevationCalculator {
    // Sums every consecutive downhill step in a sequence of altitudes,
    // in the order the route was recorded. Barometric altitude on a
    // modern Watch is clean enough that a plain sum of negative deltas
    // is a reasonable read without extra smoothing — a route-derived
    // approximation, not a validated formula, same honesty as
    // TrainingPlanEngine.cardioMuscleLoad's own elevation/intensity
    // factors that consume this.
    nonisolated static func cumulativeDescent(altitudes: [Double]) -> Double {
        guard altitudes.count > 1 else { return 0 }
        var descent = 0.0
        for index in 1..<altitudes.count {
            let delta = altitudes[index - 1] - altitudes[index]
            if delta > 0 { descent += delta }
        }
        return descent
    }
}
