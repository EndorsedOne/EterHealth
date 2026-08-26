import Foundation

// Pulled out of HealthStore's async, per-second zone classifier
// (classifyHeartRateZones) so the exact same real thresholds — manual
// boundaries from an actual lactate test when set, else Karvonen %HRR
// against a measured/configured/age-estimated max, never a plain %HRmax
// (which systematically shrinks "easy" for anyone with a low resting
// HR) — can also classify a SINGLE value synchronously, like one already-
// completed session's own average HR, without a fresh HealthKit sample
// query for something that doesn't need per-second resolution. One
// source of truth for both: HealthStore's classifier calls into this too.
enum HeartRateZoneClassifier {
    // Same fallback order HealthStore's own classifier uses: a configured/
    // measured maximum wins outright; otherwise Tanaka et al. 2001
    // (208 - 0.7×age, more accurate across ages than 220-age) beats a
    // peak-based guess; only falls back to the peak-based floor when
    // birthDate is also missing.
    nonisolated static func effectiveMaximum(configured: Double?, birthDate: Date?, observedPeak: Double?, now: Date = Date()) -> Double {
        let ageBased = birthDate.map { birthDate -> Double in
            let age = Calendar.current.dateComponents([.year], from: birthDate, to: now).year ?? 40
            return 208.0 - 0.7 * Double(age)
        }
        return configured ?? ageBased ?? min(208.0, max(170.0, (observedPeak ?? 165) + 5))
    }

    // Same "average the last 14 real readings, else the current snapshot"
    // resting-HR resolution HealthStore's classifier uses, factored out so
    // a second caller can't quietly drift onto a different window.
    nonisolated static func restingHR(recentHistory: [Double], snapshotFallback: Double) -> Double {
        recentHistory.isEmpty ? snapshotFallback : recentHistory.reduce(0, +) / Double(recentHistory.count)
    }

    // Zone index 1-5. Same Karvonen %HRR cut points (60/70/80/90% of
    // reserve) HealthStore's per-second classifier uses — applied here to
    // one bpm value instead of one HR sample among thousands.
    nonisolated static func zone(bpm: Double, manualBoundaries: HeartRateZoneBoundaries?, effectiveMax: Double, restingHR: Double) -> Int {
        if let manualBoundaries {
            return bpm < Double(manualBoundaries.z1z2) ? 1 : bpm < Double(manualBoundaries.z2z3) ? 2
                 : bpm < Double(manualBoundaries.z3z4) ? 3 : bpm < Double(manualBoundaries.z4z5) ? 4 : 5
        }
        // Degrades to plain %HRmax on its own when restingHR is 0 (no
        // resting-HR data at all) since reserve then equals effectiveMax —
        // same behavior as the per-second classifier.
        let reserve = max(1, effectiveMax - restingHR)
        let fraction = (bpm - restingHR) / reserve
        return fraction < 0.60 ? 1 : fraction < 0.70 ? 2 : fraction < 0.80 ? 3 : fraction < 0.90 ? 4 : 5
    }
}
