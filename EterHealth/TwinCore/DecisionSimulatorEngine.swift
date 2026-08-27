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
    // TwinCore: profile/events/reviews/activeInjuries/calibration/
    // personalAnchor used to come from GoalStore/LifestyleFactorStore/
    // WorkoutReviewStore/InjuryStore/TwinStateStore singleton instances,
    // needed here both directly (TwinEngine.assess below) and via
    // forwardPlanLoads' own call into TrainingPlanEngine.weekAhead.
    // PR17: `travelHistory` va igual de explícito que `travel`. Sin él, este
    // simulador construía su TwinContext con el historial vacío, así que
    // TravelLearningEngine caía al prior: la tarjeta de hoy proyectaba con TUS
    // tasas medidas y el simulador con las de la literatura, sobre el mismo
    // viaje. Mismo fallo de dos-motores que PR15 vino a cerrar, un nivel más
    // abajo.
    //
    // PR15: `travel` es un parámetro explícito y no un default. Esta función
    // construye su propio TwinContext desde los seis parámetros sueltos (ver
    // el comentario de abajo), así que un `travel` con default nil habría
    // dejado al simulador ciego al viaje: diría que un HIIT sale gratis
    // mientras el plan lo está limitando. Es el único sitio del pipeline que
    // no hereda TwinContext del call site, y por tanto el único que podía
    // desincronizarse en silencio.
    static func simulate(_ decision: SimulatedDecision, health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                        profile: AthletePlanProfile, events: [LifestyleEvent], reviews: [WorkoutReview],
                        activeInjuries: [InjuryRecord], calibration: TwinCalibration, personalAnchor: PersonalReadinessAnchor,
                        travel: TravelEpisode?, travelHistory: [TravelEpisode], now: Date = Date()) -> DecisionSimulation {
        if decision.isLifestyle {
            return simulateLifestyle(decision, health: health, imports: imports, checkIn: checkIn,
                                     profile: profile, events: events, reviews: reviews, activeInjuries: activeInjuries,
                                     calibration: calibration, personalAnchor: personalAnchor,
                                     travel: travel, travelHistory: travelHistory, now: now)
        }
        // PR1.5: assembled once and reused below for both the assess() call
        // and (via forwardPlanLoads) weekAhead — this function's own
        // external signature keeps the six separate parameters since
        // callers outside TwinCore already have them as six separate reads.
        let context = TwinContext(profile: profile, events: events, reviews: reviews,
                                  activeInjuries: activeInjuries, calibration: calibration,
                                  personalAnchor: personalAnchor, travel: travel, travelHistory: travelHistory)
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context, now: now)
        let added: Double
        let tradeoffs: [String]
        let performanceExpectation: String
        let basis: HistoricalLoad?

        switch decision {
        case .alcohol, .fastingTonight, .poorHydration, .sauna:
            fatalError("Lifestyle decisions are routed to simulateLifestyle above and never reach this switch")

        case .rest:
            added = 0; basis = nil
            tradeoffs = ["Más disponibilidad probable mañana", "No añade estímulo ni kilómetros", "Útil si hay dolor, enfermedad o fatiga acumulada"]
            performanceExpectation = "Sin sesión que valorar hoy — el beneficio se mide en la disponibilidad de mañana, no en un rendimiento."

        case .quality:
            // PR4: el mismo clasificador configurado que el plan, con la
            // evidencia real de este atleta. Antes esto compartía con el plan
            // una regla de kcal/min que confundía calor con intensidad, así
            // que "cuánto me costó una sesión de calidad" se calculaba sobre
            // un conjunto de sesiones mal etiquetado.
            let running = RunningPerformanceEngine.summarize(
                workouts: health.workoutHistory, zones: health.runningHeartRateZones,
                reviews: context.reviews, now: now)
            let matched = qualifyingRuns(health.recentWorkouts, matching: SessionClassification.qualityRunPredicate(
                reviews: context.reviews,
                thresholdPace: SessionClassification.thresholdPaceSecondsPerKm(fiveK: running.fiveK, tenK: running.tenK),
                thresholdHeartRate: health.currentHeartRateZoneBoundaries().map { Double($0.z3z4) }
            ), now: now)
            let load = historicalLoad(matched, cardioFactor: PerformanceEngine.cardioFactor("Carrera"), fallback: 78)
            basis = load; added = load.load
            tradeoffs = ["Aporta estímulo de velocidad o umbral", "Eleva la carga cardiovascular aguda", "Probablemente desplaza mañana hacia descanso o tren superior"]
            performanceExpectation = paceExpectation(matched, readiness: assessment.score, label: "intervalos", basis: load)

        case .longRun:
            let matched = qualifyingRuns(health.recentWorkouts, matching: TrainingPlanEngine.isLongRun, now: now)
            let load = historicalLoad(matched, cardioFactor: PerformanceEngine.cardioFactor("Carrera"), fallback: 75)
            basis = load; added = load.load
            tradeoffs = ["Construye resistencia aeróbica y tolerancia de tiempo en pie", "Coste de recuperación alto por duración, no por intensidad", "Probablemente desplaza mañana hacia descanso o trabajo suave"]
            performanceExpectation = paceExpectation(matched, readiness: assessment.score, label: "tirada larga", basis: load)

        case .strength:
            let matched = imports.workouts.filter { $0.start <= now && now.timeIntervalSince($0.start) <= 120 * 86_400 }
            let loads = matched.map { workout in Double(workout.exercises.reduce(0) { $0 + $1.sets }) * 3 }
            let load = HistoricalLoad(load: loads.isEmpty ? 42 : median(loads), sessions: matched.count, isPersonal: matched.count >= 2)
            basis = load; added = load.load
            tradeoffs = ["Mantiene empuje y tirón sin cargar tanto las piernas", "Compatible con prioridad de running", "La fatiga local depende de series y proximidad al fallo"]
            let factor = StrengthPrescriptionEngine.readinessLoadFactor(assessment.score)
            let pct = Int((factor * 100).rounded())
            performanceExpectation = factor >= 1
                ? "Tu disponibilidad de hoy (\(assessment.score)/100) permite mantener o progresar ligeramente la carga habitual (~\(pct)% de tu referencia)."
                : "Con tu disponibilidad de hoy (\(assessment.score)/100), esperable prescribir ~\(pct)% de tu carga habitual — no es el día para buscar un máximo."
        }

        // El reparto por canal sale de overrideSessionKind, que ya mapea cada
        // decisión a su tipo de sesión — no una segunda tabla.
        let addedDual = DualLoad.split(total: added, kind: decision.overrideSessionKind ?? .recovery)
        let projectedAcute = performance.dual.projectedAcute(adding: addedDual)
        let projectedChronicDual = performance.dual.projectedHabitual(adding: addedDual)
        let ratio = performance.dual.projectedGoverningRatio(adding: addedDual)

        // Una sola fisiología. Esto era una segunda: constantes de fatiga y
        // recuperación por tipo de decisión (14/10/6 para calidad, 8/5/3 para
        // fuerza, +7 para descanso) más una penalización propia por ratio,
        // todo aplicado a mano sobre la puntuación de hoy. Ahora la decisión
        // se convierte en carga, la carga pasa por step() y la disponibilidad
        // sale de TwinReadout — el mismo camino exacto que usan
        // TwinStateStore.predictedTomorrow y el weekAhead del plan.
        //
        // El bonus de recuperación de un día de descanso ya no se declara:
        // emerge de que step() decae la fatiga sin añadir carga nueva.
        let tomorrowPhysiology = step(assessment.physiology, session: addedDual, recoverySignals: .none, dtDays: 1)
        // El DELTA que predice el modelo, aplicado a la disponibilidad real de
        // hoy — no el valor absoluto de TwinReadout, que está anclado en la
        // mediana personal y es OTRA escala. Tomarlo directo hacía que
        // "descansar" se mostrara como 60 -> 49: no era una predicción, era un
        // cambio de escala, y encima el copy seguía diciendo "parte de tu
        // disponibilidad actual (60/100)". Un día de descanso no puede costar
        // 11 puntos.
        //
        // Misma decisión que projectTrajectory: el nivel lo fija la
        // puntuación real, la forma la da step().
        let todayReadout = TwinReadout.derive(from: assessment.physiology, anchor: context.personalAnchor,
                                              calibration: context.calibration).score
        let tomorrowReadout = TwinReadout.derive(from: tomorrowPhysiology, anchor: context.personalAnchor,
                                                 calibration: context.calibration).score
        let tomorrow = min(100, max(0, assessment.score + tomorrowReadout - todayReadout))
        let headline: String
        if tomorrow >= 70 { headline = "Mañana seguirías con buena disponibilidad" }
        else if tomorrow >= 50 { headline = "Mañana convendría ajustar la intensidad" }
        else { headline = "Mañana probablemente tocaría recuperar" }

        let sampleCount = health.recentWorkouts.count + imports.workoutCount
        var evidenceScore = min(100, Int((Double(sampleCount) / 25 * 55).rounded()) + Int((Double(assessment.baselineConfidence) * 0.45).rounded()))
        if let basis, !basis.isPersonal { evidenceScore = min(evidenceScore, 35) }
        let confidence = ConfidenceEngine.level(score: evidenceScore)

        // El crónico proyectado se calcula, ya no se reconstruye dividiendo
        // el agudo por el ratio (que además se caía al habitual cuando el
        // ratio era 0).
        let trajectory = projectTrajectory(
            tomorrowReadiness: tomorrow, projectedAcuteLoad: projectedAcute,
            projectedChronicLoad: projectedChronicDual, days: 4,
            physiology: tomorrowPhysiology, anchor: context.personalAnchor, calibration: context.calibration,
            futureLoads: forwardPlanLoads(health: health, imports: imports, checkIn: checkIn, context: context, now: now, count: 3)
        )
        let explanation = basis.map { basis in
            basis.isPersonal
                ? "Parte de tu disponibilidad actual (\(assessment.score)/100) y suma la carga mediana de tus últimas \(basis.sessions) sesiones reales de este tipo."
                : "Parte de tu disponibilidad actual (\(assessment.score)/100). Aún sin suficiente historial de este tipo de sesión (\(basis.sessions) registrada(s)): usa una carga típica provisional en su lugar."
        } ?? "Parte de tu disponibilidad actual (\(assessment.score)/100) y aplica una respuesta de recuperación conservadora."

        return DecisionSimulation(
            decision: decision, addedLoad: added, projectedAcuteLoad: projectedAcute.combined, projectedRatio: ratio,
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
    private static func simulateLifestyle(_ decision: SimulatedDecision, health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                                          profile: AthletePlanProfile, events: [LifestyleEvent], reviews: [WorkoutReview],
                                          activeInjuries: [InjuryRecord], calibration: TwinCalibration, personalAnchor: PersonalReadinessAnchor,
                                          travel: TravelEpisode?, travelHistory: [TravelEpisode], now: Date = Date()) -> DecisionSimulation {
        let context = TwinContext(profile: profile, events: events, reviews: reviews,
                                  activeInjuries: activeInjuries, calibration: calibration,
                                  personalAnchor: personalAnchor, travel: travel, travelHistory: travelHistory)
        let performance = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context, now: now)
        let associations = HabitAssociationEngine.analyze(
            events: events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory, sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory,
            deepShare: SleepArchitectureEngine.dailyDeepShareSeries(health.sleepStagesHistory),
            remShare: SleepArchitectureEngine.dailyRemShareSeries(health.sleepStagesHistory),
            sleepSchedule: health.sleepScheduleHistory, now: now
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
        // Base: el mañana que el gemelo ya predice para hoy (predictedTomorrow,
        // que es step() con la sesión que el plan propone). Antes esto partía
        // de la puntuación de HOY, que es otra cantidad: un efecto aprendido
        // sobre "mañana" tiene que aplicarse sobre el mañana previsto, no
        // sobre el hoy medido.
        //
        // El delta aprendido NO pasa por step() a propósito: "2 cervezas" no
        // es una carga y no hay forma honesta de expresarla como tal.
        // HabitAssociationEngine lo mide como puntos de disponibilidad sobre
        // evidencia personal, y así se aplica.
        let tomorrow = min(100, max(0, assessment.predictedTomorrow.score + genericImmediate + learnedImpact))

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
            tomorrowReadiness: tomorrow, projectedAcuteLoad: performance.dual.acuteChannels,
            projectedChronicLoad: performance.dual.habitualChannels, days: 4,
            // El estado de mañana del propio gemelo: una decisión de estilo de
            // vida no cambia la sesión de hoy, así que la trayectoria evoluciona
            // desde ahí, con el delta aprendido ya aplicado al nivel del día 1.
            physiology: step(assessment.physiology, session: .none, recoverySignals: .none, dtDays: 1),
            anchor: context.personalAnchor, calibration: context.calibration,
            futureLoads: forwardPlanLoads(health: health, imports: imports, checkIn: checkIn, context: context, now: now, count: 3)
        )
        let explanation = "Parte de tu disponibilidad actual (\(assessment.score)/100)" +
            (genericImmediate != 0 ? " y aplica la misma cautela inmediata que el gemelo ya usaría (\(genericImmediate) pt)" : "") +
            (hasConfidentLearning ? ", más tu efecto personal aprendido (\(learnedImpact >= 0 ? "+" : "")\(learnedImpact) pt sobre \(sampleCount) episodios)." : ".")

        return DecisionSimulation(
            decision: decision, addedLoad: 0, projectedAcuteLoad: performance.acuteLoad,
            projectedRatio: performance.dual.governingRatio,
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
    // PR3c: acute/chronic duales y el ratio que gobierna, el mismo que el
    // gate del plan. Con el ratio combinado, la trayectoria podía proyectar
    // "reevaluar sesión prevista" para un día que status() habría mandado a
    // recuperar, porque el pico de un canal quedaba diluido por el otro.
    /// `physiology` es el estado de mañana ya calculado por el llamante (la
    /// decisión aplicada vía step()). La FORMA de la trayectoria sale de
    /// evolucionar ese estado con step(), no de una fórmula propia — el NIVEL
    /// lo sigue fijando `tomorrowReadiness`, porque el día 1 puede venir de
    /// algo que step() no modela: el efecto personal aprendido de una decisión
    /// de estilo de vida ("2 cervezas") no es una carga y no hay forma honesta
    /// de expresarlo como tal. Así que los días 2+ aplican el DELTA que el
    /// propio modelo predice sobre ese nivel, en vez de reinventar cuánto se
    /// recupera cada día.
    nonisolated static func projectTrajectory(tomorrowReadiness: Int, projectedAcuteLoad: DualLoad,
                                               projectedChronicLoad: DualLoad, days: Int,
                                               // Obligatorio, sin valor por defecto: con un nil
                                               // la trayectoria se quedaría congelada sin que
                                               // nada avisara, que es peor que no tenerla.
                                               physiology: TwinPhysiology,
                                               anchor: PersonalReadinessAnchor,
                                               calibration: TwinCalibration,
                                               futureLoads: [DualLoad] = []) -> [DecisionProjectionDay] {
        guard days > 0 else { return [] }
        var readiness = min(100, max(0, tomorrowReadiness))
        var state = physiology
        // Referencia del día 1 en la escala del modelo, para poder aplicar
        // deltas sin arrastrar la diferencia de nivel entre esa escala y la
        // puntuación real/aprendida que fija el día 1.
        let baseline = TwinReadout.derive(from: state, anchor: anchor, calibration: calibration).score
        var acute = DualLoad(aerobic: max(0, projectedAcuteLoad.aerobic), strength: max(0, projectedAcuteLoad.strength))
        var chronic = DualLoad(aerobic: max(0, projectedChronicLoad.aerobic), strength: max(0, projectedChronicLoad.strength))
        return (1...days).map { day in
            if day > 1 {
                let addedLoad = futureLoads.count >= day - 1 ? futureLoads[day - 2] : .none
                acute = DualLoad(aerobic: PerformanceEngine.stepWeeklyEquivalent(acute.aerobic, dayLoad: addedLoad.aerobic, timeConstant: 7),
                                 strength: PerformanceEngine.stepWeeklyEquivalent(acute.strength, dayLoad: addedLoad.strength, timeConstant: 7))
                chronic = DualLoad(aerobic: PerformanceEngine.stepWeeklyEquivalent(chronic.aerobic, dayLoad: addedLoad.aerobic, timeConstant: 28),
                                   strength: PerformanceEngine.stepWeeklyEquivalent(chronic.strength, dayLoad: addedLoad.strength, timeConstant: 28))
                // Esto era la SEGUNDA copia de la fórmula que el PR2 quitó de
                // ForwardState.apply: mismo bonus por recuperación, misma
                // fatiga por carga, misma penalización por ratio. Se aplicó el
                // arreglo en un sitio y se dejó en el otro. Ahora el estado
                // evoluciona con step() y la disponibilidad sale del delta que
                // TwinReadout predice, no de constantes propias.
                state = step(state, session: addedLoad, recoverySignals: .none, dtDays: 1)
                let projected = TwinReadout.derive(from: state, anchor: anchor, calibration: calibration).score
                readiness = min(100, max(0, tomorrowReadiness + projected - baseline))
            }
            let ratio = DualLoad.governingRatio(acute: acute, habitual: chronic)
            let guidance = readiness < 50 || ratio >= 1.55 ? "Recuperar"
                : readiness < 65 || ratio >= 1.30 ? "Suave o menor volumen"
                : "Reevaluar sesión prevista"
            return DecisionProjectionDay(day: day, readiness: readiness, acuteLoad: acute.combined, loadRatio: ratio, guidance: guidance)
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
    private static func forwardPlanLoads(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                                         context: TwinContext, now: Date, count: Int) -> [DualLoad] {
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: checkIn,
                                                context: context, now: now, days: min(7, count + 2))
        guard week.count > 2 else { return [] }
        return week.dropFirst(2).prefix(count).map { DualLoad.ratioLoad($0.kind) }
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
