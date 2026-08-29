import Foundation

// PR15. El impacto de un viaje sobre el gemelo, separado en las DOS cosas que
// el brief pide no mezclar y que la literatura tampoco mezcla:
//
//  · `travelFatigue`: el coste del TRÁNSITO. Duración puerta a puerta,
//    escalas, y cuánta ventana de sueño destruye el vuelo. Se resuelve en
//    horas o pocos días y no tiene dirección: un Madrid–Buenos Aires (sin
//    apenas cambio horario, 13 h de vuelo nocturno) fatiga muchísimo y no
//    desajusta casi nada.
//  · `circadianOffsetHours`: el DESAJUSTE de fase, con signo. Depende de
//    husos y de dirección, tarda días en resolverse y su tasa es asimétrica
//    (ver CircadianReentrainment). Un Madrid–Nueva York desajusta 6 h con un
//    vuelo diurno de 8 h que apenas fatiga.
//
// Antes esto era UN número: en TwinEngine.assess, `-min(12, Δh) × (1 − edad /
// (Δh × 14 h))`. Ni distinguía las dos causas, ni sabía de vuelos nocturnos,
// ni de escalas, ni tenía fase de vuelta. Y había una SEGUNDA penalización
// distinta e incompatible en WidgetSnapshotStore (`Δh × 0.8`, sin decaer y
// sin dirección), así que con 9 husos el widget seguía restando 7.2 puntos el
// día 30 del viaje mientras la app ya no restaba nada. Las dos desaparecen
// aquí: este es el único sitio que estima impacto de viaje.
//
// Puro y determinista: mismo (episodio, fecha, señales) → mismo resultado.
// Sin stores, sin Date(), sin aleatoriedad.

// MARK: - Factores, para que la explicación sea concreta

/// Los hechos que producen el impacto, cada uno con su texto. Existen como
/// tipo y no como un String ya montado porque el brief pide explícitamente
/// que la explicación sea "limito la sesión por vuelo nocturno + sueño corto
/// + HRV por debajo de tu banda" y no "porque has viajado": para eso hay que
/// poder enumerar los factores REALMENTE presentes, no rellenar una plantilla.
enum TravelFactor: Equatable {
    case doorToDoor(hours: Double)
    case layovers(Int)
    case overnightFlight(sleepHoursLost: Double)
    case circadianOffset(hours: Double, daysRemaining: Double)
    case keepHomeSchedule
    // Los tres siguientes son señales medidas. Aparecen en la explicación
    // porque el atleta necesita saber por qué se limita la sesión, pero NO
    // añaden coste de readiness aquí: HRV, pulso y sueño ya se cuentan una vez
    // en las señales propias de TwinEngine.assess. Contarlos otra vez desde
    // el viaje sería doble conteo del mismo dato.
    case shortSleep(hours: Double, expected: Double)
    case hrvBelowBand(value: Double, lowerNormal: Double)
    case restingHeartRateAboveBand(value: Double, upperNormal: Double)

    var description: String {
        switch self {
        case .doorToDoor(let hours):
            return "\(Int(hours.rounded())) h puerta a puerta"
        case .layovers(let count):
            return count == 1 ? "1 escala" : "\(count) escalas"
        case .overnightFlight(let lost):
            return String(format: "vuelo nocturno (%.0f h de tu ventana de sueño)", lost)
        case .circadianOffset(let hours, let days):
            let direction = hours > 0 ? "al este" : "al oeste"
            return String(format: "%.0f h de desajuste %@ sin resolver (≈%.1f días de prior)", abs(hours), direction, days)
        case .keepHomeSchedule:
            return "horario de origen mantenido, sin intento de adaptación"
        case .shortSleep(let hours, let expected):
            return String(format: "sueño de %.1f h frente a tus %.1f habituales", hours, expected)
        case .hrvBelowBand(let value, let lower):
            return String(format: "HRV %.0f ms, por debajo de tu banda (%.0f)", value, lower)
        case .restingHeartRateAboveBand(let value, let upper):
            return String(format: "pulso en reposo %.0f ppm, por encima de tu banda (%.0f)", value, upper)
        }
    }

    /// Si es una señal medida (y por tanto ya contada en assess) o un hecho
    /// estructural del viaje (y por tanto propio de este motor).
    var isMeasuredSignal: Bool {
        switch self {
        case .shortSleep, .hrvBelowBand, .restingHeartRateAboveBand: return true
        default: return false
        }
    }
}

/// Lo que hace que un episodio no sirva para aprender con el mismo peso. Un
/// OptionSet y no varios Bool sueltos porque siempre viajan juntos y porque
/// así el histórico de PR16 puede filtrar por "sin ningún confusor" con una
/// comparación.
struct TravelConfounders: OptionSet, Equatable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let illness = TravelConfounders(rawValue: 1 << 0)
    static let injury = TravelConfounders(rawValue: 1 << 1)
    static let race = TravelConfounders(rawValue: 1 << 2)
    static let alcohol = TravelConfounders(rawValue: 1 << 3)
    static let extraordinaryLoad = TravelConfounders(rawValue: 1 << 4)
    static let none: TravelConfounders = []

    var descriptions: [String] {
        var parts: [String] = []
        if contains(.illness) { parts.append("enfermedad declarada") }
        if contains(.injury) { parts.append("lesión activa") }
        if contains(.race) { parts.append("competición") }
        if contains(.alcohol) { parts.append("alcohol registrado") }
        if contains(.extraordinaryLoad) { parts.append("carga extraordinaria") }
        return parts
    }
}

// MARK: - Resultado

struct TravelImpact: Equatable {
    let phase: TravelPhase
    /// Desajuste que QUEDA por resolver, con signo: positivo = falta adelantar
    /// fase (se viajó al este), negativo = falta retrasarla (al oeste).
    let circadianOffsetHours: Double
    /// 0 (nada) … 1 (el tránsito más duro que este modelo representa).
    let travelFatigue: Double
    let factors: [TravelFactor]
    let confidence: ConfidenceAssessment
    let confounders: TravelConfounders
    /// Cuándo las señales confirmaron estabilidad sostenida. nil = todavía no,
    /// o sin datos suficientes para afirmarlo — que no es lo mismo que "no
    /// estable", y por eso es Optional y no una fecha inventada.
    let stabilizedAt: Date?

    static let none = TravelImpact(
        phase: .recovered, circadianOffsetHours: 0, travelFatigue: 0, factors: [],
        confidence: ConfidenceAssessment(score: 0, level: .low, reason: "Sin viaje activo."),
        confounders: .none, stabilizedAt: nil
    )

    var isPotentiallyConfounded: Bool { !confounders.isEmpty }

    /// Si aporta algo al gemelo. Un episodio en preparación, o ya recuperado,
    /// existe pero no mueve nada — y decirlo aquí evita que cada consumidor
    /// invente su propio umbral.
    var isMeaningful: Bool {
        abs(circadianOffsetHours) >= 0.5 || travelFatigue >= 0.05
    }

    // MARK: Coste de readiness — UNA definición, dos consumidores
    //
    // TwinEngine.assess (la puntuación real de hoy) y TwinReadout.derive (la
    // proyección de mañana) tienen que costar lo MISMO por el mismo desajuste,
    // o hoy y mañana discreparían por construcción. Los dos llaman a estas
    // dos funciones estáticas; ninguno tiene su propia fórmula.
    //
    // Los topes siguen la misma convención de ±X pt por señal que assess ya
    // aplica al HRV (−15…12) y al sueño (−12): el desajuste circadiano llega
    // como máximo a −12, exactamente el mismo techo que tenía el modelo
    // anterior para la diferencia horaria, así que un viaje al este de 8+
    // husos cuesta hoy lo que costaba antes. Lo que cambia es todo lo demás:
    // cómo decae, que la vuelta tiene su propia fase, y que la fatiga de
    // tránsito ya no va disfrazada dentro del mismo número.
    static let maximumCircadianCost = 12.0
    static let circadianCostPerHour = 1.5
    static let maximumFatigueCost = 8.0

    nonisolated static func circadianReadinessCost(offsetHours: Double) -> Int {
        -Int(min(maximumCircadianCost, abs(offsetHours) * circadianCostPerHour).rounded())
    }

    nonisolated static func fatigueReadinessCost(_ fatigue: Double) -> Int {
        -Int((min(1, max(0, fatigue)) * maximumFatigueCost).rounded())
    }

    var circadianReadinessCost: Int { Self.circadianReadinessCost(offsetHours: circadianOffsetHours) }
    var fatigueReadinessCost: Int { Self.fatigueReadinessCost(travelFatigue) }

    /// Los factores estructurales del viaje, para la explicación de la fatiga.
    var structuralFactors: [TravelFactor] { factors.filter { !$0.isMeasuredSignal } }
    /// Las señales medidas, que explican pero no cobran aquí.
    var signalFactors: [TravelFactor] { factors.filter(\.isMeasuredSignal) }
}

// MARK: - Entradas de señal

/// Lo que el motor necesita de fuera, ya leído. Un tipo de valor y no los
/// stores: así el motor es `nonisolated` y puro, y los tests le pueden dar
/// exactamente la señal que quieren comprobar sin montar un HealthStore.
struct TravelSignalContext {
    var baseline: PersonalBaselineProfile?
    var sleepHistory: [TrendPoint]
    var hrvHistory: [TrendPoint]
    var restingHeartRateHistory: [TrendPoint]
    /// Horarios reales de acostarse y levantarse. Entra en la confirmación de
    /// estabilidad porque una re-sincronización circadiana es, literalmente,
    /// que el horario de sueño se haya movido al huso local: dormir 8 h
    /// tranquilas a la hora de casa en Tokio no es haberse adaptado.
    var sleepSchedule: [NightlySleepSchedule]
    var confounders: TravelConfounders

    static let none = TravelSignalContext(baseline: nil, sleepHistory: [], hrvHistory: [],
                                          restingHeartRateHistory: [], sleepSchedule: [],
                                          confounders: .none)
}

// MARK: - Motor

enum TravelImpactEngine {
    /// Cuántos días consecutivos dentro de banda hacen falta para afirmar
    /// estabilidad. Tres, y no uno: una noche buena en medio de un jet lag no
    /// es estabilidad, y el brief pide explícitamente "varios días
    /// consecutivos dentro de bandas personales, con datos suficientes".
    static let stabilityDays = 3

    /// La fatiga de tránsito decae con la MISMA vida media por defecto que
    /// step() ya usa para la fatiga muscular cuando no hay una tasa aprendida
    /// (1.5 días). Reutilizarla en vez de inventar otra constante es
    /// deliberado: son dos fatigas agudas distintas, pero esta app no tiene
    /// evidencia para darles ritmos distintos, y dos números parecidos y
    /// separados es exactamente cómo aparecen las divergencias.
    static let fatigueHalfLifeDays = 1.5

    // Pesos del reparto de la fatiga de tránsito. Heurística documentada y
    // acotada, no un modelo: los tres términos suman como máximo 1.0, y cada
    // tope dice cuánto puede aportar su factor como mucho.
    //
    // 24 h puerta a puerta llegando al tope de duración es la referencia: es
    // aproximadamente un Madrid–Auckland con escala, el viaje más largo que un
    // atleta europeo hace de forma realista. Las escalas pesan poco por sí
    // mismas (su coste real ya está dentro de la duración puerta a puerta);
    // lo que pesa es perder la noche.
    static let referenceDoorToDoorHours = 24.0
    static let durationWeight = 0.55
    static let layoverWeight = 0.075
    static let maximumLayoverWeight = 0.15
    static let overnightWeight = 0.30

    /// El impacto de un episodio en un instante. `nil` de episodio, o un
    /// episodio cancelado o ya recuperado, devuelven `.none` — no un cero
    /// disfrazado de medición.
    nonisolated static func impact(episode: TravelEpisode?, at date: Date,
                                   signals: TravelSignalContext = .none,
                                   rates: ReentrainmentRates = .prior) -> TravelImpact {
        guard let episode else { return .none }
        let phase = episode.phase(at: date, rates: rates)
        guard phase.isActive else {
            // Un episodio ya recuperado no tiene impacto — pero puede quedar
            // por medir. Si la estabilidad de la vuelta nunca se confirmó y la
            // ventana de gracia sigue abierta, se sigue buscando: sin esto, una
            // estabilización más LENTA que la predicha era imposible de
            // registrar, y el aprendizaje sólo veía respuestas iguales o más
            // rápidas que el prior (sesgo sistemático hacia arriba).
            //
            // Todo lo demás se queda a cero, así que `isMeaningful` es false y
            // ni el techo de intensidad ni las señales de assess se enteran:
            // esto sólo alimenta la captura de la medición.
            guard phase == .recovered,
                  let window = episode.stabilityMeasurableUntil(leg: .homeReturn, rates: rates),
                  date <= window,
                  let stabilized = stabilizedDate(episode: episode, at: date, signals: signals,
                                                  rates: rates, measuringLeg: .homeReturn) else { return .none }
            return TravelImpact(phase: phase, circadianOffsetHours: 0, travelFatigue: 0, factors: [],
                                confidence: confidence(signals: signals, stabilized: true),
                                confounders: signals.confounders, stabilizedAt: stabilized)
        }

        let stabilized = stabilizedDate(episode: episode, at: date, signals: signals, rates: rates)
        let offset = circadianOffset(episode: episode, at: date, stabilizedAt: stabilized, rates: rates)
        let fatigue = transitFatigue(episode: episode, at: date, rates: rates)

        var factors: [TravelFactor] = []
        // Estructurales: los del tránsito que está pesando ahora.
        let leg = relevantLeg(episode: episode, phase: phase)
        if let doorToDoor = leg.transitDuration, doorToDoor > 0, fatigue > 0 {
            factors.append(.doorToDoor(hours: doorToDoor / 3_600))
        }
        if leg.layovers > 0, fatigue > 0 { factors.append(.layovers(leg.layovers)) }
        let sleepLost = leg.flights.reduce(0) { $0 + $1.sleepWindowOverlapHours }
        if sleepLost >= FlightSegment.minimumOvernightOverlapHours, fatigue > 0 {
            factors.append(.overnightFlight(sleepHoursLost: sleepLost))
        }
        if abs(offset) >= 0.5 {
            factors.append(.circadianOffset(hours: offset,
                                            daysRemaining: CircadianReentrainment.daysToRealign(offsetHours: offset, rates: rates)))
        }
        if episode.resolvedStayPolicy == .keepHomeSchedule, phase == .destinationStable {
            factors.append(.keepHomeSchedule)
        }
        // Medidas: explican, no cobran.
        factors.append(contentsOf: measuredFactors(at: date, signals: signals))

        return TravelImpact(
            phase: phase, circadianOffsetHours: offset, travelFatigue: fatigue,
            factors: factors,
            confidence: confidence(signals: signals, stabilized: stabilized != nil),
            confounders: signals.confounders, stabilizedAt: stabilized
        )
    }

    // MARK: Desajuste circadiano

    /// El desajuste que queda, por fase. Todo sale del prior de
    /// CircadianReentrainment y de las fechas del episodio; lo único que las
    /// señales pueden hacer es ACORTARLO (ver `stabilizedAt`), nunca alargarlo:
    /// si a los ocho días las señales siguen fuera de banda, atribuirlo al
    /// viaje sería una afirmación que no se puede sostener, así que lo que baja
    /// es la confianza, no lo que sube es el desajuste.
    nonisolated static func circadianOffset(episode: TravelEpisode, at date: Date,
                                            stabilizedAt: Date? = nil,
                                            rates: ReentrainmentRates = .prior) -> Double {
        // Con horario de origen mantenido el reloj no se mueve, así que no hay
        // desajuste PROPIO que resolver — el coste del viaje es la fatiga de
        // tránsito. Limitación conocida y declarada: vivir en hora de casa en
        // un destino con el ciclo de luz invertido tiene un coste real que este
        // modelo no representa.
        guard episode.resolvedStayPolicy == .adaptToDestination else { return 0 }

        switch episode.phase(at: date, rates: rates) {
        case .preDeparture, .recovered, .cancelled:
            return 0
        case .outboundTransit:
            return episode.outboundShiftHours * transitProgress(episode.outboundFlights, at: date)
        case .destinationAdaptation, .destinationStable:
            guard let arrival = episode.destinationArrival else { return 0 }
            if let stabilizedAt, date >= stabilizedAt { return 0 }
            return remaining(shift: episode.outboundShiftHours, since: arrival, at: date, rates: rates)
        case .returnTransit:
            let shift = episode.returnShiftHours
            return shift * transitProgress(episode.returnFlights, at: date)
        case .homeReadaptation:
            guard let homeArrival = episode.homeArrival else { return 0 }
            if let stabilizedAt, date >= stabilizedAt { return 0 }
            return remaining(shift: episode.returnShiftHours, since: homeArrival, at: date, rates: rates)
        }
    }

    /// Decaimiento LINEAL a la tasa del prior, no exponencial. La
    /// re-sincronización circadiana se describe en la literatura como un
    /// desplazamiento de fase de tantas horas por día, que es lineal por
    /// definición; usar una exponencial aquí sólo porque el resto del modelo
    /// las usa sería cambiar el fenómeno para que encaje con el código.
    private nonisolated static func remaining(shift: Double, since start: Date, at date: Date,
                                              rates: ReentrainmentRates) -> Double {
        guard shift != 0 else { return 0 }
        let elapsedDays = max(0, date.timeIntervalSince(start) / 86_400)
        let rate = rates.hoursPerDay(forOffsetHours: shift)
        let resolved = elapsedDays * rate
        let magnitude = max(0, abs(shift) - resolved)
        return shift > 0 ? magnitude : -magnitude
    }

    /// 0 al despegar, 1 al aterrizar. Durante el tránsito el desajuste se
    /// acumula progresivamente en vez de aparecer de golpe: cruzar husos es
    /// gradual, y un escalón en la llegada haría que step() viera un salto que
    /// ninguna fisiología tiene.
    private nonisolated static func transitProgress(_ flights: [FlightSegment], at date: Date) -> Double {
        guard let start = flights.map(\.departure).min(),
              let end = flights.map(\.arrival).max(), end > start else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }

    // MARK: Fatiga de tránsito

    /// El pico de fatiga del tramo que corresponda, decaído desde la llegada.
    nonisolated static func transitFatigue(episode: TravelEpisode, at date: Date,
                                           rates: ReentrainmentRates = .prior) -> Double {
        let phase = episode.phase(at: date, rates: rates)
        guard phase.isActive, phase != .preDeparture else { return 0 }
        let leg = relevantLeg(episode: episode, phase: phase)
        let peak = peakFatigue(flights: leg.flights, transitDuration: leg.transitDuration)
        guard peak > 0 else { return 0 }
        guard let arrival = leg.flights.map(\.arrival).max() else { return 0 }
        if date < arrival {
            // En vuelo: sube con el propio tránsito.
            return peak * transitProgress(leg.flights, at: date)
        }
        let elapsedDays = date.timeIntervalSince(arrival) / 86_400
        return peak * pow(0.5, elapsedDays / fatigueHalfLifeDays)
    }

    /// Los tres términos, cada uno acotado por su propio peso. Suma máxima 1.0.
    nonisolated static func peakFatigue(flights: [FlightSegment], transitDuration: TimeInterval?) -> Double {
        guard !flights.isEmpty else { return 0 }
        let hours = (transitDuration ?? flights.reduce(0) { $0 + $1.duration }) / 3_600
        let durationTerm = min(durationWeight, hours / referenceDoorToDoorHours * durationWeight)
        let layoverTerm = min(maximumLayoverWeight, Double(max(0, flights.count - 1)) * layoverWeight)
        let sleepLost = flights.reduce(0) { $0 + $1.sleepWindowOverlapHours }
        let overnightTerm = min(overnightWeight, sleepLost / Double(FlightSegment.sleepWindowHours) * overnightWeight)
        return min(1, durationTerm + layoverTerm + overnightTerm)
    }

    /// Qué tramo pesa en esta fase. La vuelta no reutiliza el resultado de la
    /// ida: a partir del tránsito de vuelta, la fatiga y el desajuste son los
    /// de la vuelta.
    private nonisolated static func relevantLeg(episode: TravelEpisode, phase: TravelPhase)
        -> (flights: [FlightSegment], transitDuration: TimeInterval?, layovers: Int) {
        switch phase {
        case .returnTransit, .homeReadaptation:
            return (episode.returnFlights, episode.returnTransitDuration, episode.returnLayovers)
        default:
            return (episode.outboundFlights, episode.outboundTransitDuration, episode.outboundLayovers)
        }
    }

    // MARK: Estabilidad

    /// Cuánto puede variar la hora de acostarse respecto a la mediana local
    /// antes de que la noche no cuente como estabilizada. 90 minutos es la
    /// misma banda que SleepRegularityEngine ya usa como frontera de
    /// irregularidad; no es un umbral nuevo inventado aquí.
    static let bedtimeStabilityToleranceMinutes = 90.0

    /// La fecha en la que se cumplieron `stabilityDays` días consecutivos con
    /// TODAS las señales disponibles dentro de banda. nil cuando todavía no ha
    /// pasado o cuando falta algún dato: un día sin medición ROMPE la racha,
    /// porque "tres días consecutivos dentro de banda" exige conocer los tres.
    ///
    /// Señales, y por qué estas: sueño (duración) y HRV son obligatorias — sin
    /// banda personal de las dos no se afirma nada. El pulso en reposo y la
    /// REGULARIDAD del horario de sueño entran como CONFIRMACIÓN adicional
    /// cuando hay dato: si están y se salen de banda, el día no cuenta; si no
    /// están, no penalizan.
    ///
    /// El horario de sueño se añadió por un comentario de review acertado:
    /// duración y HRV no distinguen "me he adaptado a Tokio" de "duermo bien a
    /// la hora de Madrid mientras estoy en Tokio", y esa distinción ES la
    /// re-sincronización circadiana. Sin ella se podía cerrar el desajuste de
    /// alguien que nunca movió su reloj.
    /// `measuringLeg` fuerza qué tramo se está midiendo, para los casos en los
    /// que la fase ya no lo dice (un episodio recuperado cuya vuelta quedó sin
    /// medir). nil = se deduce de la fase, que es el caso normal.
    nonisolated static func stabilizedDate(episode: TravelEpisode, at date: Date,
                                           signals: TravelSignalContext,
                                           rates: ReentrainmentRates = .prior,
                                           measuringLeg: TravelLeg? = nil) -> Date? {
        guard let baseline = signals.baseline,
              let sleepFloor = baseline.sleep.lowerNormal,
              let hrvFloor = baseline.hrv.lowerNormal else { return nil }
        let restingCeiling = baseline.restingHeartRate.upperNormal
        let phase = episode.phase(at: date, rates: rates)
        let start: Date?
        if let measuringLeg {
            start = measuringLeg == .homeReturn ? episode.homeArrival : episode.destinationArrival
        } else {
            switch phase {
            case .destinationAdaptation, .destinationStable: start = episode.destinationArrival
            case .homeReadaptation: start = episode.homeArrival
            default: return nil
            }
        }
        guard let start else { return nil }

        let leg = measuringLeg ?? (phase == .homeReadaptation ? .homeReturn : .outbound)
        let localZone = leg == .homeReturn
            ? TimeZone(identifier: episode.homeTimeZoneID)
            : TimeZone(identifier: episode.destinationTimeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        // Las noches se agrupan en el día civil donde se estaba, no en el huso
        // que tenga el teléfono meses después al reconstruir el viaje.
        calendar.timeZone = localZone ?? .current
        // El horario contra el que se compara: el ANCLA PERSONAL, no la mediana
        // de las mismas noches que se están juzgando.
        //
        // La primera versión de esta comprobación hacía justo eso, y un
        // comentario de review lo señaló: tres noches seguidas acostándose a
        // las 07:00 en Tokio son perfectamente "regulares" y pasaban como
        // estables, aunque 07:00 en Tokio sea 23:00 en Lisboa — es decir,
        // alguien que no ha movido su reloj en absoluto. Aquello medía
        // regularidad y yo lo había documentado como si midiera adaptación.
        //
        // El ancla es la hora habitual de acostarse del atleta, aprendida de
        // las noches ANTES de salir y leída en hora de casa; adaptarse
        // significa volver a esa misma hora de reloj pero en el huso de donde
        // estás. Así "23:30 en Tokio" cuenta como adaptado y "07:00 en Tokio"
        // (= 23:30 en Lisboa) no, que es la distinción que hace falta.
        let habitualBedtimeMinutes = habitualBedtimeMinutes(episode: episode, signals: signals)

        var streak = 0
        var cursor = calendar.startOfDay(for: start)
        let limit = calendar.startOfDay(for: date)
        while cursor <= limit {
            if dayIsStable(cursor, calendar: calendar, signals: signals,
                           sleepFloor: sleepFloor, hrvFloor: hrvFloor, restingCeiling: restingCeiling,
                           habitualBedtimeMinutes: habitualBedtimeMinutes, localZone: localZone) {
                streak += 1
                if streak >= stabilityDays { return cursor }
            } else {
                streak = 0
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return nil
    }

    /// Decisión pura del backfill de viajes pasados: qué tramos cuya ventana de
    /// gracia ya cerró (`< now`) confirman estabilidad según las señales, y en
    /// cuántos días desde la llegada. Sin HealthKit — el store le pasa las
    /// señales ya leídas, así esto se testea en aislamiento igual que
    /// stabilizedDate. Sólo mira tramos aún sin medir (stabilityMeasurableUntil
    /// devuelve nil cuando ya hay medición). Es la misma comprobación que en
    /// vivo, sólo que mirando atrás en vez de esperar a que pasen los días.
    nonisolated static func retroactiveStability(
        episode: TravelEpisode, signals: TravelSignalContext,
        rates: ReentrainmentRates = .prior, now: Date = Date()
    ) -> [(leg: TravelLeg, days: Double)] {
        var result: [(leg: TravelLeg, days: Double)] = []
        if let window = episode.stabilityMeasurableUntil(leg: .outbound, rates: rates), window < now,
           let arrival = episode.destinationArrival {
            // La ida no se puede medir más allá de la vuelta a casa.
            let limit = min(window, episode.homeArrival ?? window)
            if let stabilized = stabilizedDate(episode: episode, at: limit, signals: signals,
                                               rates: rates, measuringLeg: .outbound),
               stabilized >= arrival {
                result.append((.outbound, stabilized.timeIntervalSince(arrival) / 86_400))
            }
        }
        if let window = episode.stabilityMeasurableUntil(leg: .homeReturn, rates: rates), window < now,
           let homeArrival = episode.homeArrival {
            if let stabilized = stabilizedDate(episode: episode, at: window, signals: signals,
                                               rates: rates, measuringLeg: .homeReturn),
               stabilized >= homeArrival {
                result.append((.homeReturn, stabilized.timeIntervalSince(homeArrival) / 86_400))
            }
        }
        return result
    }

    /// Un día cuenta como estabilizado si todas las señales CON DATO están en
    /// banda. Sueño y HRV son obligatorias (sin ellas no se llega hasta aquí);
    /// pulso en reposo y regularidad de horario confirman cuando existen.
    private nonisolated static func dayIsStable(
        _ day: Date, calendar: Calendar, signals: TravelSignalContext,
        sleepFloor: Double, hrvFloor: Double, restingCeiling: Double?,
        habitualBedtimeMinutes: Double?, localZone: TimeZone?
    ) -> Bool {
        guard let sleep = value(in: signals.sleepHistory, on: day, calendar: calendar),
              let hrv = value(in: signals.hrvHistory, on: day, calendar: calendar),
              sleep >= sleepFloor, hrv >= hrvFloor else { return false }
        if let restingCeiling,
           let resting = value(in: signals.restingHeartRateHistory, on: day, calendar: calendar),
           resting > restingCeiling { return false }
        if let habitualBedtimeMinutes, let localZone,
           let bedtime = signals.sleepSchedule.first(where: { calendar.isDate($0.night, inSameDayAs: day) })?.bedtime {
            // La hora de acostarse leída en el huso de DONDE ESTÁ, comparada
            // con su hora habitual de reloj. Es la comparación que distingue
            // haberse adaptado de haber mantenido el horario de origen.
            let minutes = minutesFromLocalMidnight(bedtime, in: localZone)
            if abs(shortestAngularDifference(minutes, habitualBedtimeMinutes)) > bedtimeStabilityToleranceMinutes {
                return false
            }
        }
        return true
    }

    /// Cuántas noches de antes de salir se miran para establecer la costumbre.
    /// Tres semanas: suficiente para que la mediana describa un hábito y no un
    /// par de noches raras, y corto como para que sea el hábito ACTUAL.
    static let habitualBedtimeLookbackDays = 21.0

    /// La hora habitual de acostarse del atleta, en minutos desde la medianoche
    /// de SU CASA, aprendida de las noches previas a la salida.
    ///
    /// nil cuando no hay noches suficientes antes del viaje: entonces la
    /// comprobación de horario no se aplica y no penaliza, la misma convención
    /// que el pulso en reposo. Sin ancla no se afirma nada sobre adaptación de
    /// horario — que es distinto de afirmar que no hubo.
    nonisolated static func habitualBedtimeMinutes(episode: TravelEpisode,
                                                   signals: TravelSignalContext) -> Double? {
        guard let departure = episode.outboundDeparture,
              let homeZone = TimeZone(identifier: episode.homeTimeZoneID) else { return nil }
        let windowStart = departure.addingTimeInterval(-habitualBedtimeLookbackDays * 86_400)
        let values = signals.sleepSchedule
            .filter { $0.night >= windowStart && $0.night < departure }
            .map { minutesFromLocalMidnight($0.bedtime, in: homeZone) }
        guard values.count >= stabilityDays else { return nil }
        return median(values)
    }

    /// Mediana circular sobre un reloj de 24 h. Una mediana aritmética de
    /// [23:40, 00:10, 23:50] daría las 15:53, que no es la hora a la que se
    /// acuesta nadie: los valores hay que centrarlos antes de ordenarlos.
    private nonisolated static func median(_ minutes: [Double]) -> Double? {
        guard let reference = minutes.first else { return nil }
        let centred = minutes.map { reference + shortestAngularDifference($0, reference) }
        let sorted = centred.sorted(), middle = sorted.count / 2
        let raw = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let day = 24.0 * 60
        return (raw.truncatingRemainder(dividingBy: day) + day).truncatingRemainder(dividingBy: day)
    }

    private nonisolated static func minutesFromLocalMidnight(_ date: Date, in zone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// Distancia en minutos sobre un reloj de 24 h. Sin esto, acostarse a las
    /// 23:50 y a las 00:10 saldrían a 1420 minutos de distancia en vez de a 20
    /// — y toda noche que cruza medianoche rompería la racha.
    private nonisolated static func shortestAngularDifference(_ a: Double, _ b: Double) -> Double {
        let day = 24.0 * 60
        let raw = (a - b).truncatingRemainder(dividingBy: day)
        if raw > day / 2 { return raw - day }
        if raw < -day / 2 { return raw + day }
        return raw
    }

    private nonisolated static func value(in history: [TrendPoint], on day: Date, calendar: Calendar) -> Double? {
        history.first { calendar.isDate($0.date, inSameDayAs: day) }?.value
    }

    /// Las señales medidas de HOY que explican por qué se limita la sesión.
    /// No cobran readiness aquí — ver el comentario de TravelFactor.
    private nonisolated static func measuredFactors(at date: Date, signals: TravelSignalContext) -> [TravelFactor] {
        guard let baseline = signals.baseline else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: date)
        var factors: [TravelFactor] = []
        if let sleep = value(in: signals.sleepHistory, on: today, calendar: calendar),
           let floor = baseline.sleep.lowerNormal, sleep < floor,
           let expected = baseline.sleep.expected {
            factors.append(.shortSleep(hours: sleep, expected: expected))
        }
        if let hrv = value(in: signals.hrvHistory, on: today, calendar: calendar),
           let floor = baseline.hrv.lowerNormal, hrv < floor {
            factors.append(.hrvBelowBand(value: hrv, lowerNormal: floor))
        }
        if let resting = value(in: signals.restingHeartRateHistory, on: today, calendar: calendar),
           let ceiling = baseline.restingHeartRate.upperNormal, resting > ceiling {
            factors.append(.restingHeartRateAboveBand(value: resting, upperNormal: ceiling))
        }
        return factors
    }

    /// La confianza de la estimación. Baja cuando el impacto sale sólo del
    /// prior y sube cuando hay señales reales que lo confirman o lo acortan —
    /// que es literalmente lo que el brief pide: prior prudente y explicable al
    /// principio, respuesta individual después.
    nonisolated static func confidence(signals: TravelSignalContext, stabilized: Bool) -> ConfidenceAssessment {
        guard let baseline = signals.baseline else {
            return ConfidenceAssessment(
                score: 20, level: .low,
                reason: "Estimación sólo desde el prior de la literatura: no hay línea base personal de sueño ni HRV con la que confirmarla."
            )
        }
        let usableSignals = [baseline.sleep.lowerNormal, baseline.hrv.lowerNormal,
                             baseline.restingHeartRate.upperNormal].compactMap { $0 }.count
        var assessment = ConfidenceEngine.samples(usableSignals, medium: 2, high: 3,
                                                  label: "señal con banda personal")
        if stabilized {
            assessment = ConfidenceAssessment(
                score: min(90, assessment.score + 15), level: ConfidenceEngine.level(score: min(90, assessment.score + 15)),
                reason: assessment.reason + " Tus propias señales han confirmado estabilidad sostenida, así que el prior ya no manda."
            )
        }
        if !signals.confounders.isEmpty {
            let listed = signals.confounders.descriptions.joined(separator: ", ")
            assessment = ConfidenceAssessment(
                score: max(10, assessment.score - 25), level: ConfidenceEngine.level(score: max(10, assessment.score - 25)),
                reason: assessment.reason + " Episodio potencialmente confundido por \(listed): no se usará con el mismo peso para aprender."
            )
        }
        return assessment
    }
}
