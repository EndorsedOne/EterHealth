import Foundation

// PR3: una sola carga EWMA mezclaba sentadilla y tirada larga, así que no
// había forma de modelar interferencia concurrente — ni de responder a
// "¿esta sobrecarga es de fuerza o de fondo?". Dos canales con sus propias
// constantes de tiempo, y el número combinado de siempre pasa a ser una
// LECTURA derivada de los dos, no una tercera fuente que pueda divergir.
struct DualLoad: Equatable {
    var aerobic: Double
    var strength: Double
    static let none = DualLoad(aerobic: 0, strength: 0)
    // El combinado es exactamente la suma porque el EWMA es lineal: el
    // ewmaWeeklyEquivalent de (aeróbico + fuerza) día a día y la suma de los
    // dos EWMA por separado son el mismo número. Por eso partir el canal no
    // mueve ni un decimal de lo que ya se mostraba (hay un test que lo fija).
    var combined: Double { aerobic + strength }

    // Reparto heurístico y documentado por tipo de sesión: un híbrido/brick
    // aporta a los dos canales, el resto a uno solo.
    static func split(total: Double, kind: PlannedSessionKind) -> DualLoad {
        switch kind {
        case .strength: return DualLoad(aerobic: 0, strength: total)
        case .hybrid, .brick: return DualLoad(aerobic: total * 0.6, strength: total * 0.4)
        default: return DualLoad(aerobic: total, strength: 0)
        }
    }

    // ESTÍMULO: lo que de verdad entrena. Un día de descanso no entrena
    // nada, y por eso `recovery` es cero aquí — el "8" de
    // forecastSessionLoad representa actividad residual de un día normal,
    // que es otra cosa (ver ratioLoad abajo). Alimentar los canales de
    // fitness/fatiga de step() con ese residuo dejaba la fatiga sin bajar
    // nunca por debajo de la fitness en una semana simulada.
    static func forecast(_ kind: PlannedSessionKind) -> DualLoad {
        if kind == .recovery { return .none }
        return split(total: TrainingPlanEngine.forecastSessionLoad(kind), kind: kind)
    }

    // CARGA para el ratio agudo:crónico, que sí cuenta el residuo de un día
    // normal: es el mismo número que ese modelo ha usado siempre, sólo
    // repartido en canales. Dos funciones y no una porque son dos modelos
    // distintos con dos preguntas distintas ("¿esto me entrena?" vs "¿cuánta
    // carga llevo encima?"), y tenerlas separadas y nombradas es lo que evita
    // que alguien las cruce por descuido.
    // Por debajo de esta carga habitual semanal-equivalente un canal no
    // tiene ratio con el que juzgar nada: es el mismo suelo, y por la misma
    // razón, que TwinReadout.derive's minimumTrustedFitness. El agudo (τ7)
    // reacciona muchísimo más rápido que el habitual (τ28) sube, así que
    // contra un canal casi vacío —alguien cuyo historial real es todo fuerza
    // y empieza a correr— el ratio se dispara a un valor que ninguna semana
    // de descanso puede deshacer, y el gate lo dejaría en recuperación
    // permanente. Sin evidencia no hay penalización, que es la misma
    // honestidad que esta app ya aplica en otros sitios.
    static let minimumTrustedHabitual = 15.0

    // ÚNICA definición del ratio que gobierna los gates de carga. La usan
    // tanto DualLoadSummary (hoy, real) como la simulación hacia delante de
    // TrainingPlanEngine.weekAhead, para que no puedan discrepar.
    static func governingRatio(acute: DualLoad, habitual: DualLoad) -> Double {
        Swift.max(ratio(acute: acute.aerobic, habitual: habitual.aerobic),
                  ratio(acute: acute.strength, habitual: habitual.strength))
    }

    static func governingChannel(acute: DualLoad, habitual: DualLoad) -> String {
        ratio(acute: acute.aerobic, habitual: habitual.aerobic) >= ratio(acute: acute.strength, habitual: habitual.strength)
            ? "aeróbica" : "de fuerza"
    }

    static func ratio(acute: Double, habitual: Double) -> Double {
        habitual >= minimumTrustedHabitual ? acute / habitual : 0
    }

    static func ratioLoad(_ kind: PlannedSessionKind) -> DualLoad {
        // El residuo de un día de descanso es movimiento diario, no fuerza.
        split(total: TrainingPlanEngine.forecastSessionLoad(kind), kind: kind == .recovery ? .easyRun : kind)
    }
}

// PR11: el ORDEN dentro de un día que carga los dos canales. Hasta ahora
// DualLoad sabía CUÁNTO va a cada canal (split) pero no en qué secuencia, y
// la secuencia no es un detalle de presentación: es una de las poquísimas
// variables de un programa concurrente que cambia la adaptación sin cambiar
// ni el volumen ni la intensidad.
//
// La regla y su base:
//
//  · Wilson et al. 2012 (meta-análisis de entrenamiento concurrente) y la
//    revisión de Fyfe/Bishop/Stepto describen el mecanismo: el trabajo
//    aeróbico hecho poco después de la resistencia atenúa la señalización
//    mTOR que esa sesión de fuerza buscaba. El daño va en una dirección: la
//    fuerza previa penaliza mucho menos a una sesión aeróbica FÁCIL que la
//    aeróbica previa a la sesión de fuerza. De ahí el defecto:
//    FUERZA PRIMERO.
//  · La excepción no es una excepción al mecanismo, es la regla de
//    priorización que cualquier programa aplica por encima de él: la sesión
//    CLAVE va primero, con las piernas frescas. Una sesión de calidad o una
//    tirada larga corridas sobre piernas ya cargadas de sentadillas no son
//    la misma sesión — el ritmo objetivo deja de ser alcanzable y la
//    sesión mide fatiga en vez de entrenar el sistema que pretendía. Cuando
//    el estímulo aeróbico del día es ESE, va primero.
//  · El margen de horas es el mismo que la propuesta de "Después del tren
//    superior" ya usaba y justificaba (>= 3 h para que la interferencia sea
//    pequeña, no cero); aquí se nombra en un solo sitio en vez de quedar
//    escrito dentro de un cue.
//
// Lo que esto NO hace: no toca step(), ni los EWMA, ni el reparto de split.
// El orden es una recomendación explícita sobre una decisión que ya está
// tomada, no un cuarto canal de carga.
enum ConcurrentOrder: Equatable {
    /// El caso por defecto: la fuerza primero y el estímulo aeróbico fácil
    /// después, con margen.
    case strengthFirst
    /// La sesión aeróbica del día es la clave (calidad o tirada larga): va
    /// primero, con piernas frescas.
    case enduranceFirst

    /// Margen mínimo entre las dos sesiones del día. El mismo >= 3 h en los
    /// dos sentidos: es el orden lo que cambia el efecto, no el hueco.
    var minimumHoursBetween: Double { 3 }

    var explanation: String {
        switch self {
        case .strengthFirst:
            return "Fuerza primero y el trabajo aeróbico después, con al menos 3 h de margen: el estímulo aeróbico inmediatamente posterior a la fuerza atenúa la señalización que esa sesión de fuerza busca, y el orden inverso penaliza mucho menos a una sesión aeróbica fácil."
        case .enduranceFirst:
            return "Hoy la sesión aeróbica es la clave, así que va primero y con piernas frescas: corrida después de la fuerza dejaría de ser alcanzable a ritmo objetivo y mediría fatiga en vez de entrenar lo que pretende. Deja al menos 3 h antes de la fuerza."
        }
    }
}

extension DualLoad {
    /// El orden preferido cuando un día carga los dos canales. `aerobic` es
    /// el estímulo aeróbico del día; devuelve `enduranceFirst` sólo cuando
    /// ese estímulo es una sesión clave (calidad o tirada larga), que es la
    /// única situación en la que la regla de priorización pesa más que el
    /// mecanismo de interferencia. Pura y sin estado: el mismo par de kinds
    /// siempre da el mismo orden.
    static func preferredOrder(aerobic: PlannedSessionKind) -> ConcurrentOrder {
        switch aerobic {
        case .qualityRun, .longRun, .brick, .raceDay: return .enduranceFirst
        // Volumen aeróbico fácil, natación y bici: la fuerza va primero.
        // La natación además apenas comparte musculatura con un día de
        // pierna, así que la interferencia real es todavía menor.
        case .easyRun, .swim, .bike, .hybrid, .strength, .recovery: return .strengthFirst
        }
    }
}

// Un día de historial con los dos canales separados en el origen, en vez de
// sumados al entrar. `load` combinado se conserva para DailyTraining y para
// el ratio de siempre.
struct DailyDualTraining: Equatable {
    let date: Date
    let sessions: Int
    let aerobic: Double
    let strength: Double
    var load: Double { aerobic + strength }
}

struct DualLoadSummary: Equatable {
    var acuteAerobic: Double      // τ = 7
    var habitualAerobic: Double   // τ = 28
    var acuteStrength: Double
    var habitualStrength: Double
    var observedDays: Int
    // Por canal, no el combinado: una racha sostenida de fuerza no debe
    // contar como semanas sostenidas de fondo, que es justo lo que hacía
    // que loadGuidance leyera "sobrecarga" con la evidencia del otro canal.
    var sustainedAerobicWeeks: Int
    var sustainedStrengthWeeks: Int
    // Capacidad demostrada antes de la ventana reciente: mediana de las
    // semanas activas entre 4 y 12 semanas atrás. No sustituye la preparación
    // actual (EWMA 28 d); permite distinguir una carga nueva de un retorno a
    // un volumen que esta persona ya sostuvo.
    var historicalAerobicCapacity: Double = 0
    var historicalStrengthCapacity: Double = 0

    static let none = DualLoadSummary(acuteAerobic: 0, habitualAerobic: 0, acuteStrength: 0, habitualStrength: 0,
                                      observedDays: 0, sustainedAerobicWeeks: 0, sustainedStrengthWeeks: 0)

    // El suelo de confianza va aquí, en el ratio de cada canal, y no sólo en
    // el que gobierna el gate: así `aerobicGuidance`/`strengthGuidance` lo
    // heredan y no hay dos reglas distintas de "cuándo un canal tiene ratio".
    // Sin él, un canal con una pizca de historial (habitual 5, agudo 60) leía
    // "sobrecarga probable" con evidencia de una sola semana.
    var aerobicRatio: Double { DualLoad.ratio(acute: acuteAerobic, habitual: habitualAerobic) }
    var strengthRatio: Double { DualLoad.ratio(acute: acuteStrength, habitual: habitualStrength) }

    // El ratio que gobierna los gates de carga (exceedsPaceCeiling y la
    // divulgación de riesgo de Agresivo): el canal que realmente pica, no la
    // mezcla. Sumar los dos canales antes de dividir hacía dos cosas mal a la
    // vez — un pico real de un solo canal quedaba diluido por el otro canal
    // tranquilo, y una subida moderada simultánea en los dos se leía como un
    // pico que ninguno de los dos tenía. Es estrictamente más sensible que el
    // combinado, y eso es la corrección, no un efecto secundario.
    var governingRatio: Double { Swift.max(aerobicRatio, strengthRatio) }
    var planningRatio: Double {
        guidance == .returning ? min(governingRatio, 1.29) : governingRatio
    }

    // Qué canal manda, para poder decirlo en el rationale en vez de hablar de
    // "la carga" en abstracto.
    var governingChannel: String { DualLoad.governingChannel(acute: acuteChannels, habitual: habitualChannels) }

    var acuteChannels: DualLoad { DualLoad(aerobic: acuteAerobic, strength: acuteStrength) }
    var habitualChannels: DualLoad { DualLoad(aerobic: habitualAerobic, strength: habitualStrength) }

    var strengthGuidance: LoadGuidance {
        contextualGuidance(acute: acuteStrength, habitual: habitualStrength,
                           historical: historicalStrengthCapacity,
                           base: PerformanceEngine.loadGuidance(ratio: strengthRatio, sustainedWeeks: sustainedStrengthWeeks, observedDays: observedDays))
    }

    var aerobicGuidance: LoadGuidance {
        contextualGuidance(acute: acuteAerobic, habitual: habitualAerobic,
                           historical: historicalAerobicCapacity,
                           base: PerformanceEngine.loadGuidance(ratio: aerobicRatio, sustainedWeeks: sustainedAerobicWeeks, observedDays: observedDays))
    }

    private func contextualGuidance(acute: Double, habitual: Double, historical: Double,
                                    base: LoadGuidance) -> LoadGuidance {
        guard historical >= DualLoad.minimumTrustedHabitual,
              habitual < historical * 0.72,
              acute <= historical * 1.10,
              base == .absorb || base == .overload else { return base }
        return .returning
    }

    // Regla explícita, no un promedio mudo: manda el canal que pide más
    // cautela. Promediar los dos ratios es exactamente el error que el
    // canal único ya cometía — una semana dura de fuerza y un fondo suave
    // se cancelaban y salía "productiva" cuando la fuerza estaba en
    // sobrecarga. `learning` (sin datos suficientes) es el rango más bajo
    // a propósito: no tener evidencia en un canal no puede tapar lo que el
    // otro sí mide.
    var guidance: LoadGuidance {
        aerobicGuidance.cautionRank >= strengthGuidance.cautionRank ? aerobicGuidance : strengthGuidance
    }

    // Mismo paso de un día que projectedAcuteLoad/projectedLoadRatio ya
    // usaban, aplicado por canal en vez de a la mezcla.
    func projectedAcute(adding session: DualLoad) -> DualLoad {
        DualLoad(aerobic: acuteAerobic + session.aerobic * (1 - exp(-1 / 7.0)) * 7,
                 strength: acuteStrength + session.strength * (1 - exp(-1 / 7.0)) * 7)
    }

    func projectedHabitual(adding session: DualLoad) -> DualLoad {
        DualLoad(aerobic: habitualAerobic + session.aerobic * (1 - exp(-1 / 28.0)) * 7,
                 strength: habitualStrength + session.strength * (1 - exp(-1 / 28.0)) * 7)
    }

    func projectedRatios(adding session: DualLoad) -> (aerobic: Double, strength: Double) {
        let acute = projectedAcute(adding: session), habitual = projectedHabitual(adding: session)
        return (DualLoad.ratio(acute: acute.aerobic, habitual: habitual.aerobic),
                DualLoad.ratio(acute: acute.strength, habitual: habitual.strength))
    }

    // El ratio que gobierna tras añadir una sesión hipotética — el mismo
    // criterio que el gate del plan, para que el simulador no pueda decir
    // "esto no te pasa factura" mientras status() manda a recuperación.
    func projectedGoverningRatio(adding session: DualLoad) -> Double {
        DualLoad.governingRatio(acute: projectedAcute(adding: session), habitual: projectedHabitual(adding: session))
    }
}

extension LoadGuidance {
    // Orden de cautela, no de severidad clínica: es lo único que necesita la
    // regla "manda el peor de los dos canales" de DualLoadSummary.guidance.
    var cautionRank: Int {
        switch self {
        case .learning: return 0
        case .low: return 1
        case .productive: return 2
        case .absorb: return 3
        case .returning: return 3
        case .deload: return 4
        case .overload: return 5
        }
    }
}

extension PerformanceEngine {
    // La ÚNICA separación aeróbico/fuerza del repo. TwinPhysiology.derive
    // tenía su propia copia de este bucle (mismo filtro de Hevy-espejado,
    // mismo isStrengthWorkout, mismas unidades) y ahora la consume desde
    // aquí: dos copias de "qué cuenta como fuerza" era precisamente lo que
    // el brief prohíbe.
    @MainActor static func dailyDualHistory(health: HealthStore, imports: ImportStore,
                                            days: Int = 84, now: Date = Date()) -> [DailyDualTraining] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        var sessions: [Date: Int] = [:]
        var aerobic: [Date: Double] = [:]
        var strength: [Date: Double] = [:]

        // Hevy es fuerza por definición: son series, no minutos.
        for workout in imports.workouts where workout.start >= start && workout.start <= now {
            let day = calendar.startOfDay(for: workout.start)
            sessions[day, default: 0] += 1
            strength[day, default: 0] += Double(workout.exercises.reduce(0) { $0 + $1.sets }) * 3
        }
        for workout in health.recentWorkouts where workout.date >= start && workout.date <= now &&
            !workout.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror(workout) {
            let day = calendar.startOfDay(for: workout.date)
            sessions[day, default: 0] += 1
            let load = workout.durationMinutes * cardioFactor(workout.activity)
            // cardioFactor se queda tal cual y no se mezclan unidades entre
            // canales: una sesión de fuerza registrada en HealthKit (sin
            // series que contar) sigue valorándose por minutos, pero cae en
            // el canal de fuerza, no en el aeróbico.
            if TrainingPlanEngine.isStrengthWorkout(workout) { strength[day, default: 0] += load }
            else { aerobic[day, default: 0] += load }
        }

        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -(days - 1) + offset, to: today) else { return nil }
            return DailyDualTraining(date: date, sessions: sessions[date] ?? 0,
                                     aerobic: aerobic[date] ?? 0, strength: strength[date] ?? 0)
        }
    }

    @MainActor static func dualSummary(history: [DailyDualTraining]) -> DualLoadSummary {
        let aerobicLoads = history.map(\.aerobic)
        let strengthLoads = history.map(\.strength)
        let habitualAerobic = ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 28)
        let habitualStrength = ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 28)
        let historical = historicalWeeklyCapacity(history: history)
        return DualLoadSummary(
            acuteAerobic: ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 7),
            habitualAerobic: habitualAerobic,
            acuteStrength: ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 7),
            habitualStrength: habitualStrength,
            observedDays: history.filter { $0.sessions > 0 }.count,
            sustainedAerobicWeeks: sustainedWeeks(loads: aerobicLoads, habitualWeekly: habitualAerobic),
            sustainedStrengthWeeks: sustainedWeeks(loads: strengthLoads, habitualWeekly: habitualStrength),
            historicalAerobicCapacity: historical.aerobic,
            historicalStrengthCapacity: historical.strength
        )
    }

    /// Mediana de semanas activas anteriores al último mes. Las semanas a
    /// cero no desaparecen de la preparación actual —ya están dentro del
    /// EWMA de 28 días—, pero tampoco borran la prueba de que el atleta
    /// sostuvo un volumen anteriormente. Exige cuatro semanas reales para
    /// no convertir un pico aislado en "capacidad".
    nonisolated static func historicalWeeklyCapacity(history: [DailyDualTraining]) -> DualLoad {
        guard history.count > 28 else { return .none }
        let older = history.dropLast(28)
        var aerobicWeeks: [Double] = [], strengthWeeks: [Double] = []
        var index = older.startIndex
        while index < older.endIndex {
            let end = older.index(index, offsetBy: 7, limitedBy: older.endIndex) ?? older.endIndex
            let slice = older[index..<end]
            let aerobic = slice.reduce(0) { $0 + $1.aerobic }
            let strength = slice.reduce(0) { $0 + $1.strength }
            if aerobic > 0 { aerobicWeeks.append(aerobic) }
            if strength > 0 { strengthWeeks.append(strength) }
            index = end
        }
        func capacity(_ values: [Double]) -> Double {
            guard values.count >= 4 else { return 0 }
            let sorted = values.sorted(), middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        return DualLoad(aerobic: capacity(aerobicWeeks), strength: capacity(strengthWeeks))
    }

    // Extraído tal cual de summarize (mismas 4 semanas rodantes, mismo 0.85)
    // para poder aplicarlo por canal sin una segunda definición.
    nonisolated static func sustainedWeeks(loads: [Double], habitualWeekly: Double) -> Int {
        guard habitualWeekly > 0 else { return 0 }
        let rolling = stride(from: max(0, loads.count - 28), to: loads.count, by: 7).map { start in
            loads[start..<min(start + 7, loads.count)].reduce(0, +)
        }
        return rolling.suffix(3).filter { $0 >= habitualWeekly * 0.85 }.count
    }
}
