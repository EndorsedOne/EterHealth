import Foundation

// MEV/MAV/MRV (Minimum Effective / Maximum Adaptive / Maximum Recoverable
// weekly Volume) — the volume-landmark concept is broadly established
// across hypertrophy training literature, not this app's invention. What
// IS this app's own is which specific weekly-set numbers it commits to:
// the MAV values below are exactly MuscleRadar's pre-existing per-bucket
// targets (previously private to that one View, used only for a
// retrospective radar chart), just split down to the same 10-muscle
// granularity TwinEngine/MuscleReadiness already track — so the radar
// display and the actual prescription logic describe "how much has this
// muscle done this week" using ONE shared number, not two independently
// invented ones. MEV/MRV are derived as fixed 0.5x/1.5x ratios of MAV — a
// real simplification of how landmark spacing actually varies muscle to
// muscle in the literature, documented as such rather than dressed up
// with false per-muscle precision this app can't back with its own data.
struct MuscleVolumeLandmarks {
    let mev: Double
    let mav: Double
    let mrv: Double
}

enum MuscleVolumeLandmarkTable {
    // Same 10 names MuscleReadiness.name already uses.
    private static let weeklyMAV: [String: Double] = [
        "Cuádriceps": 8, "Glúteos": 6, "Isquios": 4, "Gemelos": 4,
        "Pecho": 15, "Espalda": 16, "Hombros": 13,
        "Bíceps": 7, "Tríceps": 9, "Core": 8
    ]
    // Falls back to this when a muscle name isn't in the table above —
    // matches MuscleRadar's own prior fallback for the same situation.
    private static let fallbackMAV = 14.0

    nonisolated static func landmarks(for muscle: String) -> MuscleVolumeLandmarks {
        let mav = weeklyMAV[muscle] ?? fallbackMAV
        return MuscleVolumeLandmarks(mev: (mav * 0.5).rounded(), mav: mav, mrv: (mav * 1.5).rounded())
    }

    // Same bucket names MuscleRadar's own radar axes use — its displayed
    // target is now the SUM of its constituent muscles' real MAV, instead
    // of a second, separately hand-picked aggregate that happened to
    // match by coincidence.
    nonisolated static func bucketMAV(_ bucket: String) -> Double {
        switch bucket {
        case "Piernas": return ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"].reduce(0) { $0 + (weeklyMAV[$1] ?? 0) }
        case "Brazos": return ["Bíceps", "Tríceps"].reduce(0) { $0 + (weeklyMAV[$1] ?? 0) }
        default: return weeklyMAV[bucket] ?? fallbackMAV
        }
    }
}
