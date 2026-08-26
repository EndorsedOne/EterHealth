import Foundation

struct PerformanceSummary {
    let sessions: Int
    let minutes: Double
    let calories: Double
    let strengthSets: Int
    let strengthVolume: Double
    let previousSessions: Int
    let daily: [DailyTraining]
    // PR3: los dos canales son ahora la fuente. acuteLoad/habitualLoad de
    // abajo son la LECTURA combinada de siempre, derivada de ellos — el
    // mismo número exacto (el EWMA es lineal), no una tercera serie que
    // pueda separarse en silencio de los canales que deciden.
    let dual: DualLoadSummary
    let lowAerobic: Double
    let highAerobic: Double
    let anaerobic: Double
    let observedLoadDays: Int
    let sustainedLoadWeeks: Int

    var acuteLoad: Double { dual.acuteAerobic + dual.acuteStrength }
    var habitualLoad: Double { dual.habitualAerobic + dual.habitualStrength }

    var sessionChange: Int { sessions - previousSessions }
    // PR3f: una sola guidance y un solo ratio en toda la app — los de los
    // canales. Mientras la UI leía el ratio combinado y el plan y el score ya
    // gateaban por canal, la tarjeta podía decir "Carga productiva · ×0.93"
    // el mismo día que la recomendación decía recuperar. `loadRatio` es
    // ahora el ratio que gobierna, que es justo el que la guidance de al lado
    // está describiendo; los números crudos que la tarjeta muestra
    // (acuteLoad/habitualLoad) siguen siendo el combinado, y eso es correcto:
    // son carga total, no un ratio.
    var loadRatio: Double { dual.governingRatio }
    var loadChannel: String { dual.governingChannel }
    var loadGuidance: LoadGuidance { dual.guidance }
    var loadState: String {
        loadGuidance.title
    }
    var loadAdvice: String { loadGuidance.advice }
    var requiresRecovery: Bool { loadGuidance == .overload }

    func projectedAcuteLoad(adding sessionLoad: Double) -> Double {
        acuteLoad + sessionLoad * (1 - exp(-1 / 7.0)) * 7
    }

    func projectedLoadRatio(adding sessionLoad: Double) -> Double {
        guard habitualLoad > 0 else { return 0 }
        let projectedChronic = habitualLoad + sessionLoad * (1 - exp(-1 / 28.0)) * 7
        return projectedAcuteLoad(adding: sessionLoad) / projectedChronic
    }
}

enum LoadGuidance: Equatable {
    case learning, low, productive, absorb, deload, overload

    var title: String {
        switch self {
        case .learning: return "Creando línea base"
        case .low: return "Carga por debajo de tu base"
        case .productive: return "Carga productiva"
        case .absorb: return "Conviene absorber carga"
        case .deload: return "Descarga aconsejable"
        case .overload: return "Sobrecarga probable"
        }
    }

    var advice: String {
        switch self {
        case .learning: return "Necesitamos más días registrados antes de juzgar el cambio de carga."
        case .low: return "Estás por debajo de tu carga reciente; puede ser recuperación útil o pérdida de continuidad según el plan."
        case .productive: return "La carga reciente está cerca de tu capacidad habitual y permite progresar gradualmente."
        case .absorb: return "Evita sumar otra sesión dura seguida; conserva estímulo con intensidad suave o menor volumen."
        case .deload: return "Llevas varias semanas sosteniendo carga. Reduce aproximadamente un 25–35% el volumen durante unos días y conserva algo de intensidad técnica."
        case .overload: return "El pico reciente supera claramente tu carga habitual. Prioriza recuperación y reevalúa antes de otra sesión exigente."
        }
    }
}

struct TrainingBalance {
    let phase: String
    let headline: String
    let explanation: String
    let runningScore: Int
    let strengthScore: Int
    let intensityScore: Int
    let recoveryScore: Int
    let nextPriorities: [String]
}

struct DailyTraining: Identifiable {
    var id: Date { date }
    let date: Date
    let sessions: Int
    let load: Double
}

@MainActor
enum PerformanceEngine {
    static func summarize(health: HealthStore, imports: ImportStore, now: Date = Date()) -> PerformanceSummary {
        let calendar = Calendar.current
        let seven = calendar.date(byAdding: .day, value: -7, to: now)!
        let fourteen = calendar.date(byAdding: .day, value: -14, to: now)!
        let hevyCurrent = imports.workouts.filter { $0.start >= seven && $0.start <= now }
        let hevyPrevious = imports.workouts.filter { $0.start >= fourteen && $0.start < seven }
        let healthCurrent = health.recentWorkouts.filter {
            $0.date >= seven && !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }
        let healthPrevious = health.recentWorkouts.filter {
            $0.date >= fourteen && $0.date < seven && !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }

        let sets = hevyCurrent.reduce(0) { total, workout in total + workout.exercises.reduce(0) { $0 + $1.sets } }
        let volume = hevyCurrent.reduce(0.0) { total, workout in total + workout.exercises.reduce(0) { $0 + $1.volume } }
        let hevyMinutes = hevyCurrent.reduce(0.0) { $0 + max(0, $1.end.timeIntervalSince($1.start) / 60) }
        let healthMinutes = healthCurrent.reduce(0.0) { $0 + $1.durationMinutes }
        let calories = healthCurrent.compactMap(\.calories).reduce(0, +)

        // Un solo historial, ya separado en el origen — el bucle combinado
        // que había aquí y el suyo propio de TwinPhysiology.derive eran la
        // misma separación escrita dos veces.
        let dualHistory = dailyDualHistory(health: health, imports: imports, days: 84, now: now)
        let loadHistory = dualHistory.map { DailyTraining(date: $0.date, sessions: $0.sessions, load: $0.load) }
        let daily = Array(loadHistory.suffix(28))
        let combinedLoads = loadHistory.map(\.load)
        let dual = dualSummary(history: dualHistory)
        let sustainedCombinedWeeks = sustainedWeeks(loads: combinedLoads,
                                                    habitualWeekly: dual.habitualAerobic + dual.habitualStrength)

        let zone = Dictionary(uniqueKeysWithValues: health.heartRateZones.map { ($0.zone, $0.percentage) })
        let low = (zone[1] ?? 0) + (zone[2] ?? 0)
        let high = (zone[3] ?? 0) + (zone[4] ?? 0)
        let anaerobic = zone[5] ?? 0
        return PerformanceSummary(
            sessions: hevyCurrent.count + healthCurrent.count,
            minutes: hevyMinutes + healthMinutes,
            calories: calories,
            strengthSets: sets,
            strengthVolume: volume,
            previousSessions: hevyPrevious.count + healthPrevious.count,
            daily: daily, dual: dual,
            lowAerobic: low, highAerobic: high, anaerobic: anaerobic,
            observedLoadDays: dual.observedDays, sustainedLoadWeeks: sustainedCombinedWeeks
        )
    }

    // TwinCore: goalProfile/reviews/events/activeInjuries/calibration/
    // personalAnchor used to come from GoalStore/TwinStateStore/
    // LifestyleFactorStore/WorkoutReviewStore/InjuryStore singleton
    // instances — same required-injection reasoning as TwinEngine.assess,
    // bundled into one TwinContext since PR1.5.
    static func balance(health: HealthStore, imports: ImportStore, context: TwinContext,
                        now: Date = Date()) -> TrainingBalance {
        let goalProfile = context.profile
        let summary = summarize(health: health, imports: imports, now: now)
        let calendar = Calendar.current
        let block = TrainingPlanEngine.activeBlock(on: now, profile: goalProfile)
        let recent = imports.workouts.filter { $0.start >= calendar.date(byAdding: .day, value: -10, to: now)! }
        let strengthSessions = recent.count
        let runningSessions = health.recentWorkouts.filter { $0.date >= calendar.date(byAdding: .day, value: -10, to: now)! && $0.activity == "Carrera" }.count
        let hardPercent = summary.highAerobic + summary.anaerobic
        let assessment = TwinEngine.assess(health: health, imports: imports, context: context, now: now)

        let phase = block.name
        let desiredRuns = block.runningSessions
        let desiredStrength = block.strengthSessions
        let desiredHard = RunningPerformanceEngine.hardIntensityTarget(for: block)

        func score(_ value: Int, target: ClosedRange<Int>) -> Int {
            if target.contains(value) { return 100 }
            if value < target.lowerBound { return max(20, 100 - (target.lowerBound - value) * 28) }
            return max(35, 100 - (value - target.upperBound) * 18)
        }
        let runningScore = score(runningSessions, target: desiredRuns)
        let strengthScore = score(strengthSessions, target: desiredStrength)
        let intensityScore: Int = desiredHard.contains(hardPercent) ? 100 : hardPercent < desiredHard.lowerBound ? max(30, 100 - Int(desiredHard.lowerBound - hardPercent) * 3) : max(25, 100 - Int(hardPercent - desiredHard.upperBound) * 3)
        let recoveryScore = assessment.score
        var priorities: [String] = []
        if runningSessions < desiredRuns.lowerBound { priorities.append("Añadir una sesión de carrera, preferiblemente suave si ya hubo intensidad.") }
        if strengthSessions < desiredStrength.lowerBound { priorities.append(goalProfile.gymAvailable ? "Añadir una exposición de fuerza alineada con las marcas activas." : "Añadir fuerza sin gimnasio: empuje, tirón, unilateral de pierna y core.") }
        if hardPercent > desiredHard.upperBound {
            priorities.append("Reducir intensidad: \(Int(hardPercent.rounded()))% en Z3–Z5 frente al \(Int(desiredHard.lowerBound))–\(Int(desiredHard.upperBound))% objetivo de esta fase.")
        }
        if hardPercent < desiredHard.lowerBound && runningSessions > 1 { priorities.append("Incluir un estímulo de calidad: tempo, umbral o intervalos según recuperación.") }
        if assessment.score < 55 { priorities.insert("Priorizar recuperación antes de añadir carga.", at: 0) }
        if priorities.isEmpty { priorities.append("Mantener el reparto actual y progresar la carga de forma gradual.") }
        let overall = (runningScore + strengthScore + intensityScore + recoveryScore) / 4
        let headline = overall >= 82 ? "Equilibrio alineado con tu fase" : overall >= 62 ? "Buen rumbo, con un ajuste claro" : "El reparto se está alejando del objetivo"
        let activeTargets = goalProfile.activeGoals.prefix(4).map { goal in
            [goal.title, goal.displayTarget].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ")
        let explanation = "\(runningSessions) carreras y \(strengthSessions) sesiones de fuerza en 10 días · \(Int(hardPercent.rounded()))% de cardio intenso. Fase calculada desde: \(activeTargets)."
        return TrainingBalance(phase: phase, headline: headline, explanation: explanation, runningScore: runningScore, strengthScore: strengthScore, intensityScore: intensityScore, recoveryScore: recoveryScore, nextPriorities: priorities)
    }

    // Shared with DecisionSimulatorEngine so a simulated session's load uses the
    // exact same per-minute weighting as the real daily load history.
    // nonisolated: a pure switch, also called from TwinPhysiology.derive.
    nonisolated static func cardioFactor(_ activity: String) -> Double {
        switch activity {
        case "Intervalos de alta intensidad": return 2.0
        case "Carrera", "Escaleras": return 1.45
        case "Natación": return 1.10
        case "Ciclismo": return 1.15
        default: return 0.75
        }
    }

    nonisolated static func ewmaWeeklyEquivalent(loads: [Double], timeConstant: Double) -> Double {
        guard let first = loads.first, timeConstant > 0 else { return 0 }
        let alpha = 1 - exp(-1 / timeConstant)
        let average = loads.dropFirst().reduce(first) { current, load in current + alpha * (load - current) }
        return average * 7
    }

    /// Advances a weekly-equivalent EWMA (the same units acuteLoad/habitualLoad
    /// already use) by exactly one more day of `dayLoad` — the iterative form of
    /// ewmaWeeklyEquivalent above, for simulating several days forward one at a
    /// time instead of recomputing the whole history. With `dayLoad: 0` this is
    /// mathematically identical to plain exponential decay (`current * exp(-1/τ)`),
    /// so callers that never assume a future session (the original behavior)
    /// see no change at all.
    nonisolated static func stepWeeklyEquivalent(_ current: Double, dayLoad: Double, timeConstant: Double) -> Double {
        guard timeConstant > 0 else { return current }
        let alpha = 1 - exp(-1 / timeConstant)
        let average = current / 7
        let nextAverage = average + alpha * (dayLoad - average)
        return nextAverage * 7
    }

    nonisolated static func loadGuidance(ratio: Double, sustainedWeeks: Int, observedDays: Int) -> LoadGuidance {
        guard observedDays >= 8, ratio > 0 else { return .learning }
        if ratio >= 1.55 { return .overload }
        if sustainedWeeks >= 3 && ratio >= 1.08 { return .deload }
        if ratio >= 1.30 { return .absorb }
        if ratio < 0.65 { return .low }
        return .productive
    }
}
