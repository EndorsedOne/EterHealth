import Foundation

// Matthew Walker's core argument against duration-only sleep scores: two
// nights of identical length can be very differently restorative. Deep
// (slow-wave/N3) sleep drives physical restoration — growth hormone
// release, glymphatic clearance, declarative memory consolidation — and
// concentrates in the first half of the night. REM drives emotional
// processing, procedural memory and creativity, and concentrates in the
// second half/early morning — which is exactly why a sleep cut short by
// an early alarm disproportionately steals REM, not deep sleep, even
// though total hours barely change. LongevityEngine's "Recuperación" and
// PersonalBaselineEngine's sleep baseline are both duration/timing-only
// (total hours, personal trend, cumulative debt, bedtime/wake
// regularity) — none of them ask what that sleep was actually made of.
// This engine is that missing question.
//
// Honesty matters here more than for most signals in this app: Apple
// Watch stage classification is inferred from wrist motion, heart rate
// and (Ultra) wrist temperature against a model validated against
// polysomnography — it is not EEG. Overall asleep/awake detection is
// quite reliable; which SPECIFIC stage a given period was is notably
// less so, with light/deep confusion the most common failure mode.
// Walker himself has cautioned exactly this: treat a consumer wearable's
// stage split as a directional trend, never as a clinical measurement.
// That caveat belongs in whatever surfaces this score, not just in a
// code comment — see PhysiologicalHealthView's existing sleep card.
enum SleepArchitectureEngine {
    struct Assessment {
        let score: Int
        let confidence: TrustLevel
        let evidence: String
        let nights: Int
        let averageDeepShare: Double
        let averageRemShare: Double
        let averageContinuity: Double
        let isPersonalized: Bool
        // nil unless isPersonalized. The average of the deep/REM deviation
        // vs. the user's own prior-month baseline — exposed as a number
        // (not just baked into `evidence`'s prose) so a view can say
        // accurately whether this period is a real improvement or
        // regression against the user's own trend, instead of guessing
        // that from the absolute score.
        let personalDeviation: Double?
    }

    // Reference bands are broad, published sleep-medicine norms for
    // healthy adults (not a clinical cutoff, and not something this app
    // invented) — deep ≈13–23% and REM ≈20–25% of total sleep time.
    // Both naturally decline somewhat with age; there is no attempt here
    // to adjust for that since the app doesn't collect age, so the band
    // is intentionally wide rather than falsely precise.
    // Not `private`: PhysiologicalHealthView's sleep card draws these same
    // bands as visual gauges instead of just quoting them in a sentence —
    // exposing the actual constants means the view can never quietly drift
    // out of sync with what the engine is really scoring against.
    static let deepShareBand = (low: 0.13, high: 0.23)
    static let remShareBand = (low: 0.20, high: 0.25)
    // Same reasoning: the continuity gauge shades its "healthy" zone from
    // `continuityBand.ideal` up, using the exact threshold the score below
    // is computed from.
    static let continuityBand = (poor: 0.75, ideal: 0.95)
    // The prior window sits right before the 14-night scoring window
    // (day -45 to day -15) — "how does the last two weeks compare to the
    // month before that," not to the same nights being scored.
    private static let priorWindowStartDays = -45
    private static let priorWindowEndDays = -15
    private static let minimumPriorNights = 10

    static func evaluate(_ nights: [NightlySleepStages], now: Date = Date()) -> Assessment? {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        // Nights with no real deep/REM split (older data, phone-only
        // tracking) would silently dilute the average with a signal that
        // says nothing about architecture — excluded, not counted as 0%.
        let recent = nights.filter { $0.night >= cutoff && $0.hasStageSplit }
        guard recent.count >= 5 else { return nil }

        let averageDeepShare = average(recent.map { $0.deepHours / $0.asleepHours })
        let averageRemShare = average(recent.map { $0.remHours / $0.asleepHours })
        let averageContinuity = average(recent.map { $0.asleepHours / max($0.asleepHours + $0.awakeHours, 0.01) })

        let deepScore = bandScore(averageDeepShare, band: deepShareBand)
        let remScore = bandScore(averageRemShare, band: remShareBand)
        let continuityScore = ascendingScore(averageContinuity, poor: continuityBand.poor, ideal: continuityBand.ideal)
        // The absolute band stays the primary driver on purpose — Walker's
        // actual clinical point is that chronically low deep/REM is bad
        // *regardless* of whether it's "normal for you". Letting a
        // person's own average fully replace the band would let someone
        // with a genuinely poor, stable pattern (say, alcohol-suppressed
        // REM every night) score consistently well just for being
        // consistent. So the personal average becomes an ANCHOR for a
        // secondary trend signal — is this getting better or worse
        // relative to your own last month — not a substitute for the
        // physiological band.
        let baseScore = average([deepScore, remScore, continuityScore])

        let priorStart = calendar.date(byAdding: .day, value: priorWindowStartDays, to: now) ?? now
        let priorEnd = calendar.date(byAdding: .day, value: priorWindowEndDays, to: now) ?? now
        let prior = nights.filter { $0.night >= priorStart && $0.night < priorEnd && $0.hasStageSplit }

        var score = baseScore
        var isPersonalized = false
        var evidenceSuffix = ""
        var personalDeviation: Double? = nil
        if prior.count >= minimumPriorNights {
            let personalDeepBaseline = average(prior.map { $0.deepHours / $0.asleepHours })
            let personalRemBaseline = average(prior.map { $0.remHours / $0.asleepHours })
            if personalDeepBaseline > 0 && personalRemBaseline > 0 {
                let deepDeviation = (averageDeepShare - personalDeepBaseline) / personalDeepBaseline
                let remDeviation = (averageRemShare - personalRemBaseline) / personalRemBaseline
                let averageDeviation = (deepDeviation + remDeviation) / 2
                // Asymmetric on purpose: a decline against your own recent
                // pattern costs more than an equivalent rise earns —
                // flagging regression matters more here than rewarding
                // noise, and the band above already owns the upside.
                let adjustment = averageDeviation >= 0 ? min(5, averageDeviation * 20) : max(-12, averageDeviation * 20)
                score = min(100, max(0, baseScore + adjustment))
                isPersonalized = true
                personalDeviation = averageDeviation
                evidenceSuffix = " · \(averageDeviation >= 0.03 ? "por encima de" : averageDeviation <= -0.03 ? "por debajo de" : "en línea con") tu propio promedio de \(prior.count) noches previas"
            }
        }

        let evidence = "Profundo \(percent(averageDeepShare))% (referencia 13–23%) · REM \(percent(averageRemShare))% (referencia 20–25%) · continuidad \(percent(averageContinuity))%\(evidenceSuffix) · \(recent.count) noches con fases reales · estimación del Apple Watch, no polisomnografía"

        return Assessment(
            score: Int(score.rounded()), confidence: ConfidenceEngine.level(samples: recent.count, medium: 7, high: 14),
            evidence: evidence, nights: recent.count,
            averageDeepShare: averageDeepShare, averageRemShare: averageRemShare, averageContinuity: averageContinuity,
            isPersonalized: isPersonalized, personalDeviation: personalDeviation
        )
    }

    // Per-night deep/REM share as a daily TrendPoint series — the same
    // per-night hasStageSplit-filtered shares `evaluate` above averages,
    // just exposed one night at a time so HabitAssociationEngine can
    // correlate a habit against architecture specifically (deep sleep,
    // REM) instead of only total duration. A night with no real stage
    // split contributes nothing, same exclusion `evaluate` already applies.
    nonisolated static func dailyDeepShareSeries(_ nights: [NightlySleepStages]) -> [TrendPoint] {
        nights.filter(\.hasStageSplit).map { TrendPoint(date: $0.night, value: $0.deepHours / $0.asleepHours * 100) }
    }

    nonisolated static func dailyRemShareSeries(_ nights: [NightlySleepStages]) -> [TrendPoint] {
        nights.filter(\.hasStageSplit).map { TrendPoint(date: $0.night, value: $0.remHours / $0.asleepHours * 100) }
    }

    private static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    // A share below OR above the reference band both cost score — unlike
    // steps or VO2max, more deep/REM isn't unambiguously better past a
    // healthy range (and an outlier high share is more often a
    // classification artifact than a real physiological gain).
    private static func bandScore(_ value: Double, band: (low: Double, high: Double)) -> Double {
        if value >= band.low && value <= band.high { return 90 }
        let width = band.high - band.low
        let distance = value < band.low ? band.low - value : value - band.high
        let penalty = min(65, (distance / width) * 65)
        return max(25, 90 - penalty)
    }

    private static func ascendingScore(_ value: Double, poor: Double, ideal: Double) -> Double {
        guard ideal > poor else { return 50 }
        let ratio = (value - poor) / (ideal - poor)
        return min(95, max(20, 20 + ratio * 75))
    }
}
