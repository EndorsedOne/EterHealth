import XCTest
@testable import EterHealth

// PR14. Los episodios de viaje: fechas, husos IANA, horario de verano, ida y
// vuelta como fases distintas, y estancia corta. Archivo propio y no dentro de
// EngineTests porque no comparte ninguno de sus fixtures (ni HealthStore, ni
// ImportStore, ni TwinContext): son tipos de valor puros y sus tests sólo
// necesitan fechas.
@MainActor
final class TravelEpisodeTests: XCTestCase {

    // MARK: - Utilidades de fecha

    /// Un instante en hora LOCAL de un huso concreto. Todos los tests se
    /// escriben así, en la hora que el atleta leería en su billete, no en UTC:
    /// si un test tuviera que traducir a UTC a mano estaría reimplementando
    /// justo lo que pretende comprobar.
    private func local(_ timeZoneID: String, _ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        components.timeZone = TimeZone(identifier: timeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        return calendar.date(from: components)!
    }

    private func segment(_ originID: String, _ departure: Date,
                         _ destinationID: String, _ arrival: Date) -> FlightSegment {
        FlightSegment(departure: departure, arrival: arrival,
                      originTimeZoneID: originID, destinationTimeZoneID: destinationID)
    }

    // MARK: - Desplazamiento con signo y horario de verano

    func testOffsetShiftIsSignedSoEastIsPositiveAndWestNegative() {
        // Madrid → Tokio: hacia el este, hay que ADELANTAR el reloj.
        let east = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 12),
                           "Asia/Tokyo", local("Asia/Tokyo", 2026, 7, 11, 8))
        XCTAssertEqual(east.offsetShiftHours, 7, accuracy: 0.001, "Madrid CEST (+2) → Tokio (+9) = +7.")

        // Madrid → Nueva York: hacia el oeste, hay que RETRASARLO.
        let west = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 12),
                           "America/New_York", local("America/New_York", 2026, 7, 10, 15))
        XCTAssertEqual(west.offsetShiftHours, -6, accuracy: 0.001, "Madrid CEST (+2) → Nueva York EDT (−4) = −6.")

        // El signo es lo que lleva la dirección dentro del escalar, y es de
        // donde salen las dos tasas distintas de re-sincronización.
        XCTAssertEqual(CircadianReentrainment.hoursPerDay(forOffsetHours: east.offsetShiftHours),
                       CircadianReentrainment.advanceHoursPerDay)
        XCTAssertEqual(CircadianReentrainment.hoursPerDay(forOffsetHours: west.offsetShiftHours),
                       CircadianReentrainment.delayHoursPerDay)
    }

    func testTheSameRouteHasADifferentShiftInsideTheDaylightSavingGap() {
        // ESTE es el test que hace inútil guardar un Int de husos. Europa
        // cambia la hora el último domingo de octubre (26/10/2025) y Estados
        // Unidos el primer domingo de noviembre (2/11/2025). En la semana de
        // en medio, Madrid ya está en invierno (+1) y Nueva York sigue en
        // verano (−4): la MISMA ruta desplaza 5 h en vez de las 6 habituales.
        let inTheGap = segment("Europe/Madrid", local("Europe/Madrid", 2025, 10, 29, 10),
                               "America/New_York", local("America/New_York", 2025, 10, 29, 13))
        XCTAssertEqual(inTheGap.offsetShiftHours, -5, accuracy: 0.001,
                       "En la ventana 26/10–2/11 la diferencia Madrid–Nueva York es de 5 h, no de 6.")

        // Fuera de la ventana, con los dos husos en invierno, vuelven a ser 6.
        let bothInWinter = segment("Europe/Madrid", local("Europe/Madrid", 2025, 11, 10, 10),
                                   "America/New_York", local("America/New_York", 2025, 11, 10, 13))
        XCTAssertEqual(bothInWinter.offsetShiftHours, -6, accuracy: 0.001)

        // Y con los dos en verano, también 6 — el desplazamiento no depende
        // sólo de la ruta.
        let bothInSummer = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 10),
                                   "America/New_York", local("America/New_York", 2026, 7, 10, 13))
        XCTAssertEqual(bothInSummer.offsetShiftHours, -6, accuracy: 0.001)
    }

    func testMultiLegOutboundSumsEveryHopNotJustTheFirst() {
        // Madrid → Doha → Auckland. Si sólo contara el primer salto, el
        // desplazamiento saldría +1 en vez de +10.
        let leg1 = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 15),
                           "Asia/Qatar", local("Asia/Qatar", 2026, 7, 10, 23))
        let leg2 = segment("Asia/Qatar", local("Asia/Qatar", 2026, 7, 11, 2),
                           "Pacific/Auckland", local("Pacific/Auckland", 2026, 7, 12, 5))
        let episode = TravelEpisode(title: "Auckland", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Pacific/Auckland",
                                    outboundFlights: [leg1, leg2])
        XCTAssertEqual(leg1.offsetShiftHours, 1, accuracy: 0.001)
        XCTAssertEqual(leg2.offsetShiftHours, 9, accuracy: 0.001)
        XCTAssertEqual(episode.outboundShiftHours, 10, accuracy: 0.001)
        XCTAssertEqual(episode.outboundLayovers, 1)
        // Puerta a puerta, escala incluida: no la suma de los tiempos de vuelo.
        let doorToDoor = episode.outboundTransitDuration! / 3_600
        let airborne = (leg1.duration + leg2.duration) / 3_600
        XCTAssertGreaterThan(doorToDoor, airborne, "La escala forma parte del tránsito, no desaparece.")
        XCTAssertEqual(doorToDoor - airborne, 3, accuracy: 0.001, "Las 3 h de escala en Doha.")
    }

    // MARK: - Vuelo nocturno

    func testOvernightIsMeasuredAgainstTheOriginsSleepWindowNotADepartureHour() {
        // El clásico: sale a las 21:00 y aterriza de madrugada. La hora de
        // salida sola (21:00 < 23:00) diría que no es nocturno.
        let redEye = segment("America/New_York", local("America/New_York", 2026, 7, 10, 21),
                             "Europe/Madrid", local("Europe/Madrid", 2026, 7, 11, 10))
        XCTAssertTrue(redEye.isOvernight)
        XCTAssertGreaterThan(redEye.sleepWindowOverlapHours, 4,
                             "De 21:00 a 04:00 hora de Nueva York se come casi toda la ventana.")

        // Un vuelo diurno del mismo trayecto no lo es.
        let daytime = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 10),
                              "America/New_York", local("America/New_York", 2026, 7, 10, 13))
        XCTAssertFalse(daytime.isOvernight)
        XCTAssertEqual(daytime.sleepWindowOverlapHours, 0, accuracy: 0.001)

        // Y uno que despega a las 22:30 y aterriza a las 00:00 tampoco: 1 h de
        // solape no destruye una noche, y el umbral está en 2 h.
        let lateEvening = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 22, 30),
                                  "Europe/Madrid", local("Europe/Madrid", 2026, 7, 11, 0))
        XCTAssertFalse(lateEvening.isOvernight)

        // La ventana se mide en hora del ORIGEN, que es el reloj con el que el
        // cuerpo sube al avión. El mismo vuelo evaluado en hora del destino
        // saldría 03:00–10:00 y contaría distinto.
        XCTAssertGreaterThan(
            FlightSegment.sleepWindowOverlapHours(from: redEye.departure, to: redEye.arrival,
                                                  in: TimeZone(identifier: "America/New_York")!),
            FlightSegment.sleepWindowOverlapHours(from: redEye.departure, to: redEye.arrival,
                                                  in: TimeZone(identifier: "Europe/Madrid")!)
        )
    }

    // MARK: - Ida y vuelta son fases distintas

    func testReturnGetsItsOwnReadaptationLengthInsteadOfReusingTheOutbound() {
        // El requisito explícito del brief. Madrid→Tokio son 8 h al ESTE
        // (1 h/día → 8 días de adaptación); Tokio→Madrid son 8 h al OESTE
        // (1.5 h/día → 5.33 días de readaptación). Reutilizar el resultado de
        // la ida daría 8 y sería falso.
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 1, 10, 12),
                               "Asia/Tokyo", local("Asia/Tokyo", 2026, 1, 11, 9))
        let back = segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 1, 25, 10),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 1, 25, 16))
        let episode = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo",
                                    outboundFlights: [outbound], returnFlights: [back])
        XCTAssertEqual(episode.outboundShiftHours, 8, accuracy: 0.001)
        XCTAssertEqual(episode.returnShiftHours, -8, accuracy: 0.001)
        XCTAssertEqual(episode.destinationAdaptationDays(), 8, accuracy: 0.001)
        XCTAssertEqual(episode.homeReadaptationDays(), 8 / 1.5, accuracy: 0.001)
        XCTAssertLessThan(episode.homeReadaptationDays(), episode.destinationAdaptationDays(),
                          "Volver al oeste cuesta menos que ir al este, y el modelo tiene que decirlo.")
    }

    func testWestwardOutboundInvertsWhichPhaseIsTheLongOne() {
        // La comprobación simétrica: con un destino al oeste, la fase larga es
        // la readaptación al volver, no la adaptación al llegar. Si alguien
        // implementara "la vuelta cuesta menos" como una constante en vez de
        // como consecuencia del signo, esto lo detecta.
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 10),
                               "America/Los_Angeles", local("America/Los_Angeles", 2026, 7, 10, 13))
        let back = segment("America/Los_Angeles", local("America/Los_Angeles", 2026, 7, 24, 14),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 7, 25, 11))
        let episode = TravelEpisode(title: "Los Ángeles", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "America/Los_Angeles",
                                    outboundFlights: [outbound], returnFlights: [back])
        XCTAssertEqual(episode.outboundShiftHours, -9, accuracy: 0.001)
        XCTAssertEqual(episode.returnShiftHours, 9, accuracy: 0.001)
        XCTAssertEqual(episode.destinationAdaptationDays(), 9 / 1.5, accuracy: 0.001)
        XCTAssertEqual(episode.homeReadaptationDays(), 9, accuracy: 0.001)
        XCTAssertGreaterThan(episode.homeReadaptationDays(), episode.destinationAdaptationDays())
    }

    func testProjectedReturnShiftUsesTheRealDateSoItIsNotJustTheOutboundNegated() {
        // Sin vuelta dada de alta todavía, el desplazamiento de vuelta se
        // proyecta con los husos declarados en la fecha del fin de estancia.
        // No es −outboundShift: si el horario de verano cambia durante la
        // estancia, el número es distinto. Salida en la ventana de octubre
        // (5 h) y vuelta ya en noviembre (6 h).
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2025, 10, 29, 10),
                               "America/New_York", local("America/New_York", 2025, 10, 29, 13))
        let episode = TravelEpisode(title: "Nueva York", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "America/New_York",
                                    outboundFlights: [outbound],
                                    expectedStayEndDate: local("America/New_York", 2025, 11, 10, 9))
        XCTAssertEqual(episode.outboundShiftHours, -5, accuracy: 0.001)
        XCTAssertEqual(episode.projectedReturnShiftHours(at: episode.stayEnd!), 6, accuracy: 0.001,
                       "La vuelta ya es de 6 h porque Estados Unidos cambió la hora durante la estancia.")
        XCTAssertNotEqual(episode.projectedReturnShiftHours(at: episode.stayEnd!), -episode.outboundShiftHours)
    }

    // MARK: - Línea temporal completa

    func testPhaseWalksTheWholeTimelineInOrder() {
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 3, 2, 12),
                               "Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 3, 9))
        let back = segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 20, 10),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 3, 20, 16))
        let episode = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo",
                                    outboundFlights: [outbound], returnFlights: [back])
        let expected: [(Date, TravelPhase)] = [
            (local("Europe/Madrid", 2026, 2, 25, 9), .preDeparture),
            (local("Europe/Madrid", 2026, 3, 2, 18), .outboundTransit),
            (local("Asia/Tokyo", 2026, 3, 5, 9), .destinationAdaptation),      // +2 días de 8
            (local("Asia/Tokyo", 2026, 3, 15, 9), .destinationStable),          // pasados los 8
            (local("Asia/Tokyo", 2026, 3, 20, 13), .returnTransit),
            (local("Europe/Madrid", 2026, 3, 22, 12), .homeReadaptation),       // +2 días de 5.33
            (local("Europe/Madrid", 2026, 4, 5, 12), .recovered)
        ]
        for (date, phase) in expected {
            XCTAssertEqual(episode.phase(at: date), phase, "El \(date) debería ser \(phase.rawValue).")
        }
        // Y el orden de la línea temporal es estrictamente creciente, que es
        // lo que la UI dibuja.
        let indexes = expected.map { episode.phase(at: $0.0).timelineIndex! }
        XCTAssertEqual(indexes, indexes.sorted(), "Las fases no pueden ir hacia atrás: \(indexes)")
    }

    func testPhaseIsDerivedNotStoredSoAStaleEpisodeCannotLie() {
        // El fallo que tenía el check diario: un estado guardado que nadie
        // actualiza. Aquí el mismo episodio, sin tocarlo, reporta fases
        // distintas según cuándo se le pregunte.
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 5, 1, 12),
                               "America/New_York", local("America/New_York", 2026, 5, 1, 15))
        let episode = TravelEpisode(title: "Nueva York", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "America/New_York",
                                    outboundFlights: [outbound],
                                    expectedStayEndDate: local("America/New_York", 2026, 6, 1, 9))
        XCTAssertEqual(episode.phase(at: local("Europe/Madrid", 2026, 4, 20, 9)), .preDeparture)
        XCTAssertEqual(episode.phase(at: local("America/New_York", 2026, 5, 2, 9)), .destinationAdaptation)
        XCTAssertEqual(episode.phase(at: local("America/New_York", 2026, 5, 20, 9)), .destinationStable)
    }

    func testCancellationIsTheOnlyRealStoredStateAndBeatsEveryDate() {
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 5, 1, 12),
                               "Asia/Tokyo", local("Asia/Tokyo", 2026, 5, 2, 9))
        var episode = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo", outboundFlights: [outbound])
        episode.isCancelled = true
        for date in [local("Europe/Madrid", 2026, 4, 1, 9), local("Asia/Tokyo", 2026, 5, 3, 9)] {
            XCTAssertEqual(episode.phase(at: date), .cancelled)
        }
        XCTAssertNil(TravelPhase.cancelled.timelineIndex, "Cancelado no es un punto del recorrido.")
        XCTAssertFalse(TravelPhase.cancelled.isActive)
        XCTAssertFalse(TravelPhase.recovered.isActive)
    }

    // MARK: - Estancia corta

    func testAShortStayKeepsTheHomeScheduleAndClaimsNoAdaptationAtAll() {
        // 36 h en Nueva York con 6 h de desplazamiento: adaptarse sólo
        // garantiza volver desincronizado de los dos sitios.
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 6, 9),
                               "America/New_York", local("America/New_York", 2026, 7, 6, 12))
        let back = segment("America/New_York", local("America/New_York", 2026, 7, 7, 18),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 7, 8, 7))
        let short = TravelEpisode(title: "Reunión en Nueva York", homeTimeZoneID: "Europe/Madrid",
                                  destinationTimeZoneID: "America/New_York",
                                  outboundFlights: [outbound], returnFlights: [back])
        XCTAssertEqual(short.resolvedStayPolicy, .keepHomeSchedule)
        XCTAssertEqual(short.destinationAdaptationDays(), 0,
                       "Cero días de adaptación porque no se intenta, que es distinto de 'ya adaptado'.")
        XCTAssertEqual(short.homeReadaptationDays(), 0, "Si el reloj no se movió, no hay nada que readaptar.")
        // Y por tanto no hay fase de adaptación en la línea temporal: se pasa
        // de la ida a la estancia directamente.
        XCTAssertEqual(short.phase(at: local("America/New_York", 2026, 7, 6, 14)), .destinationStable)
        XCTAssertEqual(short.phase(at: local("Europe/Madrid", 2026, 7, 8, 9)), .recovered)

        // La misma ruta con dos semanas de estancia sí se adapta.
        let longBack = segment("America/New_York", local("America/New_York", 2026, 7, 20, 18),
                               "Europe/Madrid", local("Europe/Madrid", 2026, 7, 21, 7))
        let long = TravelEpisode(title: "Nueva York", homeTimeZoneID: "Europe/Madrid",
                                 destinationTimeZoneID: "America/New_York",
                                 outboundFlights: [outbound], returnFlights: [longBack])
        XCTAssertEqual(long.resolvedStayPolicy, .adaptToDestination)
        XCTAssertEqual(long.destinationAdaptationDays(), 6 / 1.5, accuracy: 0.001)
    }

    func testTheShortStayThresholdScalesWithTheShiftNotJustAFixed48Hours() {
        // Con un desplazamiento grande, "corto" es más largo: 4 días en
        // Auckland (11 h) siguen sin dar para adaptarse ni a medio camino,
        // mientras 4 días en Londres (1 h) sobran.
        let farOutbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 1, 5, 15),
                                  "Pacific/Auckland", local("Pacific/Auckland", 2026, 1, 7, 5))
        let farBack = segment("Pacific/Auckland", local("Pacific/Auckland", 2026, 1, 11, 10),
                              "Europe/Madrid", local("Europe/Madrid", 2026, 1, 11, 23))
        let far = TravelEpisode(title: "Auckland", homeTimeZoneID: "Europe/Madrid",
                                destinationTimeZoneID: "Pacific/Auckland",
                                outboundFlights: [farOutbound], returnFlights: [farBack])
        XCTAssertEqual(far.outboundShiftHours, 12, accuracy: 0.001)
        XCTAssertEqual(far.resolvedStayPolicy, .keepHomeSchedule,
                       "4 días no llegan ni a la mitad de los 12 que costaría re-sincronizarse.")

        let nearOutbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 1, 5, 9),
                                   "Europe/London", local("Europe/London", 2026, 1, 5, 10))
        let nearBack = segment("Europe/London", local("Europe/London", 2026, 1, 9, 18),
                               "Europe/Madrid", local("Europe/Madrid", 2026, 1, 9, 21))
        let near = TravelEpisode(title: "Londres", homeTimeZoneID: "Europe/Madrid",
                                 destinationTimeZoneID: "Europe/London",
                                 outboundFlights: [nearOutbound], returnFlights: [nearBack])
        XCTAssertEqual(near.outboundShiftHours, -1, accuracy: 0.001)
        XCTAssertEqual(near.resolvedStayPolicy, .adaptToDestination)
    }

    func testDeclaredPolicyAlwaysBeatsTheAutomaticOne() {
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 6, 9),
                               "America/New_York", local("America/New_York", 2026, 7, 6, 12))
        let back = segment("America/New_York", local("America/New_York", 2026, 7, 7, 18),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 7, 8, 7))
        var episode = TravelEpisode(title: "Nueva York", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "America/New_York",
                                    outboundFlights: [outbound], returnFlights: [back])
        XCTAssertEqual(episode.resolvedStayPolicy, .keepHomeSchedule)
        episode.declaredStayPolicy = .adaptToDestination
        XCTAssertEqual(episode.resolvedStayPolicy, .adaptToDestination,
                       "Lo que el atleta declara manda sobre el automático, en los dos sentidos.")
        XCTAssertGreaterThan(episode.destinationAdaptationDays(), 0)
    }

    // MARK: - Validez y coherencia de los datos

    func testAnInvalidSegmentIsDetectedInsteadOfProducingSilentZeros() {
        let backwards = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 15),
                                "Asia/Tokyo", local("Europe/Madrid", 2026, 7, 10, 12))
        XCTAssertFalse(backwards.isValid, "Llegar antes de salir no es un tramo.")
        let unknownZone = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 12),
                                  "Marte/Olympus", local("Europe/Madrid", 2026, 7, 10, 20))
        XCTAssertFalse(unknownZone.isValid)
        XCTAssertEqual(unknownZone.offsetShiftHours, 0, accuracy: 0.001,
                       "Sin huso resoluble, 0 y no un NaN que se propague al resto del modelo.")
    }

    func testDeclaredZonesAreCheckedAgainstTheRealFlightsInsteadOfSilentlyWinning() {
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 12),
                               "Asia/Tokyo", local("Asia/Tokyo", 2026, 7, 11, 9))
        let consistent = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                       destinationTimeZoneID: "Asia/Tokyo", outboundFlights: [outbound])
        XCTAssertTrue(consistent.declaredZonesMatchFlights)
        let inconsistent = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Lisbon",
                                         destinationTimeZoneID: "Asia/Tokyo", outboundFlights: [outbound])
        XCTAssertFalse(inconsistent.declaredZonesMatchFlights,
                       "Declarar Lisboa y volar desde Madrid es una incoherencia que hay que avisar, no resolver a escondidas.")
        // Un episodio sin vuelos todavía no es incoherente, sólo incompleto.
        XCTAssertTrue(TravelEpisode(title: "Pendiente", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo").declaredZonesMatchFlights)
    }

    func testFlightsAreKeptSortedSoTheFirstAndLastAreReallyTheFirstAndLast() {
        let leg2 = segment("Asia/Qatar", local("Asia/Qatar", 2026, 7, 11, 2),
                           "Pacific/Auckland", local("Pacific/Auckland", 2026, 7, 12, 5))
        let leg1 = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 15),
                           "Asia/Qatar", local("Asia/Qatar", 2026, 7, 10, 23))
        // Dados de alta al revés a propósito.
        let episode = TravelEpisode(title: "Auckland", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Pacific/Auckland",
                                    outboundFlights: [leg2, leg1])
        XCTAssertEqual(episode.outboundFlights.first?.originTimeZoneID, "Europe/Madrid")
        XCTAssertEqual(episode.outboundFlights.last?.destinationTimeZoneID, "Pacific/Auckland")
        XCTAssertTrue(episode.declaredZonesMatchFlights)
    }

    // MARK: - Priors

    func testReentrainmentPriorsAreAsymmetricAndBounded() {
        // La asimetría es el hecho fisiológico que justifica todo el modelo de
        // dos fases: retrasar el reloj es la dirección natural.
        XCTAssertGreaterThan(CircadianReentrainment.delayHoursPerDay,
                             CircadianReentrainment.advanceHoursPerDay)
        XCTAssertEqual(CircadianReentrainment.daysToRealign(offsetHours: 0), 0,
                       "Sin desplazamiento no hay nada que re-sincronizar.")
        XCTAssertEqual(CircadianReentrainment.daysToRealign(offsetHours: 3), 3, accuracy: 0.001)
        XCTAssertEqual(CircadianReentrainment.daysToRealign(offsetHours: -3), 2, accuracy: 0.001)
        // Acotado: la tasa lineal no se extrapola indefinidamente.
        XCTAssertEqual(CircadianReentrainment.daysToRealign(offsetHours: 30),
                       CircadianReentrainment.maximumAdaptationDays, accuracy: 0.001)
    }

    // MARK: - Store

    func testStorePicksTheStartedEpisodeAsTheCurrentOneAndDropsRecoveredAndCancelled() {
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        let now = local("Europe/Madrid", 2026, 5, 10, 12)
        // Uno ya terminado hace meses.
        let old = TravelEpisode(
            title: "Viejo", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "America/New_York",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 1, 5, 10),
                                      "America/New_York", local("America/New_York", 2026, 1, 5, 13))],
            returnFlights: [segment("America/New_York", local("America/New_York", 2026, 1, 12, 18),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 1, 13, 7))])
        // Uno en curso.
        let ongoing = TravelEpisode(
            title: "En curso", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Asia/Tokyo",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 5, 8, 12),
                                      "Asia/Tokyo", local("Asia/Tokyo", 2026, 5, 9, 9))],
            expectedStayEndDate: local("Asia/Tokyo", 2026, 6, 1, 9))
        // Uno futuro.
        let future = TravelEpisode(
            title: "Futuro", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Europe/London",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 1, 9),
                                      "Europe/London", local("Europe/London", 2026, 9, 1, 10))])
        for episode in [old, ongoing, future] { store.save(episode) }

        XCTAssertEqual(store.currentEpisode(at: now)?.title, "En curso",
                       "El empezado gana al futuro, y el terminado no compite.")
        XCTAssertEqual(store.completedEpisodes(at: now).map(\.title), ["Viejo"])

        store.cancel(id: ongoing.id)
        XCTAssertEqual(store.currentEpisode(at: now)?.title, "Futuro",
                       "Cancelado el que estaba en curso, el actual pasa a ser el próximo por salir.")
        XCTAssertEqual(store.completedEpisodes(at: now).map(\.title), ["Viejo"],
                       "Un viaje cancelado nunca entra en el histórico del que se aprende.")
    }

    func testStoreRoundTripsThroughJSONWithDerivedValuesIntact() {
        let outbound = segment("Europe/Madrid", local("Europe/Madrid", 2026, 3, 2, 12),
                               "Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 3, 9))
        let episode = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo",
                                    outboundFlights: [outbound], note: "Con escala corta")
        let data = try! JSONEncoder().encode([episode])
        let decoded = try! JSONDecoder().decode([TravelEpisode].self, from: data)
        XCTAssertEqual(decoded, [episode])
        // Y los derivados se recalculan igual tras el round-trip, que es el
        // punto de no almacenarlos.
        XCTAssertEqual(decoded[0].outboundShiftHours, episode.outboundShiftHours, accuracy: 0.001)
        XCTAssertEqual(decoded[0].destinationAdaptationDays(), episode.destinationAdaptationDays(), accuracy: 0.001)
        XCTAssertEqual(decoded[0].phase(at: local("Asia/Tokyo", 2026, 3, 5, 9)), .destinationAdaptation)
    }
}
