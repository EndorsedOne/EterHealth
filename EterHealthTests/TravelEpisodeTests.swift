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

    // Dar de alta la vuelta cuando YA hay un destino intermedio tiene que
    // AÑADIR una parada, no sobrescribir la intermedia. El fallo que esto fija
    // se veía en la UI —la ciudad de la vuelta acababa en un destino nuevo—
    // pero el contrato es del modelo.
    func testAddingTheReturnWithAnIntermediateStopAppendsInsteadOfReplacing() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))
        XCTAssertFalse(episode.returnsHome, "Todavía no hay vuelta.")

        episode.returnFlights = [segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 20, 11),
                                         "Europe/Madrid", local("Europe/Madrid", 2026, 9, 20, 20))]

        XCTAssertEqual(episode.stops.count, 3, "La vuelta se AÑADE; Seúl no se pierde.")
        XCTAssertEqual(episode.intermediateStops.count, 1)
        XCTAssertEqual(episode.intermediateStops.first?.destinationTimeZoneID, "Asia/Seoul")
        XCTAssertTrue(episode.returnsHome)

        // Y sustituirla después reemplaza esa misma parada, no añade otra.
        episode.returnFlights = [segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 21, 11),
                                         "Europe/Madrid", local("Europe/Madrid", 2026, 9, 21, 20))]
        XCTAssertEqual(episode.stops.count, 3, "Cambiar la vuelta no crea una parada nueva.")
    }

    func testIntermediatePhaseBasisAndEndBelongToThatStop() {
        let bangkok = TravelStop(flights: [segment(
            "Europe/Madrid", local("Europe/Madrid", 2026, 9, 1, 10),
            "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 2, 8)
        )])
        let seoul = TravelStop(flights: [segment(
            "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 10, 10),
            "Asia/Seoul", local("Asia/Seoul", 2026, 9, 10, 17)
        )])
        let home = TravelStop(flights: [segment(
            "Asia/Seoul", local("Asia/Seoul", 2026, 9, 20, 10),
            "Europe/Madrid", local("Europe/Madrid", 2026, 9, 20, 18)
        )])
        let measuredAt = local("Asia/Seoul", 2026, 9, 12, 12)
        let episode = TravelEpisode(
            title: "Asia", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Asia/Bangkok",
            stops: [bangkok, seoul, home],
            measuredOutcome: TravelMeasuredOutcome(
                destinationStabilityDays: nil, homeStabilityDays: nil,
                confoundersRawValue: 0, lastMeasuredAt: measuredAt,
                stopOutcomes: [TravelStopMeasuredOutcome(
                    stopID: seoul.id, stabilityDays: 1, confoundersRawValue: 0, lastMeasuredAt: measuredAt
                )])
        )
        let stableInSeoul = local("Asia/Seoul", 2026, 9, 12, 12)

        XCTAssertEqual(episode.phase(at: stableInSeoul), .destinationStable)
        XCTAssertEqual(episode.phaseBasis(at: stableInSeoul), .measuredStability)
        XCTAssertEqual(episode.currentPhaseEnd(at: stableInSeoul), home.departure,
                       "La estancia estable de Seúl termina al salir de Seúl, no en la vuelta global ni en Bangkok.")
    }

    // Y vaciarla la quita sin tocar el destino intermedio.
    func testClearingTheReturnKeepsTheIntermediateStop() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        let home = segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 20, 11),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 9, 20, 20))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))
        episode.stops.append(TravelStop(flights: [home]))

        episode.returnFlights = []

        XCTAssertEqual(episode.stops.count, 2)
        XCTAssertEqual(episode.stops.last?.destinationTimeZoneID, "Asia/Seoul")
        XCTAssertFalse(episode.returnsHome)
    }

    // El fallo que se veía en la app: añades Seúl, guardas, reabres y sólo
    // quedan ida y vuelta. Reconstruir el episodio desde outbound/return
    // DESCARTA los destinos intermedios.
    func testRebuildingAnEpisodeKeepsItsIntermediateStops() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 17, 0),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 17, 7))
        let home = segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 19, 11),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 9, 19, 22))
        var original = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                     destinationTimeZoneID: "Asia/Bangkok",
                                     outboundFlights: [toBangkok])
        original.stops.append(TravelStop(flights: [toSeoul]))
        original.stops.append(TravelStop(flights: [home]))

        // Igual que hace el guardado de la pantalla de edición.
        let rebuilt = TravelEpisode(
            id: original.id, title: original.title,
            homeTimeZoneID: original.homeTimeZoneID, destinationTimeZoneID: original.destinationTimeZoneID,
            stops: original.stops, measuredOutcome: original.measuredOutcome)

        XCTAssertEqual(rebuilt.stops.count, 3, "Seúl no se puede perder al guardar.")
        XCTAssertEqual(rebuilt.intermediateStops.first?.destinationTimeZoneID, "Asia/Seoul")
        XCTAssertEqual(rebuilt.stops.map(\.id), original.stops.map(\.id),
                       "Y conserva la identidad de cada parada, que es lo que la UI usa para editarlas.")
    }

    // El aviso rojo permanente: con varias paradas la vuelta sale de la ÚLTIMA
    // parada, no del destino declarado. Compararla contra el declarado marcaba
    // como incoherente un itinerario perfectamente válido.
    func testMultiStopItineraryIsNotFlaggedAsInconsistent() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 17, 0),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 17, 7))
        let home = segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 19, 11),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 9, 19, 22))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Bangkok",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))
        episode.stops.append(TravelStop(flights: [home]))

        XCTAssertTrue(episode.declaredZonesMatchFlights,
                      "Madrid→Bangkok→Seúl→Madrid es coherente y no puede dar aviso.")
    }

    // Pero un hueco real SÍ se detecta: si un tramo no sale de donde aterrizó
    // el anterior, el itinerario está roto. Antes esto no se comprobaba.
    func testAGapBetweenStopsIsStillFlagged() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        // Sale de Tokio, pero aterrizaste en Bangkok: falta un trayecto.
        let fromNowhere = segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 9, 17, 0),
                                  "Asia/Seoul", local("Asia/Seoul", 2026, 9, 17, 3))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Bangkok",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [fromNowhere]))

        XCTAssertFalse(episode.declaredZonesMatchFlights,
                       "Un salto de Bangkok a Tokio que nadie voló es un hueco real.")
    }

    // MULTIDESTINO, fases. El itinerario real que motivó esto: Madrid →
    // Bangkok (estancia) → Seúl (estancia) → Madrid. Con el modelo de ida y
    // vuelta, meter Seúl como escala marcaba los días en Bangkok como
    // "en tránsito" y la adaptación a Bangkok no existía.
    func testEachStopGetsItsOwnTransitAdaptationAndStay() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        let home = segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 20, 11),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 9, 20, 20))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))
        episode.stops.append(TravelStop(flights: [home]))

        // En vuelo a Bangkok.
        XCTAssertEqual(episode.phase(at: local("Asia/Bangkok", 2026, 9, 12, 2)), .outboundTransit)
        // Ya en Bangkok: adaptación a Bangkok — NO "en tránsito", que es lo
        // que la escala hacía.
        XCTAssertEqual(episode.phase(at: local("Asia/Bangkok", 2026, 9, 13, 12)), .destinationAdaptation)
        // En vuelo a Seúl: vuelve a ser tránsito de ida, no vuelta.
        XCTAssertEqual(episode.phase(at: local("Asia/Seoul", 2026, 9, 16, 14)), .outboundTransit)
        // En Seúl: su propia adaptación, no la estancia de Bangkok.
        XCTAssertEqual(episode.phase(at: local("Asia/Seoul", 2026, 9, 17, 12)), .destinationAdaptation)
        // Volando a casa.
        XCTAssertEqual(episode.phase(at: local("Europe/Madrid", 2026, 9, 20, 15)), .returnTransit)
        // Y en casa, readaptación.
        XCTAssertEqual(episode.phase(at: local("Europe/Madrid", 2026, 9, 21, 12)), .homeReadaptation)
    }

    // La adaptación de cada parada se calcula sobre SU salto. Seúl son +2 h
    // desde Bangkok: si se calculara sobre el acumulado (+8 h desde Madrid),
    // la app pediría días de adaptación que no corresponden.
    func testIntermediateStopAdaptsOverItsOwnJumpNotTheCumulativeOne() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))

        let bangkokEnd = episode.adaptationEnd(forStopAt: 0)!.date
        let seoulEnd = episode.adaptationEnd(forStopAt: 1)!.date
        let bangkokDays = bangkokEnd.timeIntervalSince(episode.stops[0].arrival!) / 86_400
        let seoulDays = seoulEnd.timeIntervalSince(episode.stops[1].arrival!) / 86_400

        XCTAssertGreaterThan(bangkokDays, seoulDays,
                             "+5 h a Bangkok cuesta más adaptación que las +2 h de Bangkok a Seúl.")
        XCTAssertGreaterThan(seoulDays, 0, "Pero Seúl SÍ tiene adaptación propia: no es cero.")
    }

    // Y el caso de ida y vuelta de siempre se comporta exactamente igual que
    // antes: la generalización no puede cambiar lo que ya funcionaba.
    func testTwoStopTripKeepsItsOriginalPhaseSequence() {
        let out = segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 1, 10),
                          "Asia/Tokyo", local("Asia/Tokyo", 2026, 7, 2, 8))
        let back = segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 7, 12, 10),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 7, 12, 18))
        let episode = TravelEpisode(title: "Tokio", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Tokyo",
                                    outboundFlights: [out], returnFlights: [back])

        XCTAssertEqual(episode.phase(at: local("Europe/Madrid", 2026, 6, 28, 12)), .preDeparture)
        XCTAssertEqual(episode.phase(at: local("Asia/Tokyo", 2026, 7, 2, 2)), .outboundTransit)
        XCTAssertEqual(episode.phase(at: local("Asia/Tokyo", 2026, 7, 3, 12)), .destinationAdaptation)
        XCTAssertEqual(episode.phase(at: local("Asia/Tokyo", 2026, 7, 10, 12)), .destinationStable)
        XCTAssertEqual(episode.phase(at: local("Asia/Tokyo", 2026, 7, 12, 14)), .returnTransit)
        XCTAssertEqual(episode.phase(at: local("Europe/Madrid", 2026, 7, 13, 12)), .homeReadaptation)
    }

    // Dónde estás AHORA deja de ser un campo declarado y pasa a ser la parada
    // vigente: con varias paradas, "el destino" ya no es un sitio.
    func testCurrentDestinationFollowsTheStopYouAreIn() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))

        XCTAssertEqual(episode.currentDestinationTimeZoneID(at: local("Europe/Madrid", 2026, 9, 1, 12)),
                       "Europe/Madrid", "Antes de salir, estás en casa.")
        XCTAssertEqual(episode.currentDestinationTimeZoneID(at: local("Asia/Bangkok", 2026, 9, 14, 12)),
                       "Asia/Bangkok")
        XCTAssertEqual(episode.currentDestinationTimeZoneID(at: local("Asia/Seoul", 2026, 9, 18, 12)),
                       "Asia/Seoul")
    }

    // MULTIDESTINO. Lo que no se puede perder al migrar: `measuredOutcome`
    // guarda los días reales hasta la estabilidad de cada viaje pasado, y de
    // ahí salen las tasas de reajuste aprendidas. Las series de HealthKit sólo
    // llegan 90 días atrás, así que esas mediciones NO se pueden recalcular:
    // si se pierden en la migración, se pierden para siempre.
    func testEpisodeSavedBeforeMultiDestinationKeepsItsLearnedOutcome() throws {
        // JSON exactamente como lo escribía el formato anterior: ida y vuelta
        // como dos listas, sin `stops`.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Tokio",
          "homeTimeZoneID": "Europe/Madrid",
          "destinationTimeZoneID": "Asia/Tokyo",
          "outboundFlights": [{
            "id": "22222222-2222-2222-2222-222222222222",
            "departure": 800000000, "arrival": 800050000,
            "originTimeZoneID": "Europe/Madrid", "destinationTimeZoneID": "Asia/Tokyo"
          }],
          "returnFlights": [{
            "id": "33333333-3333-3333-3333-333333333333",
            "departure": 800600000, "arrival": 800650000,
            "originTimeZoneID": "Asia/Tokyo", "destinationTimeZoneID": "Europe/Madrid"
          }],
          "isCancelled": false,
          "note": "",
          "measuredOutcome": {
            "destinationStabilityDays": 4.5,
            "homeStabilityDays": 2.5,
            "confoundersRawValue": 0,
            "lastMeasuredAt": 800700000
          }
        }
        """
        let episode = try JSONDecoder().decode(TravelEpisode.self, from: Data(json.utf8))

        // Lo aprendido sobrevive intacto.
        XCTAssertEqual(episode.measuredOutcome?.destinationStabilityDays, 4.5)
        XCTAssertEqual(episode.measuredOutcome?.homeStabilityDays, 2.5)
        // Y el recorrido se reinterpreta como dos tramos, que es lo que ida y
        // vuelta ya significaban.
        XCTAssertEqual(episode.stops.count, 2)
        XCTAssertEqual(episode.stops.first?.destinationTimeZoneID, "Asia/Tokyo")
        XCTAssertTrue(episode.returnsHome)
        XCTAssertTrue(episode.intermediateStops.isEmpty)
        // Las lecturas de ida/vuelta siguen dando lo mismo, así que el motor
        // de aprendizaje —que lee outboundShiftHours y returnShiftHours— no
        // nota el cambio.
        XCTAssertEqual(episode.outboundFlights.count, 1)
        XCTAssertEqual(episode.returnFlights.count, 1)
        XCTAssertEqual(episode.outboundShiftHours, -episode.returnShiftHours, accuracy: 0.001)
    }

    // Un viaje en curso sin vuelta dada de alta —el caso real del usuario—
    // migra a UN tramo y sigue sin vuelta. No se inventa una.
    func testInProgressEpisodeWithoutReturnMigratesToASingleLeg() throws {
        let json = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "title": "Bangkok",
          "homeTimeZoneID": "Europe/Madrid",
          "destinationTimeZoneID": "Asia/Bangkok",
          "outboundFlights": [{
            "id": "55555555-5555-5555-5555-555555555555",
            "departure": 800000000, "arrival": 800059400,
            "originTimeZoneID": "Europe/Madrid", "destinationTimeZoneID": "Asia/Bangkok"
          }],
          "returnFlights": [],
          "isCancelled": false,
          "note": ""
        }
        """
        let episode = try JSONDecoder().decode(TravelEpisode.self, from: Data(json.utf8))

        XCTAssertEqual(episode.stops.count, 1)
        XCTAssertFalse(episode.returnsHome, "Sin vuelta no hay tramo de vuelta que reconocer.")
        XCTAssertTrue(episode.returnFlights.isEmpty)
        XCTAssertTrue(episode.intermediateStops.isEmpty)
    }

    // Y el recorrido de tres destinos que motivó todo esto.
    func testMultiDestinationTripSeparatesOutboundIntermediateAndReturn() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        let toSeoul = segment("Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 16, 10),
                              "Asia/Seoul", local("Asia/Seoul", 2026, 9, 16, 18))
        let home = segment("Asia/Seoul", local("Asia/Seoul", 2026, 9, 20, 11),
                           "Europe/Madrid", local("Europe/Madrid", 2026, 9, 20, 20))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    outboundFlights: [toBangkok])
        episode.stops.append(TravelStop(flights: [toSeoul]))
        episode.stops.append(TravelStop(flights: [home]))

        XCTAssertEqual(episode.stops.count, 3)
        XCTAssertEqual(episode.outboundFlights.count, 1, "La ida sigue siendo el primer tramo.")
        XCTAssertEqual(episode.intermediateStops.count, 1)
        XCTAssertEqual(episode.intermediateStops.first?.destinationTimeZoneID, "Asia/Seoul")
        XCTAssertTrue(episode.returnsHome)
        XCTAssertEqual(episode.returnFlights.count, 1)

        // Cada tramo lleva SU propio salto: Seúl son +2 h desde Bangkok, no
        // +8 desde Madrid. Eso es lo que la escala no podía expresar.
        XCTAssertEqual(episode.stops[1].shiftHours, 2, accuracy: 0.001)
        XCTAssertEqual(episode.stops[0].shiftHours, 5, accuracy: 0.001)
    }

    func testCanonicalDestinationFollowsTheFirstRealStopWhenSaving() {
        let toBangkok = segment("Europe/Madrid", local("Europe/Madrid", 2026, 9, 11, 12),
                                "Asia/Bangkok", local("Asia/Bangkok", 2026, 9, 12, 9))
        var episode = TravelEpisode(title: "Asia", homeTimeZoneID: "Europe/Madrid",
                                    destinationTimeZoneID: "Asia/Seoul",
                                    stops: [TravelStop(flights: [toBangkok])])

        episode.synchronizeCanonicalDestination()

        XCTAssertEqual(episode.destinationTimeZoneID, "Asia/Bangkok",
                       "El campo compatible no puede discrepar del primer destino real del itinerario.")
    }

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
