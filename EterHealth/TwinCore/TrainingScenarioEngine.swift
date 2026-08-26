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
    // True for exactly the one scenario matching the athlete's own real
    // ProgressionPace (Ajustes/GoalEditorView) — the concrete link between
    // "Tres futuros" and the real plan: this is the trajectory
    // TrainingPlanEngine.progressedCeiling is actually ramping the real
    // week's long-run/long-session ceilings along right now, not just one
    // of three equally-hypothetical alternatives.
    let isCurrentPace: Bool
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
    // Real training-load history — the same >=8-day/real-habitual-load
    // gate PerformanceEngine.loadGuidance already applies — before
    // simulating a block on top of it means anything.
    nonisolated private static let minimumObservedDays = 8

    // currentPace: the athlete's own real ProgressionPace — used only to
    // flag which scenario below is isCurrentPace, never to hide the other
    // two. This is what makes "Tres futuros" a comparison against the
    // plan's real behavior instead of three disconnected hypotheticals:
    // ProgressionPace.weeklyGrowthRate is the SAME number
    // TrainingPlanEngine.progressedCeiling now actually ramps the real
    // week's long-run/long-session ceilings by.
    static func simulate(health: HealthStore, imports: ImportStore, currentPace: ProgressionPace, weeks: Int = 8, now: Date = Date()) -> [TrainingScenario] {
        let baseline = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        guard baseline.observedLoadDays >= minimumObservedDays, baseline.habitualLoad > 0 else { return [] }
        return [
            scenario(name: ProgressionPace.conservative.rawValue, growth: ProgressionPace.conservative.weeklyGrowthRate,
                    isCurrentPace: currentPace == .conservative, baseline: baseline, weeks: weeks, now: now),
            scenario(name: ProgressionPace.optimal.rawValue, growth: ProgressionPace.optimal.weeklyGrowthRate,
                    isCurrentPace: currentPace == .optimal, baseline: baseline, weeks: weeks, now: now),
            scenario(name: ProgressionPace.aggressive.rawValue, growth: ProgressionPace.aggressive.weeklyGrowthRate,
                    isCurrentPace: currentPace == .aggressive, baseline: baseline, weeks: weeks, now: now)
        ]
    }

    nonisolated static func scenario(name: String, growth: Double, isCurrentPace: Bool = false, baseline: PerformanceSummary, weeks: Int, now: Date) -> TrainingScenario {
        // PR3c: los dos canales. La rampa sigue siendo un objetivo semanal
        // agregado — este motor no sabe cómo repartirá el atleta la semana —
        // así que crece manteniendo la MEZCLA aeróbico/fuerza que ya tiene.
        // Con un reparto proporcional los números apenas se mueven respecto
        // al combinado, y eso es lo honesto: una rampa proporcional no crea
        // interferencia entre canales. Lo que se gana es que ya no hay una
        // segunda definición del ratio, y que el suelo de confianza por canal
        // aplica también aquí.
        var acute = baseline.dual.acuteChannels
        var habitual = baseline.dual.habitualChannels
        var weeklyTargetLoad = baseline.habitualLoad
        let aerobicShare = baseline.habitualLoad > 0 ? baseline.dual.habitualAerobic / baseline.habitualLoad : 1
        var points: [ScenarioWeekPoint] = []
        let calendar = Calendar.current
        for weekIndex in 0..<max(1, weeks) {
            // Every 4th week backs off — the same periodization convention
            // TrainingPlanEngine's own deload logic uses elsewhere. A
            // scenario that ramped every single week with no relief would
            // model a straight line to overtraining, not a real block.
            let isDeloadWeek = weekIndex > 0 && weekIndex % 4 == 0
            let priorRatio = DualLoad.governingRatio(acute: acute, habitual: habitual)
            // Even "Agresivo" holds flat, never compounds further, once
            // its own trajectory has already reached overload — the point
            // of comparing scenarios is to show WHEN each one hits that
            // wall, not to keep growing past it as if the body would allow it.
            if isDeloadWeek {
                weeklyTargetLoad *= 0.70
            } else if priorRatio < 1.55 {
                weeklyTargetLoad *= (1 + growth)
            }
            let dayLoad = DualLoad(aerobic: weeklyTargetLoad / 7 * aerobicShare,
                                   strength: weeklyTargetLoad / 7 * (1 - aerobicShare))
            for _ in 0..<7 {
                acute = DualLoad(aerobic: PerformanceEngine.stepWeeklyEquivalent(acute.aerobic, dayLoad: dayLoad.aerobic, timeConstant: 7),
                                 strength: PerformanceEngine.stepWeeklyEquivalent(acute.strength, dayLoad: dayLoad.strength, timeConstant: 7))
                habitual = DualLoad(aerobic: PerformanceEngine.stepWeeklyEquivalent(habitual.aerobic, dayLoad: dayLoad.aerobic, timeConstant: 28),
                                    strength: PerformanceEngine.stepWeeklyEquivalent(habitual.strength, dayLoad: dayLoad.strength, timeConstant: 28))
            }
            let ratio = DualLoad.governingRatio(acute: acute, habitual: habitual)
            let guidance = PerformanceEngine.loadGuidance(ratio: ratio, sustainedWeeks: weekIndex, observedDays: minimumObservedDays + weekIndex * 7)
            let date = calendar.date(byAdding: .weekOfYear, value: weekIndex + 1, to: now) ?? now
            points.append(ScenarioWeekPoint(weekIndex: weekIndex, date: date, weeklyLoad: weeklyTargetLoad, loadRatio: ratio, guidance: guidance, isDeloadWeek: isDeloadWeek))
        }
        let weeksAtRisk = points.filter { $0.guidance == .overload || $0.guidance == .absorb }.count
        let peak = points.map(\.loadRatio).max() ?? 0
        let final = points.last?.loadRatio ?? 0
        let habitualChangePercent = baseline.habitualLoad > 0 ? ((habitual.combined / baseline.habitualLoad) - 1) * 100 : 0
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
            name: name, weeklyGrowthRate: growth, isCurrentPace: isCurrentPace, weeks: points,
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
