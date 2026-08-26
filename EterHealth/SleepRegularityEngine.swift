import Foundation

// Schedule regularity — how consistently this person goes to bed and wakes
// up — is a distinct question from duration or personal trend, both
// already covered elsewhere (PersonalBaselineEngine's sleep metric,
// LongevityEngine's trend/debt components). A person can average a
// perfectly healthy 8h a night while going to bed anywhere between 22:00
// and 03:00 — real circadian-health literature treats that kind of swing
// as its own risk factor, independent of total sleep amount.
struct SleepRegularity {
    let score: Double
    let bedtimeVariabilityMinutes: Double
    let wakeVariabilityMinutes: Double
    let samples: Int
    let evidence: String
}

enum SleepRegularityEngine {
    /// Needs a handful of real nights before saying anything — one or two
    /// nights can't tell a genuinely irregular schedule apart from a
    /// single late night. nil means "still accumulating," the same
    /// pattern every other provisional signal in this app already uses,
    /// never a guessed score from too little data.
    private static let minimumNights = 5

    static func evaluate(_ schedule: [NightlySleepSchedule], recentNights: Int = 14) -> SleepRegularity? {
        let recent = Array(schedule.suffix(recentNights))
        guard recent.count >= minimumNights else { return nil }

        let bedtimeOffsets = recent.map { hoursFromNoon($0.bedtime) }
        let wakeOffsets = recent.map { hoursFromNoon($0.wakeTime) }
        let bedtimeVariability = standardDeviation(bedtimeOffsets) * 60
        let wakeVariability = standardDeviation(wakeOffsets) * 60
        let averageVariability = (bedtimeVariability + wakeVariability) / 2

        // Bands loosely follow the "social jet lag" framing common in
        // sleep-regularity research: under ~30 min of night-to-night swing
        // reads as genuinely consistent, 30-60 min as typical/workable,
        // 60-105 min as a real irregular pattern, beyond that as a swing
        // large enough to itself be a circadian stressor regardless of
        // how many hours were slept.
        let score = averageVariability <= 30 ? 90.0
            : averageVariability <= 60 ? 75.0
            : averageVariability <= 105 ? 55.0
            : 35.0

        return SleepRegularity(
            score: score,
            bedtimeVariabilityMinutes: bedtimeVariability,
            wakeVariabilityMinutes: wakeVariability,
            samples: recent.count,
            evidence: "Horario: hora de dormir varía ±\(Int(bedtimeVariability.rounded())) min, hora de despertar ±\(Int(wakeVariability.rounded())) min (\(recent.count) noches)"
        )
    }

    // Hours since the most recent noon, e.g. 22:30 → 10.5, 00:30 → 12.5,
    // 01:00 → 13.0 — keeps a normal bedtime/wake window (evening through
    // early morning) as one continuous, non-wrapping number instead of
    // needing circular statistics to handle the midnight rollover.
    private static func hoursFromNoon(_ date: Date) -> Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0) / 60
        return hour >= 12 ? (hour - 12 + minute) : (hour + 12 + minute)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
