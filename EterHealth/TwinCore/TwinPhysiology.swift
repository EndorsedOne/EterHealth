import Foundation

// PR2: the gemelo's real state, evolved day to day — not reconstructed from
// scratch as an additive score every time assess() runs. TwinReadout.score
// below is a DERIVED summary of this state for the UI (Hoy still shows a
// single 0–100 number and its TwinSignal breakdown, unchanged), never fed
// back into TrainingPlanEngine as an input itself.
//
// Same two-compartment fitness/fatigue shape TrainingScenarioEngine's own
// Banister-style model already uses for "Tres futuros" — fatigue clears
// faster than fitness builds, a documented heuristic tradeoff, not a new
// invented model. τ values below are that same heuristic, split into an
// aerobic and a strength channel instead of TrainingScenarioEngine's single
// population-pace one.
//
// Three layers, not two: this struct is canonical PHYSIOLOGY only —
// fitness/fatigue and per-muscle FATIGUE, nothing else. TwinReadout is the
// separate derived score/confidence layer. Weekly training VOLUME/HISTORY
// per muscle (recentSets, lastTrained — what bestStrengthPattern's MEV/MAV/
// MRV logic needs) is a third, distinct layer that intentionally does NOT
// live here: it isn't canonical physiology, and folding it in would let a
// single struct silently mix "how tired is this muscle" with "how much has
// it actually been trained this week", two different questions with two
// different lifetimes (fatigue decays in hours/days; weekly volume resets
// on a training-week cadence). TrainingPlanEngine.status/weekAhead/
// balancedDecision still take that third layer as a plain
// [MuscleReadiness] array (a real compatibility shape, not the final
// target — see their own call sites) rather than a named
// MuscleTrainingContext type; the eventual, non-mixed shape the plan
// should read is TwinPhysiology + TwinReadout + a MuscleTrainingContext
// (or the current [MuscleReadiness]) passed as its own, separate
// parameter — never merged into this one. Do not add recentSets/
// lastTrained to TwinPhysiology to "simplify" a call site.
struct TwinPhysiology: Equatable {
    var fitnessAerobic: Double       // EWMA semanal-equivalente, τ ≈ 42 días
    var fatigueAerobic: Double       // τ ≈ 7 días
    var fitnessStrength: Double      // τ ≈ 28 días
    var fatigueStrength: Double      // τ ≈ 5 días
    // 0 (fresco) ... 100 (totalmente fatigado) — fatiga, no readiness; el
    // signo contrario a MuscleReadiness.readiness a propósito, para no
    // confundir "estado interno" con "lectura para la UI". La fuente real
    // sigue siendo TwinEngine.calculateMuscles: TwinPhysiology.derive(...)
    // abajo simplemente convierte su mismo resultado, no lo recalcula.
    // step() sólo decae este valor para proyectar hacia delante cuando no
    // hay historial real de ejercicios (p.ej. la predicción de mañana).
    var muscleFatigue: [String: Double]
    // Desviación autonómica MEDIDA hoy, con el mismo signo favorable que usa
    // PersonalMetricBaseline: positivo = mejor que tu línea base. 0 significa
    // "en tu base, o sin medición", nunca "malo".
    //
    // Por qué está en el estado y no sólo en la lectura: un HRV hundido hoy
    // dice que arrastras más fatiga de la que la carga explica, y eso es
    // información sobre el estado actual. Sigue siendo cierto que el HRV de
    // MAÑANA no se puede conocer (ver TwinEngine, donde predictedTomorrow pasa
    // RecoverySignals.none a propósito) — y por eso step() no lo asume
    // constante: lo decae hacia la base, igual que hace con sleepDebtHours.
    // Proyectar una medición que decae no es inventar un dato; asumir que la
    // supresión de hoy dura para siempre sí lo sería.
    // Con valor por defecto (mismo patrón que HealthWorkout.maxHeartRate): 0
    // es "en tu base, o sin medición", así que los sitios que no tienen
    // opinión sobre el HRV no tienen que fingir una.
    var hrvDeviation: Double = 0
    var restingHeartRateDeviation: Double = 0
    var sleepDebtHours: Double
    var illness: Bool
    // PR15: viaje. Los dos son ESTADO fisiológico que decae, que es
    // exactamente la forma que ya tienen hrvDeviation y sleepDebtHours arriba
    // — y por la misma razón viven aquí y no en el episodio: el episodio es
    // calendario (fechas, husos, vuelos) y no decae; esto sí.
    //
    // Lo que NO se hace, y es la decisión importante: no se suman a
    // fatigueAerobic ni a fatigueStrength. Un vuelo no es entrenamiento, y
    // meterlo en esos canales corrompería el ratio agudo:crónico —
    // exceedsPaceCeiling leería que has entrenado y mandaría a recuperación
    // por una carga que nunca ocurrió— además de inflar la fitness de un
    // canal por haber cogido un avión.
    //
    // CON SIGNO: positivo = falta adelantar fase (se viajó al este), negativo
    // = falta retrasarla (al oeste). El signo es lo que permite que step()
    // decaiga a la tasa correcta sin conocer el episodio; ver
    // CircadianReentrainment. Con default 0 (= "en hora, o sin viaje") por el
    // mismo patrón que hrvDeviation: quien no tiene opinión sobre el viaje no
    // tiene que fingir una.
    var circadianOffsetHours: Double = 0
    /// 0 … 1. Fatiga aguda de tránsito, no carga de entrenamiento.
    var travelFatigue: Double = 0
    var asOf: Date

    static func baseline(asOf: Date) -> TwinPhysiology {
        TwinPhysiology(fitnessAerobic: 0, fatigueAerobic: 0, fitnessStrength: 0, fatigueStrength: 0,
                       muscleFatigue: [:], hrvDeviation: 0, restingHeartRateDeviation: 0,
                       sleepDebtHours: 0, illness: false,
                       circadianOffsetHours: 0, travelFatigue: 0, asOf: asOf)
    }
}

// DERIVADO, no input del plan — ver el comentario de TwinPhysiology arriba.
struct TwinReadout: Equatable {
    var score: Int
    var state: String
    var confidence: Int

    // Un único sitio para las cuatro bandas Preparado/Disponible/Carga
    // moderada/Recuperación prioritaria — TwinEngine.assess las usaba
    // inline; ahora las llama desde aquí para no tener dos copias del
    // mismo umbral.
    static func label(for score: Int) -> String {
        score >= 80 ? "Preparado" : score >= 62 ? "Disponible" : score >= 45 ? "Carga moderada" : "Recuperación prioritaria"
    }
}

// Separa cardio y fuerza, tal y como pide el brief de PR2 — PR3 rellenará
// los dos canales con un historial dual EWMA completo (DualLoadSummary);
// por ahora cada sesión real solo aporta a UNO de los dos canales según su
// tipo (ver `forecast(_:)` abajo), no una mezcla inventada.
// PR3b: SessionLoad y DualLoad eran la misma forma con dos nombres —
// exactamente la clase de duplicado que el brief prohíbe. Un solo tipo, y
// este nombre se queda porque es el que lee step() en su firma.
typealias SessionLoad = DualLoad


// Lo que step() necesita para mover el estado de hoy a mañana que no está
// ya en fitness/fatiga — los mismos tipos de señal que TwinEngine.assess ya
// lee para la puntuación de hoy, agrupados para que predecir mañana pueda
// reusar la misma forma de entrada en vez de una segunda lista de parámetros.
// Todos opcionales: nil significa "sin información nueva para este paso",
// no "cero" — importante para predecir mañana, donde no se conoce todavía
// el HRV o el sueño reales del día siguiente.
struct RecoverySignals {
    var hrvDeviation: Double?
    var restingHeartRateDeviation: Double?
    var sleepDeficitHours: Double?
    var checkIn: DailyCheckIn?
    var physiologicalAlert: PhysiologicalAlert?
    // PR15: el estado de viaje recalculado para ESTE paso, cuando lo hay.
    // Mismo contrato que hrvDeviation: un valor es información nueva y manda;
    // nil significa "sin información nueva de viaje para este paso", y
    // entonces step() decae el estado que ya había — no lo borra ni lo
    // congela. Es lo que permite que la predicción de mañana arrastre el
    // desajuste de hoy perdiendo el día que corresponde.
    var travel: TravelImpact?

    static let none = RecoverySignals(hrvDeviation: nil, restingHeartRateDeviation: nil,
                                      sleepDeficitHours: nil, checkIn: nil,
                                      physiologicalAlert: nil, travel: nil)
}

// Pura: el mismo (state, session, recoverySignals, dtDays) siempre produce
// el mismo estado siguiente — sin leer stores, sin Date(), sin
// aleatoriedad. El único sitio por el que pasan tanto la predicción de
// TwinStateStore como la evolución de fitness/fatiga/readiness día a día
// de TrainingPlanEngine.weekAhead's ForwardState.apply(...), para que
// esas dos proyecciones nunca puedan divergir en silencio.
//
// Dos límites deliberados de ese "nunca divergir", ambos documentados en
// su propio sitio, no aquí por descuido:
// 1. El ratio agudo:crónico que decide exceedsPaceCeiling (el gate real
//    de "hoy toca descanso") sigue viviendo en ForwardState.acute/chronic,
//    el EWMA de un solo canal combinado de siempre — separar ESE ratio en
//    canales aeróbico/fuerza es el trabajo de PR3 (DualLoad), no algo que
//    step() resuelva por su cuenta.
// 2. muscleFatigue en la salida de step() se descarta y se sustituye por
//    el propio tracker de weekAhead (real, por ejercicio, vía
//    MuscleMap.involvement) siempre que hay uno disponible — la decaída
//    genérica de aquí abajo es solo el resultado honesto para cuando no
//    hay ese detalle (la predicción de mañana de TwinStateStore).
func step(_ state: TwinPhysiology, session: SessionLoad?, recoverySignals: RecoverySignals, dtDays: Double,
          rates: ReentrainmentRates = .prior) -> TwinPhysiology {
    let load = session ?? .none

    // Misma forma que PerformanceEngine.stepWeeklyEquivalent (el "current"
    // guardado es un equivalente semanal; el paso trabaja sobre su media
    // diaria), generalizada para dtDays ≠ 1 — weekAhead y la predicción de
    // mañana llaman a esto con dtDays: 1 casi siempre, pero el tipo no
    // fuerza esa suposición.
    func advance(_ current: Double, dayLoad: Double, timeConstant: Double) -> Double {
        guard timeConstant > 0, dtDays > 0 else { return current }
        let alpha = 1 - exp(-dtDays / timeConstant)
        let average = current / 7
        let nextAverage = average + alpha * (dayLoad - average)
        return max(0, nextAverage * 7)
    }

    let fitnessAerobic = advance(state.fitnessAerobic, dayLoad: load.aerobic, timeConstant: 42)
    let fatigueAerobic = advance(state.fatigueAerobic, dayLoad: load.aerobic, timeConstant: 7)
    let fitnessStrength = advance(state.fitnessStrength, dayLoad: load.strength, timeConstant: 28)
    let fatigueStrength = advance(state.fatigueStrength, dayLoad: load.strength, timeConstant: 5)

    // Una SessionLoad escalar no sabe qué músculos concretos trabajó la
    // sesión — el aumento real de fatiga por músculo sigue viniendo de
    // TwinEngine.calculateMuscles (la fuente única) cuando hay historial de
    // ejercicios real, como en weekAhead's propio applyMuscleLoad/
    // applyStrengthLoad. Aquí, sin ese detalle, cada músculo solo decae
    // hacia fresco con la misma vida media por defecto que
    // TrainingPlanEngine.weekAhead ya usa cuando no hay una tasa de
    // recuperación aprendida para ese músculo.
    let defaultHalfLifeDays = 1.5
    let decay = pow(0.5, dtDays / defaultHalfLifeDays)
    let muscleFatigue = state.muscleFatigue.mapValues { max(0, $0 * decay) }

    // Misma regla que el sueño de abajo: una medición nueva manda, y sin ella
    // la desviación de hoy decae hacia la base con la misma vida media por
    // defecto que la fatiga muscular. Una supresión autonómica se resuelve en
    // horas o días, no se queda fija; y proyectarla como constante sería
    // afirmar un HRV futuro que nadie ha medido.
    let hrvDeviation = recoverySignals.hrvDeviation ?? state.hrvDeviation * decay
    let restingHeartRateDeviation = recoverySignals.restingHeartRateDeviation ?? state.restingHeartRateDeviation * decay

    let sleepDebtHours: Double
    if let deficit = recoverySignals.sleepDeficitHours {
        sleepDebtHours = max(0, deficit)
    } else {
        // Sin información nueva de sueño para este paso (p.ej. prediciendo
        // mañana sin saber aún cuánto se va a dormir) — la deuda se drena
        // gradualmente, como la iría pagando una noche de descanso normal.
        sleepDebtHours = max(0, state.sleepDebtHours - dtDays * 2)
    }

    // Información nueva sobre enfermedad manda sobre el estado anterior;
    // sin ella (checkIn nil, como al predecir mañana) la enfermedad de hoy
    // se mantiene tal cual — no desaparece sola de un día para otro sin que
    // nadie lo confirme, y una alerta "recover" de hoy trata mañana con la
    // misma cautela mientras no haya una señal nueva que la contradiga.
    let illness = recoverySignals.checkIn?.illness
        ?? (recoverySignals.physiologicalAlert?.severity == .recover ? true : nil)
        ?? state.illness

    // PR15: viaje. Una medición nueva del episodio manda (mismo contrato que
    // el HRV de arriba); sin ella, los dos estados decaen — cada uno con su
    // propio mecanismo, porque son dos fenómenos distintos:
    //
    //  · El desajuste circadiano decae LINEALMENTE a la tasa del prior, y la
    //    tasa depende del SIGNO: ~1 h/día si falta adelantar fase (este),
    //    ~1.5 h/día si falta retrasarla (oeste). Es la única razón por la que
    //    el escalar lleva signo, y lo que permite que step() lo decaiga
    //    correctamente sin saber nada del episodio ni de sus vuelos. Una
    //    exponencial aquí sería cambiar el fenómeno para que encaje con el
    //    resto del código: la literatura lo describe como horas de
    //    desplazamiento de fase por día, que es lineal por definición.
    //  · La fatiga de tránsito decae con la MISMA vida media por defecto que
    //    la fatiga muscular de arriba (1.5 días), reutilizada a propósito en
    //    vez de inventar una segunda constante parecida.
    let circadianOffsetHours: Double
    let travelFatigue: Double
    if let travel = recoverySignals.travel {
        circadianOffsetHours = travel.circadianOffsetHours
        travelFatigue = travel.travelFatigue
    } else {
        // PR16: las tasas aprendidas de este atleta cuando existen. Si el
        // decaimiento de aquí usara el prior mientras TravelImpactEngine
        // calcula el desajuste con la tasa aprendida, hoy y mañana
        // discreparían — el mismo fallo que este PR viene a cerrar, sólo que
        // desplazado un día.
        let rate = rates.hoursPerDay(forOffsetHours: state.circadianOffsetHours)
        let resolved = rate * dtDays
        let magnitude = max(0, abs(state.circadianOffsetHours) - resolved)
        circadianOffsetHours = state.circadianOffsetHours > 0 ? magnitude : -magnitude
        travelFatigue = max(0, state.travelFatigue * pow(0.5, dtDays / TravelImpactEngine.fatigueHalfLifeDays))
    }

    return TwinPhysiology(
        fitnessAerobic: fitnessAerobic, fatigueAerobic: fatigueAerobic,
        fitnessStrength: fitnessStrength, fatigueStrength: fatigueStrength,
        muscleFatigue: muscleFatigue, hrvDeviation: hrvDeviation,
        restingHeartRateDeviation: restingHeartRateDeviation,
        sleepDebtHours: sleepDebtHours, illness: illness,
        circadianOffsetHours: circadianOffsetHours, travelFatigue: travelFatigue,
        asOf: state.asOf.addingTimeInterval(dtDays * 86_400)
    )
}

extension TwinPhysiology {
    // "Hoy, real" — recalculado directamente del historial de carga
    // completo cada vez (la misma convención que ya usan
    // PerformanceEngine.summarize/ewmaWeeklyEquivalent), nunca avanzado con
    // step() desde un punto de partida arbitrario. step() es solo para
    // proyectar hacia delante desde esta base real.
    // @MainActor (not nonisolated like step() above): reads HealthStore/
    // ImportStore, which are themselves main-actor-isolated.
    @MainActor static func derive(health: HealthStore, imports: ImportStore, muscleReadiness: [MuscleReadiness],
                       hrvDeviation: Double = 0, restingHeartRateDeviation: Double = 0,
                       sleepDebtHours: Double, illness: Bool,
                       travel: TravelImpact = .none, now: Date = Date()) -> TwinPhysiology {
        // PR3: el mismo historial dual que PerformanceEngine.summarize usa.
        // Antes esto repetía aquí el bucle de separación aeróbico/fuerza
        // (mismo filtro de Hevy-espejado, mismo isStrengthWorkout, mismas
        // unidades) — dos copias de "qué cuenta como fuerza" que podían
        // divergir sin que nada avisara.
        let history = PerformanceEngine.dailyDualHistory(health: health, imports: imports, days: 84, now: now)
        let aerobicLoads = history.map(\.aerobic)
        let strengthLoads = history.map(\.strength)

        return TwinPhysiology(
            fitnessAerobic: PerformanceEngine.ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 42),
            fatigueAerobic: PerformanceEngine.ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 7),
            fitnessStrength: PerformanceEngine.ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 28),
            fatigueStrength: PerformanceEngine.ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 5),
            muscleFatigue: Dictionary(uniqueKeysWithValues: muscleReadiness.map { ($0.name, Double(100 - $0.readiness)) }),
            hrvDeviation: hrvDeviation, restingHeartRateDeviation: restingHeartRateDeviation,
            sleepDebtHours: sleepDebtHours, illness: illness,
            // Recalculado del episodio real, no arrastrado: "hoy, real" es la
            // convención de esta función (ver su comentario), y el estado de
            // viaje de hoy se deriva del episodio igual que la fitness se
            // deriva del historial completo.
            circadianOffsetHours: travel.circadianOffsetHours, travelFatigue: travel.travelFatigue,
            asOf: now
        )
    }
}

extension TwinReadout {
    // Heurística documentada — nunca la puntuación real de hoy (esa sigue
    // saliendo de las señales en vivo dentro de TwinEngine.assess, sin
    // cambios). Se usa solo para predecir: arranca del ancla personal
    // (misma base que PersonalReadinessAnchor.provisional/derive ya
    // establece) y resta según cuánta fatiga hay respecto a la fitness de
    // cada canal — la misma idea de "ratio agudo:crónico" que
    // PerformanceEngine.loadGuidance ya usa, aplicada por canal en vez de
    // mezclada, con los mismos topes por señal (±X pt) que assess() ya usa
    // para HRV/sueño/etc. — no un modelo clínico nuevo.
    static func derive(from physiology: TwinPhysiology, anchor: PersonalReadinessAnchor, calibration: TwinCalibration) -> TwinReadout {
        if physiology.illness {
            let score = min(anchor.score, 40)
            return TwinReadout(score: score, state: label(for: score), confidence: anchor.confidence)
        }
        var score = Double(anchor.score)
        // Ratio, gated by a minimum real fitness floor per channel — not
        // "fitness > 0". fitnessAerobic's own 42-day time constant is far
        // slower to build up than fatigueAerobic's 7-day one is to react,
        // so right after a single simulated session against a near-empty
        // aerobic history (a fresh profile, or an athlete whose whole real
        // history is Hevy strength imports with no HealthKit cardio at
        // all), fitness is still near 0 while fatigue has already jumped —
        // the ratio explodes into a permanent max penalty that a real
        // week's worth of rest can't undo, since fitness barely moves in
        // that time either. minimumTrustedFitness is a deliberately modest
        // floor (roughly one real session's worth of weekly-equivalent
        // load) below which this channel reads as "not enough real signal
        // yet" and contributes no penalty — the same "no evidence yet ->
        // no penalty" honesty this app already applies elsewhere
        // (confidenceWeighted, TwinCalibration.none), not a worst-case
        // assumption invented for missing data. Once a channel clears that
        // floor, the ratio (same ±X pt caps as assess()'s other signals)
        // is genuinely sensitive to a hard day vs. a rest day, unlike a
        // flat difference which stays 0 for both when fitness is strong
        // enough to absorb a single hard session without fatigue ever
        // exceeding it.
        let minimumTrustedFitness = 15.0
        let aerobicStrain = physiology.fitnessAerobic >= minimumTrustedFitness ? physiology.fatigueAerobic / physiology.fitnessAerobic : 0
        let strengthStrain = physiology.fitnessStrength >= minimumTrustedFitness ? physiology.fatigueStrength / physiology.fitnessStrength : 0
        // Coefficients deliberately gentle relative to PerformanceEngine.
        // loadGuidance's own combined-ratio thresholds (0.65/1.08/1.30/1.55)
        // — muscleFatigue below already carries the precise, per-exercise
        // account of what a specific heavy session costs; this term is
        // only the broader, slower-moving "are you trending toward
        // absorbing/overload on this channel" signal ACWR-style ratios
        // already are elsewhere in this app, not a second full-strength
        // penalty for the exact same session. A stronger coefficient here
        // double-counted a single heavy session's cost on top of the
        // muscle-level term and kept simulated readiness pinned down for
        // most of a week even after real muscle fatigue had mostly cleared.
        score -= min(25, aerobicStrain * 6)
        score -= min(20, strengthStrain * 5)
        let muscleValues = Array(physiology.muscleFatigue.values)
        let averageMuscleFatigue = muscleValues.isEmpty ? 0 : muscleValues.reduce(0, +) / Double(muscleValues.count)
        score -= averageMuscleFatigue * 0.12
        // Misma escala y mismos topes que TwinEngine.assess aplica al HRV y al
        // pulso en reposo (deviation × 7, acotado a -15...12 y -15...10): un
        // HRV hundido tiene que costar en el mañana previsto lo mismo que
        // cuesta en la puntuación de hoy. No es doble conteo: la puntuación
        // real de hoy no pasa por aquí (sale de las señales en vivo dentro de
        // assess), y esta lectura sólo se usa para predecir.
        score += min(12, max(-15, physiology.hrvDeviation * 7))
        score += min(10, max(-15, physiology.restingHeartRateDeviation * 7))
        score -= min(12, physiology.sleepDebtHours * 3)
        // PR15: el coste del viaje sale de TravelImpact, que es la única
        // definición — assess() usa exactamente estas dos funciones para la
        // puntuación real de hoy. Si cada uno tuviera su fórmula, el mismo
        // desajuste costaría distinto hoy que mañana, que es precisamente el
        // fallo que tenían la app y el widget antes de este PR.
        score += Double(TravelImpact.circadianReadinessCost(offsetHours: physiology.circadianOffsetHours))
        score += Double(TravelImpact.fatigueReadinessCost(physiology.travelFatigue))
        score += Double(calibration.scoreAdjustment)
        let finalScore = min(100, max(0, Int(score.rounded())))
        return TwinReadout(score: finalScore, state: label(for: finalScore), confidence: anchor.confidence)
    }
}
