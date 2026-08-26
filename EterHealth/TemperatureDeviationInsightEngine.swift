import Foundation

// The other half of the wrist-temperature story PhysiologicalHealthView's
// extendedSignalRow deliberately leaves uncolored: favorableHigh is nil
// there because a rise has no single settled direction (it can be
// illness, a hard session, alcohol, room heat...) — genuinely ambiguous,
// not a gap. This engine doesn't try to resolve that ambiguity with a
// guessed coefficient; instead it asks the one source who actually
// knows — the user — and simply counts what they say over time. No
// correlation, no invented weighting: a frequency count of the user's
// own answers, which is the most honest thing that can be said from
// self-reported ground truth.
enum TemperatureDeviationInsightEngine {
    struct ReasonFrequency: Identifiable, Equatable {
        var id: TemperatureDeviationReason { reason }
        let reason: TemperatureDeviationReason
        let count: Int
        let percentage: Int
    }

    // Same 2% of the 8-week mean that PhysiologicalHealthView's
    // extendedSignalRow/trendCard already use as their "basically your
    // habitual" dead zone for this exact signal — reused rather than a
    // second invented threshold, so "significant enough to color" and
    // "significant enough to ask about" never disagree with each other.
    nonisolated static func isSignificantRise(delta: Double, mean: Double) -> Bool {
        delta > 0 && delta >= mean * 0.02
    }

    // Only answered logs (at least one reason picked) count toward the
    // breakdown — a log with just a free-text note and no reason tagged
    // has nothing to tally.
    nonisolated static func breakdown(_ logs: [TemperatureDeviationLog]) -> [ReasonFrequency] {
        let answered = logs.filter { !$0.reasons.isEmpty }
        guard !answered.isEmpty else { return [] }
        var counts: [TemperatureDeviationReason: Int] = [:]
        for log in answered { for reason in log.reasons { counts[reason, default: 0] += 1 } }
        let total = answered.count
        return counts.map { reason, count in
            ReasonFrequency(reason: reason, count: count, percentage: Int((Double(count) / Double(total) * 100).rounded()))
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason.rawValue < $1.reason.rawValue }
    }

    // Mirrors HabitAssociationEngine's own honesty threshold for "first
    // pattern" vs. a real one: below 3 answered episodes this states the
    // single most recent reason without dressing it up as a pattern;
    // from 3 on it names the leading reason and its share, and says so
    // explicitly when answers are actually spread out rather than
    // concentrated on one cause.
    nonisolated static func headline(_ logs: [TemperatureDeviationLog]) -> String? {
        let answered = logs.filter { !$0.reasons.isEmpty }
        guard !answered.isEmpty else { return nil }
        let frequencies = breakdown(logs)
        guard let leader = frequencies.first else { return nil }
        if answered.count < 3 {
            return "Todavía muy pocos registros (\(answered.count)) para hablar de un patrón; de momento la última subida la asociaste con \(leader.reason.rawValue.lowercased())."
        }
        if frequencies.count == 1 || leader.percentage >= 50 {
            return "De tus últimas \(answered.count) subidas de temperatura explicadas, \(leader.percentage)% las asociaste con \(leader.reason.rawValue.lowercased())."
        }
        return "De tus últimas \(answered.count) subidas de temperatura explicadas no hay una causa dominante: la más frecuente es \(leader.reason.rawValue.lowercased()) (\(leader.percentage)%), pero se reparte entre varias razones."
    }
}
