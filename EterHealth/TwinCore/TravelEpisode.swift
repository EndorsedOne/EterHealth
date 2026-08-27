import Foundation

// PR14. Un viaje intercontinental como EPISODIO, no como una casilla diaria.
//
// Lo que había antes: LifestyleEvent.timeZoneDifference, un Stepper de 0…14 h
// dentro del cuestionario diario de estilo de vida. La pregunta que hacía
// inservible ese diseño es literal del usuario: "cuando vuelvo del viaje,
// ¿sigo en viaje intercontinental? ¿cuánto tiempo?". Una casilla diaria no
// tiene final definido, así que el atleta no sabe cuándo dejar de marcarla y
// el modelo no sabe cuándo dejar de penalizar. El campo nunca llegó a usarse.
//
// Un episodio sí tiene principio y fin, y —esto es lo que de verdad cambia el
// modelo— tiene SEIS momentos con fisiología distinta: preparación, tránsito
// de ida, adaptación en destino, estancia estable, tránsito de vuelta y
// readaptación en casa. La vuelta no es "lo mismo otra vez": el desplazamiento
// tiene el signo contrario y por tanto una tasa de re-sincronización distinta
// (ver CircadianReentrainment abajo), así que genera su propia fase con su
// propia duración. Eso es imposible de expresar con un entero por día.
//
// Este archivo es SOLO tipos de valor y funciones puras: cero persistencia,
// cero SwiftUI, cero singletons. La persistencia vive en TravelEpisodeStore,
// fuera de TwinCore. El impacto fisiológico (fatiga de viaje y desajuste
// circadiano como estado que decae) es TravelImpactEngine, PR15 — este PR
// deliberadamente no toca la fisiología ni la decisión de entrenamiento.

// MARK: - Priors de re-sincronización circadiana

/// Las tasas con las que el reloj interno se re-sincroniza al huso local.
///
/// PRIOR, no verdad, y con la misma disciplina que
/// MuscleVolumeLandmarkTable aplica a los MEV/MAV/MRV: números de la
/// literatura mientras no haya evidencia propia, sustituibles por lo
/// aprendido de este atleta en cuanto la haya (PR16), y dichos como prior en
/// la UI, no presentados como una medición.
///
/// De dónde salen: las revisiones de re-entrainment de jet lag (Eastman &
/// Burgess; Waterhouse et al.) convergen en que el desplazamiento de fase
/// espontáneo es de aproximadamente 1 h/día cuando hay que ADELANTAR el reloj
/// y ~1.5 h/día cuando hay que RETRASARLO. La asimetría no es un detalle: el
/// período endógeno humano es algo mayor de 24 h, así que retrasarse es la
/// dirección natural y adelantarse la que cuesta. Es exactamente por eso que
/// volar al este se tolera peor que volar al oeste con el mismo número de
/// husos, y es la razón de que ida y vuelta necesiten fases separadas.
///
/// Lo que el modelo anterior hacía: `Δh × 14 h` con un ×1.15 al este, es
/// decir ~5.5 días para 9 husos al este frente a los ~9 días del prior de
/// literatura. Se sustituye, no se conserva — el usuario lo ha aprobado
/// explícitamente y ese número no estaba respaldado por nada.
/// Las dos tasas que gobiernan la re-sincronización, como VALOR — para que
/// lo aprendido de este atleta pueda sustituir al prior sin que ningún
/// consumidor tenga que saber de dónde vino.
///
/// Exactamente el mismo patrón que MuscleVolumeLandmarkTable: el prior es el
/// default, el aprendizaje lo sustituye cuando hay evidencia, y el tipo no
/// distingue entre los dos casos porque los consumidores no deben distinguirlos
/// — sólo la UI dice si el número es prior o medido.
struct ReentrainmentRates: Equatable {
    /// Viaje al este: hay que adelantar fase. La dirección difícil.
    var advanceHoursPerDay: Double
    /// Viaje al oeste: hay que retrasarla. La fácil.
    var delayHoursPerDay: Double

    static let prior = ReentrainmentRates(
        advanceHoursPerDay: CircadianReentrainment.advanceHoursPerDay,
        delayHoursPerDay: CircadianReentrainment.delayHoursPerDay
    )

    func hoursPerDay(forOffsetHours offset: Double) -> Double {
        offset > 0 ? advanceHoursPerDay : delayHoursPerDay
    }
}

enum CircadianReentrainment {
    /// Viaje al ESTE: el reloj tiene que adelantarse. La dirección difícil.
    static let advanceHoursPerDay = 1.0
    /// Viaje al OESTE: el reloj tiene que retrasarse. La dirección fácil.
    static let delayHoursPerDay = 1.5
    /// Tope de la estimación. Ningún viaje real necesita más de dos semanas
    /// de re-sincronización espontánea, y un número mayor sería una
    /// extrapolación de la tasa lineal más allá de donde la literatura la
    /// describe (con desplazamientos de 12 h la re-sincronización deja de ser
    /// monotónica y puede ocurrir por el lado contrario, algo que este modelo
    /// NO pretende capturar y que queda como limitación conocida).
    static let maximumAdaptationDays = 14.0

    /// La tasa que aplica a un desplazamiento con signo. Positivo = hay que
    /// adelantar fase (este); negativo = retrasar (oeste).
    ///
    /// El SIGNO es lo que permite que todo el modelo posterior —incluido el
    /// `step()` de PR15— decaiga el desajuste correctamente sin conocer el
    /// episodio: un escalar con signo lleva dentro la dirección, mientras que
    /// un `Int` de husos más un `enum` de dirección obligan a arrastrar el
    /// episodio hasta dentro de la fisiología.
    nonisolated static func hoursPerDay(forOffsetHours offset: Double,
                                        rates: ReentrainmentRates = .prior) -> Double {
        rates.hoursPerDay(forOffsetHours: offset)
    }

    /// Días de re-sincronización para un desplazamiento con signo. 0 cuando no
    /// hay desplazamiento — no hay nada que re-sincronizar, que es distinto de
    /// "se re-sincroniza instantáneamente".
    ///
    /// `rates` con default `.prior`: PR16 pasa aquí las tasas aprendidas de
    /// este atleta cuando existen, y todo lo que depende de esta función
    /// (duración de las fases, decaimiento del desajuste, el paso de step())
    /// las hereda sin cambiar nada más.
    nonisolated static func daysToRealign(offsetHours offset: Double,
                                          rates: ReentrainmentRates = .prior) -> Double {
        guard offset != 0 else { return 0 }
        return min(maximumAdaptationDays, abs(offset) / rates.hoursPerDay(forOffsetHours: offset))
    }
}

// MARK: - Fases

/// Los seis momentos con fisiología distinta de un viaje, más dos estados
/// terminales.
///
/// `destinationStable` en lugar del `stay` que la propuesta inicial tenía:
/// la adaptación ocurre DURANTE la estancia, así que "adaptación" y
/// "estancia" como fases hermanas se solapan en el tiempo y la transición
/// entre ellas no queda definida. Con `destinationAdaptation →
/// destinationStable` la línea temporal es una máquina de estados de verdad y
/// —lo importante— esa transición ES el evento "estabilidad en destino" que
/// el histórico quiere medir. Sin ella, "días reales hasta estabilidad" no
/// tiene una definición que pueda comprobarse.
enum TravelPhase: String, Codable, CaseIterable, Identifiable {
    case preDeparture = "Preparación"
    case outboundTransit = "Ida"
    case destinationAdaptation = "Adaptación"
    case destinationStable = "Estancia"
    case returnTransit = "Vuelta"
    case homeReadaptation = "Readaptación"
    case recovered = "Recuperado"
    case cancelled = "Cancelado"
    var id: String { rawValue }

    /// El orden de la línea temporal de la UI. `cancelled` no aparece en ella
    /// (no es un punto del recorrido, es su interrupción) y por eso devuelve
    /// nil en vez de una posición inventada al final.
    var timelineIndex: Int? {
        switch self {
        case .preDeparture: return 0
        case .outboundTransit: return 1
        case .destinationAdaptation: return 2
        case .destinationStable: return 3
        case .returnTransit: return 4
        case .homeReadaptation: return 5
        case .recovered: return 6
        case .cancelled: return nil
        }
    }

    /// Las fases en las que el episodio sigue vivo. Lo usa el store para
    /// decidir cuál es "el viaje actual" y lo usará PR15 para saber si hay
    /// estado de viaje que aportar al gemelo.
    var isActive: Bool {
        switch self {
        case .recovered, .cancelled: return false
        default: return true
        }
    }
}

/// Qué hace el atleta con su horario durante la estancia.
///
/// El brief pide explícitamente no fingir que hubo adaptación completa en una
/// estancia corta, y esto es la forma honesta de decirlo: no un caso especial
/// escondido dentro del cálculo, sino una política declarada que la UI puede
/// mostrar y el histórico puede usar para decidir qué viajes son comparables.
enum TravelStayPolicy: String, Codable, CaseIterable, Identifiable {
    /// Se vive en hora local del destino: hay re-sincronización que estimar.
    case adaptToDestination = "Adaptarse al destino"
    /// Se mantiene el horario de origen (sueño, comidas, entrenamientos).
    /// No hay adaptación en destino ni readaptación al volver, porque el
    /// reloj nunca se movió; lo que queda es fatiga de viaje.
    case keepHomeSchedule = "Mantener horario de origen"
    var id: String { rawValue }
}

// MARK: - Tramo de vuelo

/// Un tramo real, con sus dos husos IANA y sus dos instantes.
///
/// `duration` e `isOvernight` son DERIVADOS y no almacenados a propósito: si
/// se guardaran podrían contradecir a las fechas, y entonces habría que
/// testear la consistencia de los propios datos en vez de la lógica. Lo mismo
/// con el desplazamiento: se calcula con `secondsFromGMT(for:)` sobre la fecha
/// real del tramo, nunca con un offset fijo, porque la misma ruta cambia de
/// desplazamiento según el día del año (ver el test de Madrid–Nueva York en la
/// ventana en la que Europa ya ha cambiado la hora y Estados Unidos todavía
/// no: 5 h en vez de las 6 habituales).
struct FlightSegment: Codable, Equatable, Identifiable {
    let id: UUID
    var departure: Date
    var arrival: Date
    /// Identificador IANA, p. ej. "Europe/Madrid". String y no TimeZone
    /// porque tiene que ser Codable y estable entre versiones de iOS; se
    /// valida al construir (ver `isValid`) y se expone resuelto abajo.
    var originTimeZoneID: String
    var destinationTimeZoneID: String

    init(id: UUID = UUID(), departure: Date, arrival: Date,
         originTimeZoneID: String, destinationTimeZoneID: String) {
        self.id = id
        self.departure = departure
        self.arrival = arrival
        self.originTimeZoneID = originTimeZoneID
        self.destinationTimeZoneID = destinationTimeZoneID
    }

    var originTimeZone: TimeZone? { TimeZone(identifier: originTimeZoneID) }
    var destinationTimeZone: TimeZone? { TimeZone(identifier: destinationTimeZoneID) }

    /// Un tramo sirve para algo sólo si los dos husos existen y la llegada es
    /// posterior a la salida. La UI no deja guardar uno inválido y el motor
    /// de PR15 los ignorará en vez de propagar un NaN.
    var isValid: Bool {
        originTimeZone != nil && destinationTimeZone != nil && arrival > departure
    }

    var duration: TimeInterval { max(0, arrival.timeIntervalSince(departure)) }

    /// Desplazamiento del huso CON SIGNO: positivo = hacia el este (hay que
    /// adelantar el reloj), negativo = hacia el oeste. Calculado sobre las
    /// fechas reales de este tramo, así que el horario de verano de cada lado
    /// entra solo.
    var offsetShiftHours: Double {
        guard let originTimeZone, let destinationTimeZone else { return 0 }
        let origin = Double(originTimeZone.secondsFromGMT(for: departure))
        let destination = Double(destinationTimeZone.secondsFromGMT(for: arrival))
        return (destination - origin) / 3_600
    }

    // La ventana de oportunidad de sueño que un vuelo puede destruir, en hora
    // LOCAL DEL ORIGEN — que es el reloj con el que el cuerpo va a llegar al
    // avión, no el del destino. 23:00–07:00 es la misma banda que
    // SleepRegularityEngine usa implícitamente para su "social jet lag", no
    // una segunda definición de "noche" inventada aquí.
    static let sleepWindowStartHour = 23
    static let sleepWindowHours = 8
    /// Dos horas de solape. Un vuelo que despega a las 22:30 no es un vuelo
    /// nocturno; uno que despega a las 21:00 y aterriza a las 02:00 sí.
    static let minimumOvernightOverlapHours = 2.0

    /// Cuántas horas de la ventana de sueño del origen se come este tramo.
    /// Es la magnitud que PR15 usará para la fatiga de viaje, y aquí sirve
    /// para clasificar el tramo como nocturno o no.
    var sleepWindowOverlapHours: Double {
        guard let originTimeZone, arrival > departure else { return 0 }
        return Self.sleepWindowOverlapHours(from: departure, to: arrival, in: originTimeZone)
    }

    var isOvernight: Bool { sleepWindowOverlapHours >= Self.minimumOvernightOverlapHours }

    /// Suma el solape con la ventana 23:00–07:00 de cada noche que el
    /// intervalo toca. Recorre día a día en vez de comparar horas sueltas
    /// porque un tramo puede cruzar varias medianoches (y porque comparar
    /// "hora de salida > 23" fallaría en cualquier vuelo que despega a las
    /// 21:00). Añade con `byAdding: .hour` y no construyendo las 07:00
    /// directamente, para que un día con cambio de hora sume horas reales.
    nonisolated static func sleepWindowOverlapHours(from start: Date, to end: Date, in timeZone: TimeZone) -> Double {
        guard end > start else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Empieza un día antes: el tramo puede arrancar a las 00:30, ya
        // dentro de la ventana que abrió la noche anterior.
        guard var cursor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) else { return 0 }
        let limit = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        var total = 0.0
        while cursor <= limit {
            if let windowStart = calendar.date(bySettingHour: sleepWindowStartHour, minute: 0, second: 0, of: cursor),
               let windowEnd = calendar.date(byAdding: .hour, value: sleepWindowHours, to: windowStart) {
                let overlapStart = max(start, windowStart)
                let overlapEnd = min(end, windowEnd)
                if overlapEnd > overlapStart { total += overlapEnd.timeIntervalSince(overlapStart) / 3_600 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return total
    }
}

// MARK: - Episodio

struct TravelEpisode: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    /// El huso declarado de casa y del destino. NO son redundantes con los de
    /// los tramos aunque puedan derivarse de ellos: son el ancla de la
    /// readaptación (a qué reloj hay que volver) y siguen existiendo cuando
    /// todavía no hay vuelos dados de alta. Que puedan discrepar de los
    /// tramos es un riesgo real, y por eso hay `declaredZonesMatchFlights`
    /// abajo y un test que lo comprueba.
    var homeTimeZoneID: String
    var destinationTimeZoneID: String
    var outboundFlights: [FlightSegment]
    var returnFlights: [FlightSegment]
    /// Sustituye al `stayEndDate` de la propuesta inicial sólo para el caso
    /// en el que aún no hay vuelta dada de alta: cuando hay vuelos de vuelta,
    /// el fin de la estancia ES su primera salida, y almacenarlo aparte
    /// crearía dos fuentes para el mismo dato.
    var expectedStayEndDate: Date?
    /// nil = automático (ver `resolvedStayPolicy`).
    var declaredStayPolicy: TravelStayPolicy?
    /// La fase NO se almacena, se deriva (ver `phase(at:)`). Lo único que es
    /// estado real y no derivable es la cancelación, porque es una decisión
    /// del atleta que ninguna fecha puede expresar.
    var isCancelled: Bool
    /// PR16: los días REALES hasta estabilidad, medidos y guardados.
    ///
    /// Esto sí se almacena, y no es una excepción a "la fase se deriva": es
    /// una MEDICIÓN, no un estado derivable. Y tiene que guardarse porque las
    /// series de HRV y sueño de HealthKit sólo llegan 90 días atrás: con tres
    /// o cuatro viajes intercontinentales al año, un aprendiz que sólo leyera
    /// esa ventana casi nunca tendría dos episodios comparables a la vez. Se
    /// captura mientras el dato todavía está en la ventana y se conserva para
    /// siempre — el mismo motivo por el que TwinStateStore persiste el estado
    /// diario del gemelo en vez de recalcularlo del historial.
    var measuredOutcome: TravelMeasuredOutcome?
    var note: String

    init(id: UUID = UUID(), title: String, homeTimeZoneID: String, destinationTimeZoneID: String,
         outboundFlights: [FlightSegment] = [], returnFlights: [FlightSegment] = [],
         expectedStayEndDate: Date? = nil, declaredStayPolicy: TravelStayPolicy? = nil,
         isCancelled: Bool = false, measuredOutcome: TravelMeasuredOutcome? = nil, note: String = "") {
        self.id = id
        self.title = title
        self.homeTimeZoneID = homeTimeZoneID
        self.destinationTimeZoneID = destinationTimeZoneID
        self.outboundFlights = outboundFlights.sorted { $0.departure < $1.departure }
        self.returnFlights = returnFlights.sorted { $0.departure < $1.departure }
        self.expectedStayEndDate = expectedStayEndDate
        self.declaredStayPolicy = declaredStayPolicy
        self.isCancelled = isCancelled
        self.measuredOutcome = measuredOutcome
        self.note = note
    }

    // MARK: Momentos derivados

    var outboundDeparture: Date? { outboundFlights.map(\.departure).min() }
    var destinationArrival: Date? { outboundFlights.map(\.arrival).max() }
    var returnDeparture: Date? { returnFlights.map(\.departure).min() }
    var homeArrival: Date? { returnFlights.map(\.arrival).max() }

    /// Fin de la estancia: la salida de vuelta si existe, y sólo si no, la
    /// fecha esperada declarada. Una sola fuente, con prioridad explícita.
    var stayEnd: Date? { returnDeparture ?? expectedStayEndDate }

    var stayDuration: TimeInterval? {
        guard let destinationArrival, let stayEnd, stayEnd > destinationArrival else { return nil }
        return stayEnd.timeIntervalSince(destinationArrival)
    }

    /// Puerta a puerta, escalas incluidas — no la suma de los tramos. Un
    /// Madrid–Doha–Auckland con 6 h de escala fatiga por las 30 h que dura,
    /// no por las 24 que se pasan en el aire.
    var outboundTransitDuration: TimeInterval? {
        guard let outboundDeparture, let destinationArrival else { return nil }
        return destinationArrival.timeIntervalSince(outboundDeparture)
    }

    var returnTransitDuration: TimeInterval? {
        guard let returnDeparture, let homeArrival else { return nil }
        return homeArrival.timeIntervalSince(returnDeparture)
    }

    var outboundLayovers: Int { max(0, outboundFlights.count - 1) }
    var returnLayovers: Int { max(0, returnFlights.count - 1) }

    // MARK: Desplazamiento

    /// Desplazamiento total de la ida, con signo. Suma de tramos: un
    /// Madrid–Doha–Auckland desplaza por los dos saltos, no sólo por el
    /// primero.
    var outboundShiftHours: Double { outboundFlights.reduce(0) { $0 + $1.offsetShiftHours } }
    var returnShiftHours: Double { returnFlights.reduce(0) { $0 + $1.offsetShiftHours } }

    /// El desplazamiento que la vuelta tendría según los husos declarados,
    /// para cuando aún no hay vuelos de vuelta dados de alta. No es lo mismo
    /// que `-outboundShiftHours`: se evalúa en la fecha del fin de estancia,
    /// así que si el horario de verano ha cambiado entre medias el número es
    /// distinto — que es exactamente el caso que hace inútil un Int fijo.
    func projectedReturnShiftHours(at date: Date) -> Double {
        guard let home = TimeZone(identifier: homeTimeZoneID),
              let destination = TimeZone(identifier: destinationTimeZoneID) else { return 0 }
        return Double(home.secondsFromGMT(for: date) - destination.secondsFromGMT(for: date)) / 3_600
    }

    /// Los husos declarados coinciden con los de los tramos reales. La UI
    /// avisa cuando no, en vez de resolver el conflicto en silencio eligiendo
    /// uno de los dos.
    var declaredZonesMatchFlights: Bool {
        let outboundOrigin = outboundFlights.first?.originTimeZoneID
        let outboundDestination = outboundFlights.last?.destinationTimeZoneID
        let returnOrigin = returnFlights.first?.originTimeZoneID
        let returnDestination = returnFlights.last?.destinationTimeZoneID
        for (declared, actual) in [(homeTimeZoneID, outboundOrigin), (destinationTimeZoneID, outboundDestination),
                                   (destinationTimeZoneID, returnOrigin), (homeTimeZoneID, returnDestination)] {
            if let actual, actual != declared { return false }
        }
        return true
    }

    var hasOvernightOutbound: Bool { outboundFlights.contains { $0.isOvernight } }
    var hasOvernightReturn: Bool { returnFlights.contains { $0.isOvernight } }

    // MARK: Política de estancia

    /// Por debajo de esto, adaptarse no compensa aunque el atleta no lo haya
    /// declarado. Dos criterios y gana el mayor, los dos documentados como
    /// heurística y no como modelo:
    ///
    ///  · 48 h fijas. Ningún viaje de dos días se adapta a nada.
    ///  · La mitad de los días que costaría re-sincronizarse. Con 9 husos al
    ///    este (≈9 días de prior) una estancia de 3 días no llega ni a la
    ///    mitad del camino: empezar a adaptarse sólo garantiza llegar
    ///    desincronizado a los dos sitios. Es la versión honesta de "no
    ///    finjas que hubo adaptación completa".
    static let minimumStayForAdaptation: TimeInterval = 48 * 3_600

    func adaptationWorthAttempting(shiftHours: Double) -> TimeInterval {
        let halfRealignment = CircadianReentrainment.daysToRealign(offsetHours: shiftHours) / 2 * 86_400
        return max(Self.minimumStayForAdaptation, halfRealignment)
    }

    /// PR16: esta se queda deliberadamente con el PRIOR y no con las tasas
    /// aprendidas. La política de estancia es una decisión de planificación que
    /// el atleta ve y puede sobrescribir; si cambiara sola a medida que el
    /// modelo aprende, el mismo viaje podría pasar de "adaptarse" a "mantener
    /// horario" entre dos aperturas de la app sin que nadie tocara nada. El
    /// prior es el default estable y explicable que corresponde aquí.
    var resolvedStayPolicy: TravelStayPolicy {
        if let declaredStayPolicy { return declaredStayPolicy }
        // Sin estancia conocida todavía (no hay vuelta ni fecha esperada), lo
        // honesto es asumir que se va a vivir en hora local: es el caso
        // general de un viaje abierto, y la política se puede declarar a mano.
        guard let stayDuration else { return .adaptToDestination }
        return stayDuration < adaptationWorthAttempting(shiftHours: outboundShiftHours)
            ? .keepHomeSchedule
            : .adaptToDestination
    }

    // MARK: Duración de las dos fases de adaptación

    /// Días de adaptación en destino, según el prior. Cero con
    /// `keepHomeSchedule`: si el reloj no se mueve, no hay nada que adaptar,
    /// y decir "0 días de adaptación" es distinto de decir "ya está adaptado".
    /// La duración ESTIMADA de la adaptación. Sigue siendo el prior (o la tasa
    /// aprendida): es la predicción, y la UI la muestra como tal.
    func destinationAdaptationDays(rates: ReentrainmentRates = .prior) -> Double {
        guard resolvedStayPolicy == .adaptToDestination else { return 0 }
        return CircadianReentrainment.daysToRealign(offsetHours: outboundShiftHours, rates: rates)
    }

    /// Cuánto se SIGUE OBSERVANDO después de que la duración estimada se agote,
    /// cuando nadie confirmó estabilidad. No alarga la fase — ver abajo.
    ///
    /// Sin este margen el aprendizaje tenía un SESGO SISTEMÁTICO: la
    /// estabilidad sólo se evaluaba mientras el episodio estaba en fase de
    /// adaptación o readaptación, así que una estabilización más LENTA que la
    /// predicha nunca podía registrarse — el aprendiz sólo veía respuestas
    /// iguales o más rápidas que el prior, lo que empuja la tasa aprendida
    /// hacia arriba viaje tras viaje.
    ///
    /// ×2 es generoso y acotado: si a dos veces la duración predicha las
    /// señales siguen sin confirmar nada, atribuirlo al viaje ya no se
    /// sostiene.
    ///
    /// IMPORTANTE: esto NO entra en `phase(at:)`. La primera versión de este
    /// arreglo alargaba la fase de adaptación al margen completo, y con eso la
    /// línea temporal decía "Adaptación" durante 16 días mientras la tarjeta
    /// prometía 8 — exactamente el tipo de etiqueta que promete más de lo que
    /// mide y que el comentario de review venía a corregir. La fase se queda
    /// honesta; lo que se alarga es sólo la ventana en la que TODAVÍA se puede
    /// medir (ver TravelImpactEngine).
    static let stabilityGraceMultiple = 2.0

    /// El final de la fase de adaptación en destino: la estabilidad MEDIDA si
    /// existe, y si no la duración estimada. Sin margen de gracia.
    func destinationAdaptationEnd(rates: ReentrainmentRates = .prior) -> (date: Date, basis: TravelPhaseBasis)? {
        guard let arrival = destinationArrival else { return nil }
        if let measured = measuredOutcome?.destinationStabilityDays {
            return (arrival.addingTimeInterval(measured * 86_400), .measuredStability)
        }
        return (arrival.addingTimeInterval(destinationAdaptationDays(rates: rates) * 86_400),
                .estimatedDurationElapsed)
    }

    func homeReadaptationEnd(rates: ReentrainmentRates = .prior) -> (date: Date, basis: TravelPhaseBasis)? {
        guard let homeArrival else { return nil }
        if let measured = measuredOutcome?.homeStabilityDays {
            return (homeArrival.addingTimeInterval(measured * 86_400), .measuredStability)
        }
        return (homeArrival.addingTimeInterval(homeReadaptationDays(rates: rates) * 86_400),
                .estimatedDurationElapsed)
    }

    /// Hasta cuándo tiene sentido seguir buscando la confirmación de
    /// estabilidad de un tramo que nunca se midió. nil cuando ya está medido
    /// (no hay nada que buscar) o cuando no hay tramo.
    func stabilityMeasurableUntil(leg: TravelLeg, rates: ReentrainmentRates = .prior) -> Date? {
        switch leg {
        case .outbound:
            guard measuredOutcome?.destinationStabilityDays == nil, let arrival = destinationArrival else { return nil }
            return arrival.addingTimeInterval(destinationAdaptationDays(rates: rates) * Self.stabilityGraceMultiple * 86_400)
        case .homeReturn:
            guard measuredOutcome?.homeStabilityDays == nil, let homeArrival else { return nil }
            return homeArrival.addingTimeInterval(homeReadaptationDays(rates: rates) * Self.stabilityGraceMultiple * 86_400)
        }
    }

    /// Días de readaptación en casa. LA FASE PROPIA DE LA VUELTA, que era un
    /// requisito explícito del brief y que aquí no hay que forzar: el
    /// desplazamiento de vuelta tiene el signo contrario, así que le aplica la
    /// otra tasa y sale un número distinto por construcción. Madrid→Tokio son
    /// ~8 días de adaptación (8 h al este, 1 h/día); Tokio→Madrid son ~5.3 de
    /// readaptación (8 h al oeste, 1.5 h/día). Reutilizar el resultado de la
    /// ida daría 8 y sería falso.
    func homeReadaptationDays(rates: ReentrainmentRates = .prior) -> Double {
        guard resolvedStayPolicy == .adaptToDestination else { return 0 }
        let shift = returnFlights.isEmpty
            ? projectedReturnShiftHours(at: stayEnd ?? Date(timeIntervalSince1970: 0))
            : returnShiftHours
        return CircadianReentrainment.daysToRealign(offsetHours: shift, rates: rates)
    }

    // MARK: Fase

    /// La fase en un instante dado. Derivada, nunca almacenada: un episodio
    /// guardado con su fase dentro reportaría una fase falsa en cuanto la app
    /// pasara tres días sin abrirse, y ese es justo el fallo que el check
    /// diario ya tenía.
    func phase(at date: Date, rates: ReentrainmentRates = .prior) -> TravelPhase {
        if isCancelled { return .cancelled }
        guard let outboundDeparture, let destinationArrival else { return .preDeparture }
        if date < outboundDeparture { return .preDeparture }
        if date < destinationArrival { return .outboundTransit }

        if let returnDeparture, date >= returnDeparture {
            guard let homeArrival else { return .returnTransit }
            if date < homeArrival { return .returnTransit }
            guard let end = homeReadaptationEnd(rates: rates) else { return .recovered }
            return date < end.date ? .homeReadaptation : .recovered
        }

        guard let end = destinationAdaptationEnd(rates: rates) else { return .destinationStable }
        return date < end.date ? .destinationAdaptation : .destinationStable
    }

    /// Cuándo termina la fase actual, para que la línea temporal pueda decir
    /// "quedan 2 días" en vez de sólo nombrar la fase. nil cuando no se puede
    /// saber (una estancia sin vuelta ni fecha esperada, o ya recuperado).
    func currentPhaseEnd(at date: Date, rates: ReentrainmentRates = .prior) -> Date? {
        switch phase(at: date, rates: rates) {
        case .preDeparture: return outboundDeparture
        case .outboundTransit: return destinationArrival
        // La duración ESTIMADA, no el margen de gracia: lo que la tarjeta
        // muestra como "hasta" es la predicción, que es lo que el atleta puede
        // usar para planificar. El margen de gracia es un detalle interno del
        // aprendizaje, no una promesa sobre cuándo estará recuperado.
        case .destinationAdaptation:
            return destinationArrival?.addingTimeInterval(destinationAdaptationDays(rates: rates) * 86_400)
        case .destinationStable: return stayEnd
        case .returnTransit: return homeArrival
        case .homeReadaptation:
            return homeArrival?.addingTimeInterval(homeReadaptationDays(rates: rates) * 86_400)
        case .recovered, .cancelled: return nil
        }
    }

    /// Con qué autoridad cerró (o no) la fase de adaptación que corresponde a
    /// esta fecha. Es lo que permite que la UI no diga "recuperado" cuando lo
    /// único que ha pasado es que se agotó una estimación.
    func phaseBasis(at date: Date, rates: ReentrainmentRates = .prior) -> TravelPhaseBasis {
        switch phase(at: date, rates: rates) {
        case .preDeparture, .outboundTransit, .returnTransit, .cancelled:
            return .notApplicable
        case .destinationAdaptation, .homeReadaptation:
            return .inProgress
        case .destinationStable:
            return destinationAdaptationEnd(rates: rates)?.basis ?? .notApplicable
        case .recovered:
            return homeReadaptationEnd(rates: rates)?.basis ?? .estimatedDurationElapsed
        }
    }
}

/// De dónde sale el final de una fase de adaptación. El comentario de review
/// que lo motiva: "Recuperado" significaba "se agotó la duración estimada", no
/// "volviste realmente a tu normalidad" — y son dos afirmaciones muy distintas
/// para una app que presume de no inventar datos.
enum TravelPhaseBasis: Equatable {
    /// Las señales confirmaron estabilidad sostenida y la fase cerró ahí.
    case measuredStability
    /// Nadie confirmó nada: la fase cerró porque se agotó la duración
    /// estimada (más el margen de gracia). Es una predicción cumplida, no una
    /// medición.
    case estimatedDurationElapsed
    /// Todavía dentro de la fase.
    case inProgress
    /// No aplica: preparación, tránsito, cancelado.
    case notApplicable
}

/// Los días reales hasta estabilidad, por tramo, tal y como se midieron.
///
/// Los confusores se congelan en el momento de medir y no se recalculan
/// después: si el atleta estuvo enfermo durante la adaptación en destino, ese
/// episodio no sirve para aprender con el mismo peso — y eso sigue siendo
/// verdad seis meses más tarde, cuando el check-in de aquel día ya no está en
/// ninguna ventana que nadie consulte.
struct TravelMeasuredOutcome: Codable, Equatable {
    /// Días desde la llegada al destino hasta que las señales confirmaron
    /// estabilidad sostenida. nil = nunca se confirmó dentro del episodio, que
    /// es información distinta de "tardó mucho".
    var destinationStabilityDays: Double?
    var homeStabilityDays: Double?
    /// `TravelConfounders.rawValue` congelado. Int y no el OptionSet porque
    /// este tipo es Codable y persistido: un rawValue estable sobrevive a que
    /// alguien añada un caso nuevo al OptionSet.
    var confoundersRawValue: Int
    var lastMeasuredAt: Date

    var confounders: TravelConfounders { TravelConfounders(rawValue: confoundersRawValue) }
    var hasAnything: Bool { destinationStabilityDays != nil || homeStabilityDays != nil }
}
