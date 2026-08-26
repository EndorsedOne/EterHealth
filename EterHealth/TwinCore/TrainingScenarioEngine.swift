import Foundation

// "Simulador, no receta" — the actual gap this closes: every other forward
// view in this app (weekAhead, DecisionSimulatorEngine) produces exactly
// ONE trajectory. This runs the SAME EWMA fitness-fatigue machinery
// PerformanceEngine already uses for today's real load ratio, forward
// under 2-3 explicit weekly-growth policies over a real multi-week block,
// so a training decision can be compared against actual alternatives
// instead of just the one path the app happened to propose.
//
// Two honesty boundaries, both deliberate:
// 1. "Agresivo" never means "reckless" — its growth rate is bounded by the
//    same ~15%/week ceiling this app already treats as the safe edge
//    elsewhere (progressedCeiling, Gabbett-style ACWR guidance). There is
//    no scenario here that models training through injury risk as if it
//    were a legitimate option.
// 2. The projected race-pace band is a GENERIC, population-level
//    relationship (Banister 1975 / Busso 2003's impulse-response
//    performance model: performance responds to accumulated fitness
//    with diminishing returns, not linearly) — never fit to this
//    athlete's own history, and deliberately kept separate from
//    RunningPerformanceEngine's RaceForecast, which stays 100% personal.
//    Presented as a wide, capped band, not a point estimate, so it can't
//    be mistaken for the same kind of number as a real race prediction.
struct ScenarioWeekPoint: Identifiable {
    var id: Int { weekIndex }
    let weekIndex: Int
    let date: Date
    let weeklyLoad: Double
    let loadRatio: Double
    let guidance: LoadGuidance
    let isDeloadWeek: Bool
}

struct TrainingScenario: Identifiable {
    var id: String { name }
    let name: String
    let weeklyGrowthRate: Double
    let weeks: [ScenarioWeekPoint]
    let peakLoadRatio: Double
    let finalLoadRatio: Double
    let weeksAtRisk: Int
    let habitualLoadChangePercent: Double
    let projectedPaceChangePercent: ClosedRange<Double>
    let summary: String
}

@MainActor
enum TrainingScenarioEngine {
    static let conservativeGrowth = 0.04
    static let optimalGrowth = 0.09
    static let aggressiveGrowth = 0.15
    // Real training-load history — the same >=8-day/real-habitual-load
    // gate PerformanceEngine.loadGuidance already applies — before
    // simulating a block on top of it means anything.
    nonisolated private static let minimumObservedDays = 8

    static func simulate(health: HealthStore, imports: ImportStore, weeks: Int = 8, now: Date = Date()) -> [TrainingScenario] {
        let baseline = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        guard baseline.observedLoadDays >= minimumObservedDays, baseline.habitualLoad > 0 else { return [] }
        return [
            scenario(name: "Conservador", growth: conservativeGrowth, baseline: baseline, weeks: weeks, now: now),
            scenario(name: "Óptimo", growth: optimalGrowth, baseline: baseline, weeks: weeks, now: now),
            scenario(name: "Agresivo", growth: aggressiveGrowth, baseline: baseline, weeks: weeks, now: now)
        ]
    }

    nonisolated static func scenario(name: String, growth: Double, baseline: PerformanceSummary, weeks: Int, now: Date) -> TrainingScenario {
        var acute = baseline.acuteLoad
        var habitual = baseline.habitualLoad
        var weeklyTargetLoad = baseline.habitualLoad
        var points: [ScenarioWeekPoint] = []
        let calendar = Calendar.current
        for weekIndex in 0..<max(1, weeks) {
            // Every 4th week backs off — the same periodization convention
            // TrainingPlanEngine's own deload logic uses elsewhere. A
            // scenario that ramped every single week with no relief would
            // model a straight line to overtraining, not a real block.
            let isDeloadWeek = weekIndex > 0 && weekIndex % 4 == 0
            let priorRatio = habitual > 0 ? acute / habitual : 0
            // Even "Agresivo" holds flat, never compounds further, once
            // its own trajectory has already reached overload — the point
            // of comparing scenarios is to show WHEN each one hits that
            // wall, not to keep growing past it as if the body would allow it.
            if isDeloadWeek {
                weeklyTargetLoad *= 0.70
            } else if priorRatio < 1.55 {
                weeklyTargetLoad *= (1 + growth)
            }
            let dayLoad = weeklyTargetLoad / 7
            for _ in 0..<7 {
                acute = PerformanceEngine.stepWeeklyEquivalent(acute, dayLoad: dayLoad, timeConstant: 7)
                habitual = PerformanceEngine.stepWeeklyEquivalent(habitual, dayLoad: dayLoad, timeConstant: 28)
            }
            let ratio = habitual > 0 ? acute / habitual : 0
            let guidance = PerformanceEngine.loadGuidance(ratio: ratio, sustainedWeeks: weekIndex, observedDays: minimumObservedDays + weekIndex * 7)
            let date = calendar.date(byAdding: .weekOfYear, value: weekIndex + 1, to: now) ?? now
            points.append(ScenarioWeekPoint(weekIndex: weekIndex, date: date, weeklyLoad: weeklyTargetLoad, loadRatio: ratio, guidance: guidance, isDeloadWeek: isDeloadWeek))
        }
        let weeksAtRisk = points.filter { $0.guidance == .overload || $0.guidance == .absorb }.count
        let peak = points.map(\.loadRatio).max() ?? 0
        let final = points.last?.loadRatio ?? 0
        let habitualChangePercent = baseline.habitualLoad > 0 ? ((habitual / baseline.habitualLoad) - 1) * 100 : 0
        let paceRange = paceChangeBand(habitualLoadChangePercent: habitualChangePercent)
        let firstRisk = points.first { $0.guidance == .overload }
        let summary: String
        if let firstRisk {
            summary = "Alcanza sobrecarga probable en la semana \(firstRisk.weekIndex + 1) de \(weeks)."
        } else if weeksAtRisk > 0 {
            summary = "\(weeksAtRisk) semana\(weeksAtRisk == 1 ? "" : "s") pidiendo absorber carga, sin llegar a sobrecarga."
        } else {
            summary = "Se mantiene en carga productiva las \(weeks) semanas completas."
        }
        return TrainingScenario(
            name: name, weeklyGrowthRate: growth, weeks: points,
            peakLoadRatio: peak, finalLoadRatio: final, weeksAtRisk: weeksAtRisk,
            habitualLoadChangePercent: habitualChangePercent,
            projectedPaceChangePercent: paceRange, summary: summary
        )
    }

    // Generic, population-level, NOT personal — see file header. Busso's
    // "variable dose-response" point is exactly that the performance gain
    // per unit of accumulated load shrinks as that load rises (diminishing
    // returns), which is why this is a diminishing multiplier with a hard
    // cap, not a straight percentage of the load change.
    nonisolated static func paceChangeBand(habitualLoadChangePercent: Double) -> ClosedRange<Double> {
        let positiveChange = max(0, habitualLoadChangePercent)
        let low = -min(6.0, positiveChange * 0.08)
        let high = -min(6.0, positiveChange * 0.03)
        return low...high
    }
}
