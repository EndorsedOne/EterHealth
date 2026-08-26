import Foundation

enum SimulatedDecision: String, CaseIterable, Identifiable {
    case rest = "Descansar"
    case quality = "Intervalos"
    case longRun = "Tirada larga"
    case strength = "Fuerza superior"
    // Lifestyle choices, not workouts — projected from éter's own learned
    // personal habit associations (HabitAssociationEngine) instead of a
    // generic rule, the same engine that already powers "Aprendizajes" but
    // that this simulator never touched before.
    case alcohol = "2 cervezas esta noche"
    case fastingTonight = "Ayuno de 16 h"
    case poorHydration = "Hidratación baja hoy"
    case sauna = "Sauna 20 min"
    var id: String { rawValue }
    var isLifestyle: Bool {
        switch self { case .alcohol, .fastingTonight, .poorHydration, .sauna: return true; default: return false }
    }

    // What this decision replaces today's training session with — nil for
    // a lifestyle choice, which never substitutes for the day's actual
    // workout, only shifts the readiness that feeds into the days after it.
    var overrideSessionKind: PlannedSessionKind? {
        switch self {
        case .rest: return .recovery
        case .quality: return .qualityRun
        case .longRun: return .longRun
        case .strength: return .strength
        case .alcohol, .fastingTonight, .poorHydration, .sauna: return nil
        }
    }
}

struct DecisionSimulation {
    let decision: SimulatedDecision
    let addedLoad: Double
    let projectedAcuteLoad: Double
    let projectedRatio: Double
    let tomorrowReadiness: Int
    let headline: String
    let explanation: String
    let performanceExpectation: String
    let tradeoffs: [String]
    let confidence: TrustLevel
    let trajectory: [DecisionProjectionDay]

    // The link to "Próximos 7 días": this decision, folded into the week-
    // ahead forecast instead of shown only as an isolated readiness number.
    // Reuses the exact addedLoad/tomorrowReadiness already computed above,
    // so the simulator and the week strip can never quietly disagree about
    // the same hypothetical.
    var weekAheadOverride: TrainingPlanEngine.DecisionOverride {
        let rationale = decision.isLifestyle
            ? "Simulación: \(decision.rawValue.lowercased()) — el entrenamiento de hoy no cambia, pero sí tu disponibilidad de mañana."
            : "Simulación: \(decision.rawValue.lowercased()) en vez de la recomendación real de hoy."
        return TrainingPlanEngine.DecisionOverride(
            kind: decision.overrideSessionKind, load: addedLoad,
            tomorrowReadiness: tomorrowReadiness, todayRationale: rationale
        )
    }
}

struct DecisionProjectionDay: Identifiable {
    var id: Int { day }
    let day: Int
    let readiness: Int
    let acuteLoad: Double
    let loadRatio: Double
    let guidance: String
}

@MainActor
enum DecisionSimulatorEngine {
    static func simulate(_ decision: SimulatedDecision, health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?, now: Date = Date()) -> DecisionSimulation {
        if decision.isLifestyle {
            return simulateLifestyle(decision, health: health, imports: imports, checkIn: checkIn, now: now)
        }
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, now: now)
        let added: Double
        let fatigue: Int
        let recovery: Int
        let tradeoffs: [String]
        let performanceExpectation: String
        let basis: HistoricalLoad?

        switch decision {
        case .alcohol, .fastingTonight, .poorHydration, .sauna:
            fatalError("Lifestyle decisions are routed to simulateLifestyle above and never reach this switch")

        case .rest:
            added = 0; fatigue = 0; recovery = 7; basis = nil
            tradeoffs = ["Más disponibilidad probable mañana", "No añade estímulo ni kilómetros", "Útil si hay dolor, enfermedad o fatiga acumulada"]
            performanceExpectation = "Sin sesión que valorar hoy — el beneficio se mide en la disponibilidad de mañana, no en un rendimiento."

        case .quality:
            let matched = qualifyingRuns(health.recentWorkouts, matching: TrainingPlanEngine.isQualityRun, now: now)
            let load = historicalLoad(matched, cardioFactor: PerformanceEngine.cardioFactor("Carrera"), fallback: 78)
            basis = load; added = load.load
            fatigue = added > 70 ? 14 : added > 45 ? 10 : 6; recovery = 0
            tradeoffs = ["Aporta estímulo de velocidad o umbral", "Eleva la carga cardiovascular aguda", "Probablemente desplaza mañana hacia descanso o tren superior"]
            performanceExpectation = paceExpectation(matched, readiness: assessment.score, label: "intervalos", basis: load)

        case .longRun:
            let matched = qualifyingRuns(health.recentWorkouts, matching: TrainingPlanEngine.isLongRun, now: now)
            let load = historicalLoad(matched, cardioFactor: PerformanceEngine.cardioFactor("Carrera"), fallback: 75)
            basis = load; added = load.load
            fatigue = added > 70 ? 12 : added > 45 ? 8 : 5; recovery = 0
            tradeoffs = ["Construye resistencia aeróbica y tolerancia de tiempo en pie", "Coste de recuperación alto por duración, no por intensidad", "Probablemente desplaza mañana hacia descanso o trabajo suave"]
            performanceExpectation = paceExpectation(matched, readiness: assessment.score, label: "tirada larga", basis: load)

        case .strength:
            let matched = imports.workouts.filter { $0.start <= now && now.timeIntervalSince($0.start) <= 120 * 86_400 }
            let loads = matched.map { workout in Double(workout.exercises.reduce(0) { $0 + $1.sets }) * 3 }
            let load = HistoricalLoad(load: loads.isEmpty ? 42 : median(loads), sessions: matched.count, isPersonal: matched.count >= 2)
            basis = load; added = load.load
            fatigue = added > 55 ? 8 : added > 30 ? 5 : 3; recovery = 1
            tradeoffs = ["Mantiene empuje y tirón sin cargar tanto las piernas", "Compatible con prioridad de running", "La fatiga local depende de series y proximidad al fallo"]
            let factor = StrengthPrescriptionEngine.readinessLoadFactor(assessment.score)
            let pct = Int((factor * 100).rounded())
            performanceExpectation = factor >= 1
                ? "Tu disponibilidad de hoy (\(assessment.score)/100) permite mantener o progresar ligeramente la carga habitual (~\(pct)% de tu referencia)."
                : "Con tu disponibilidad de hoy (\(assessment.score)/100), esperable prescribir ~\(pct)% de tu carga habitual — no es el día para buscar un máximo."
        }

        let projectedLoad = performance.projectedAcuteLoad(adding: added)
        let ratio = performance.projectedLoadRatio(adding: added)
        let ratioPenalty = ratio > 1.55 ? 8 : ratio > 1.30 ? 4 : 0
        let tomorrow = min(100, max(0, assessment.score - fatigue - ratioPenalty + recovery))
        let headline: String
        if tomorrow >= 70 { headline = "Mañana seguirías con buena disponibilidad" }
        else if tomorrow >= 50 { headline = "Mañana convendría ajustar la intensidad" }
        else { headline = "Mañana probablemente tocaría recuperar" }

        let sampleCount = health.recentWorkouts.count + imports.workoutCount
        var evidenceScore = min(100, Int((Double(sampleCount) / 25 * 55).rounded()) + Int((Double(assessment.baselineConfidence) * 0.45).rounded()))
        if let basis, !basis.isPersonal { evidenceScore = min(evidenceScore, 35) }
        let confidence = ConfidenceEngine.level(score: evidenceScore)

        let projectedChronic = ratio > 0 ? projectedLoad / ratio : performance.habitualLoad
        let trajectory = projectTrajectory(
            tomorrowReadiness: tomorrow, projectedAcuteLoad: projectedLoad,
            projectedChronicLoad: projectedChronic, days: 4,
            futureLoads: forwardPlanLoads(health: health, imports: imports, checkIn: checkIn, now: now, count: 3)
        )
        let explanation = basis.map { basis in
            basis.isPersonal
                ? "Parte de tu disponibilidad actual (\(assessment.score)/100) y suma la carga mediana de tus últimas \(basis.sessions) sesiones reales de este tipo."
                : "Parte de tu disponibilidad actual (\(assessment.score)/100). Aún sin suficiente historial de este tipo de sesión (\(basis.sessions) registrada(s)): usa una carga típica provisional en su lugar."
        } ?? "Parte de tu disponibilidad actual (\(assessment.score)/100) y aplica una respuesta de recuperación conservadora."

        return DecisionSimulation(
            decision: decision, addedLoad: added, projectedAcuteLoad: projectedLoad, projectedRatio: ratio,
            tomorrowReadiness: tomorrow, headline: headline, explanation: explanation,
            performanceExpectation: performanceExpectation,
            tradeoffs: tradeoffs, confidence: confidence, trajectory: trajectory
        )
    }

    // Projects a lifestyle choice using the SAME associations HabitAssociationEngine
    // already learns from this person's own HRV/pulse/sleep response, and the
    // same generic same-day modifiers TwinEngine already applies for these —
    // so "what if I do this tonight" and "what actually happened after I did
    // this" are one consistent model, not two disconnected guesses.
    private static func simulateLifestyle(_ decision: SimulatedDecision, health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?, now: Date = Date()) -> DecisionSimulation {
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, now: now)
        let associations = HabitAssociationEngine.analyze(
            events: LifestyleFactorStore.shared.events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory, sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory, now: now
        )
        let kind: HabitKind
        let genericImmediate: Int
        let tradeoffs: [String]
        switch decision {
        case .alcohol: kind = .alcohol; genericImmediate = -6; tradeoffs = ["Coste inmediato ya observado en el gemelo (2 bebidas ≈ -6 pt)", "El efecto real sobre HRV, pulso, sueño, respiración y temperatura depende de tu propia respuesta aprendida", "Hidratación y electrolitos mitigan parte, no todo"]
        case .fastingTonight: kind = .fasting; genericImmediate = 0; tradeoffs = ["Sin coste inmediato asumido por sí solo", "El efecto depende de si tu cuerpo responde bien o mal al ayuno, no de una regla general", "Entrenar en ayunas es una decisión aparte de esta"]
        case .poorHydration: kind = .lowHydration; genericImmediate = -2; tradeoffs = ["Cautela inmediata ya aplicada en el gemelo (-2 pt, -5 si se combina con alcohol o sauna)", "Fácil de corregir hoy mismo — no es un coste irreversible", "Electrolitos solo mitigan si hay otro estresor real registrado"]
        case .sauna: kind = .sauna; genericImmediate = 0; tradeoffs = ["Sin coste inmediato asumido por sí solo", "El efecto depende de tu propia respuesta aprendida, no de una regla general", "Hidratación después es lo que más influye en cómo lo lleva tu cuerpo"]
        default: kind = .fasting; genericImmediate = 0; tradeoffs = []
        }
        let association = associations.first { $0.kind == kind }
        let hasConfidentLearning = association.map { $0.confidence.level != .low && $0.direction != .neutral } ?? false
        let learnedImpact = association.map(HabitAssociationEngine.readinessImpact) ?? 0
        let tomorrow = min(100, max(0, assessment.score + genericImmediate + learnedImpact))

        let headline: String
        if tomorrow >= 70 { headline = "Mañana seguirías con buena disponibilidad" }
        else if tomorrow >= 50 { headline = "Mañana convendría ajustar la intensidad" }
        else { headline = "Mañana probablemente tocaría recuperar" }

        let performanceExpectation: String
        if let association, hasConfidentLearning {
            let effects = association.effects.map { "\($0.name) \($0.changePercent >= 0 ? "+" : "")\($0.changePercent.formatted(.number.precision(.fractionLength(0))))%" }.joined(separator: ", ")
            performanceExpectation = "Según tus propios \(association.samples) episodios registrados, esto suele mover: \(effects). Ya incorporado en la proyección de mañana."
        } else if let association {
            performanceExpectation = "Todavía sin suficiente confianza en tu patrón personal (\(association.samples) episodio(s) registrados) — la proyección usa solo el ajuste general que ya aplica éter, no un efecto aprendido."
        } else {
            performanceExpectation = "Sin episodios registrados todavía de esto — la proyección usa solo el ajuste general que ya aplica éter. Regístralo unas veces en Factores de estilo de vida para que éter aprenda tu respuesta real."
        }

        let sampleCount = association?.samples ?? 0
        let confidence = association?.confidence.level ?? ConfidenceEngine.level(score: 0)
        let trajectory = projectTrajectory(
            tomorrowReadiness: tomorrow, projectedAcuteLoad: performance.acuteLoad, projectedChronicLoad: performance.habitualLoad, days: 4,
            futureLoads: forwardPlanLoads(health: health, imports: imports, checkIn: checkIn, now: now, count: 3)
        )
        let explanation = "Parte de tu disponibilidad actual (\(assessment.score)/100)" +
            (genericImmediate != 0 ? " y aplica la misma cautela inmediata que el gemelo ya usaría (\(genericImmediate) pt)" : "") +
            (hasConfidentLearning ? ", más tu efecto personal aprendido (\(learnedImpact >= 0 ? "+" : "")\(learnedImpact) pt sobre \(sampleCount) episodios)." : ".")

        return DecisionSimulation(
            decision: decision, addedLoad: 0, projectedAcuteLoad: performance.acuteLoad, projectedRatio: performance.loadRatio,
            tomorrowReadiness: tomorrow, headline: headline, explanation: explanation,
            performanceExpectation: performanceExpectation, tradeoffs: tradeoffs, confidence: confidence, trajectory: trajectory
        )
    }

    /// `futureLoads[0]` is the assumed training-stress added on day 2 of the
    /// trajectory (day 1 is "tomorrow", already fixed by `tomorrowReadiness`/
    /// `projectedAcuteLoad` above), `futureLoads[1]` on day 3, and so on.
    /// Left empty (the default), every future day assumes zero added load —
    /// the original behavior, preserved exactly: with `dayLoad: 0`,
    /// `stepWeeklyEquivalent` reduces to the same plain exponential decay
    /// this used to do inline, so existing callers see no change. Passing
    /// the actual forward plan's assumed loads here is what makes "what
    /// happens if I do X today" account for the fact that training doesn't
    /// stop the day after — it keeps following whatever the plan for day 3,
    /// 4, 5... actually recommends, instead of quietly assuming full rest.
    nonisolated static func projectTrajectory(tomorrowReadiness: Int, projectedAcuteLoad: Double,
                                               projectedChronicLoad: Double, days: Int,
                                               futureLoads: [Double] = []) -> [DecisionProjectionDay] {
        guard days > 0 else { return [] }
        var readiness = min(100, max(0, tomorrowReadiness))
        var acute = max(0, projectedAcuteLoad)
        var chronic = max(0, projectedChronicLoad)
        return (1...days).map { day in
            if day > 1 {
                let addedLoad = futureLoads.count >= day - 1 ? futureLoads[day - 2] : 0
                acute = PerformanceEngine.stepWeeklyEquivalent(acute, dayLoad: addedLoad, timeConstant: 7)
                chronic = PerformanceEngine.stepWeeklyEquivalent(chronic, dayLoad: addedLoad, timeConstant: 28)
                let ratio = chronic > 0 ? acute / chronic : 0
                let recovery = readiness < 55 ? 7 : readiness < 75 ? 5 : 3
                // Only a real assumed session should cost readiness — a rest
                // day (addedLoad 0) keeps the original pure-recovery bump.
                let fatigueFromLoad = addedLoad > 45 ? 6 : addedLoad > 25 ? 3 : 0
                let residualPenalty = ratio >= 1.55 ? 4 : ratio >= 1.30 ? 2 : 0
                readiness = min(100, max(0, readiness + recovery - fatigueFromLoad - residualPenalty))
            }
            let ratio = chronic > 0 ? acute / chronic : 0
            let guidance = readiness < 50 || ratio >= 1.55 ? "Recuperar"
                : readiness < 65 || ratio >= 1.30 ? "Suave o menor volumen"
                : "Reevaluar sesión prevista"
            return DecisionProjectionDay(day: day, readiness: readiness, acuteLoad: acute, loadRatio: ratio, guidance: guidance)
        }
    }

    // The trajectory's day 1 ("mañana") already reflects the hypothetical
    // decision being simulated via tomorrowReadiness/projectedAcuteLoad
    // above — but days 2+ used to assume total rest from then on, which is
    // exactly the gap flagged: "la gente no vive solo con el hoy". This
    // pulls the *actual recommended forward plan* (weekAhead, day+2
    // onward) instead, so day 3/4/5 of the trajectory assume training
    // continues the way éter would actually recommend it, not silence.
    // Note this draws from the real plan's own day+2.. path, not a version
    // re-derived for this specific hypothetical decision — a deliberate
    // simplification: what changes with the decision is the acute/chronic
    // starting point (already reflected above), not what gets recommended
    // several days out.
    private static func forwardPlanLoads(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?, now: Date, count: Int) -> [Double] {
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: checkIn, now: now, days: min(7, count + 2))
        guard week.count > 2 else { return [] }
        return week.dropFirst(2).prefix(count).map { TrainingPlanEngine.forecastSessionLoad($0.kind) }
    }

    // MARK: - Personal-history load & pace helpers

    // Not `private`: EngineTests exercises these directly, the same way it
    // already tests PersonalReadinessAnchor.derive/TwinCalibration.derive as
    // pure functions rather than only through the full `simulate` integration.
    struct HistoricalLoad: Equatable {
        let load: Double
        let sessions: Int
        let isPersonal: Bool
    }

    static func qualifyingRuns(_ workouts: [HealthWorkout], matching predicate: (HealthWorkout) -> Bool, now: Date) -> [HealthWorkout] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: now) ?? .distantPast
        return workouts.filter { $0.activity == "Carrera" && $0.date >= cutoff && $0.date <= now && predicate($0) }
    }

    /// Median load of the matched sessions using the exact per-minute weighting
    /// PerformanceEngine already uses for real daily load history — the same
    /// number this decision would actually contribute if it happened today.
    /// Falls back to a flat estimate, clearly marked as non-personal, only when
    /// fewer than two matching sessions exist.
    static func historicalLoad(_ workouts: [HealthWorkout], cardioFactor: Double, fallback: Double) -> HistoricalLoad {
        guard workouts.count >= 2 else { return HistoricalLoad(load: fallback, sessions: workouts.count, isPersonal: false) }
        let loads = workouts.map { $0.durationMinutes * cardioFactor }
        return HistoricalLoad(load: median(loads), sessions: workouts.count, isPersonal: true)
    }

    /// A deliberately modest, disclosed heuristic — not a validated pace-prediction
    /// model. Anchors on the user's own median pace for this session type, then
    /// nudges it by the same readiness bands StrengthPrescriptionEngine already
    /// uses for load, translated to a pace direction (lower readiness → slower).
    static func paceExpectation(_ workouts: [HealthWorkout], readiness: Int, label: String, basis: HistoricalLoad) -> String {
        let paces = workouts.compactMap { workout -> Double? in
            guard let km = workout.distanceKilometers, km > 0.5 else { return nil }
            return workout.durationMinutes / km
        }
        guard paces.count >= 2 else {
            return "Sin suficientes sesiones de \(label) con distancia registrada para estimar un ritmo propio todavía."
        }
        let base = median(paces)
        let factor: Double
        if readiness < 45 { factor = 1.08 }
        else if readiness < 60 { factor = 1.04 }
        else if readiness >= 84 { factor = 0.985 }
        else { factor = 1.0 }
        let expected = base * factor
        let note = factor > 1.0 ? "algo más conservador que tu mediana por tu disponibilidad de hoy" : factor < 1.0 ? "cerca de tu mejor rango habitual" : "en línea con tu mediana habitual"
        return "Ritmo esperado hoy ≈ \(formatPace(expected)) min/km (\(note); tu mediana en \(label) es \(formatPace(base)) min/km sobre \(basis.sessions) sesiones)."
    }

    static func formatPace(_ minutesPerKm: Double) -> String {
        let totalSeconds = Int((minutesPerKm * 60).rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
