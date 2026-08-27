import XCTest
@testable import EterHealth

// PR16. El aprendizaje de la respuesta individual a los viajes: tasas por
// dirección, barra de evidencia, topes contra el prior, episodios confundidos,
// y que lo aprendido llegue de verdad al gemelo por la misma ruta única.
@MainActor
final class TravelLearningTests: XCTestCase {

    private let neutralProfile = AthletePlanProfile.angelDefault
    private let neutralCalibration = TwinCalibration.none
    private let neutralAnchor = PersonalReadinessAnchor.provisional

    private func local(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d; components.hour = h
        components.timeZone = TimeZone(identifier: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: components)!
    }

    private func segment(_ from: String, _ departure: Date, _ to: String, _ arrival: Date) -> FlightSegment {
        FlightSegment(departure: departure, arrival: arrival, originTimeZoneID: from, destinationTimeZoneID: to)
    }

    /// Un viaje Madrid → Tokio (8 h al este) y vuelta (8 al oeste), con la
    /// medición ya tomada. `index` separa episodios moviendo el DÍA dentro de
    /// marzo, no el mes: Madrid está en CET todo marzo, así que los episodios
    /// comparten desplazamiento y las tasas se pueden calcular a mano.
    ///
    /// Variando el mes —como hacía la primera versión de este fixture— Madrid
    /// pasaba de CET (+1) a CEST (+2) y el mismo trayecto desplazaba 8 h en
    /// marzo y 7 en junio, así que las medianas escritas a mano no cuadraban.
    /// El modelo estaba bien; el fixture no. Queda anotado porque es
    /// exactamente el comportamiento que TravelEpisodeTests fija a propósito.
    private func measuredTokyo(index: Int, destinationDays: Double?, homeDays: Double?,
                               confounders: TravelConfounders = .none) -> TravelEpisode {
        let out = 1 + index, back = 20 + index
        return TravelEpisode(
            title: "Tokio \(index)", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Asia/Tokyo",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 3, out, 11),
                                      "Asia/Tokyo", local("Asia/Tokyo", 2026, 3, out + 1, 8))],
            returnFlights: [segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 3, back, 10),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 3, back, 16))],
            measuredOutcome: TravelMeasuredOutcome(
                destinationStabilityDays: destinationDays, homeStabilityDays: homeDays,
                confoundersRawValue: confounders.rawValue,
                lastMeasuredAt: local("Europe/Madrid", 2026, 3, 27, 12)))
    }

    // MARK: - Lo que se aprende es una TASA, no una duración

    func testLearningARateMakesTripsOfDifferentSizesComparable() {
        // El punto de aprender h/día y no "días hasta estabilizar": un
        // Madrid–Nueva York de 6 h y un Madrid–Tokio de 8 h no son comparables
        // en días, pero sí en tasa. Los dos entran en la misma estimación, y
        // por eso NO hace falta exigir que la diferencia horaria sea parecida.
        let tokyo = measuredTokyo(index: 0, destinationDays: 4, homeDays: nil)         // 8 h / 4 d = 2.0
        let newYork = TravelEpisode(
            title: "Nueva York", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "America/New_York",
            outboundFlights: [segment("America/New_York", local("America/New_York", 2026, 5, 2, 10),
                                      "Europe/Madrid", local("Europe/Madrid", 2026, 5, 2, 22))],
            returnFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 5, 20, 10),
                                    "America/New_York", local("America/New_York", 2026, 5, 20, 13))],
            measuredOutcome: TravelMeasuredOutcome(destinationStabilityDays: 3, homeStabilityDays: nil,
                                                   confoundersRawValue: 0,
                                                   lastMeasuredAt: local("Europe/Madrid", 2026, 5, 25, 12)))
        // Nueva York → Madrid es hacia el ESTE (+6): 6 h / 3 d = 2.0.
        let outcomes = TravelLearningEngine.outcomes(from: [tokyo, newYork])
        let advance = outcomes.filter { $0.isAdvance && $0.leg == .outbound }
        XCTAssertEqual(advance.count, 2, "Los dos tramos de ida van al este y son comparables como tasa.")
        for outcome in advance {
            XCTAssertEqual(outcome.observedHoursPerDay!, 2.0, accuracy: 0.001)
        }
        guard let rate = TravelLearningEngine.rate(isAdvance: true, from: outcomes) else {
            return XCTFail("Dos tramos usables tienen que producir tasa.")
        }
        XCTAssertEqual(rate.episodesUsed, 2)
        // Mediana 2.0, pero el tope es ×2 del prior (1.0) → exactamente 2.0.
        XCTAssertEqual(rate.medianHoursPerDay, 2.0, accuracy: 0.001)
        XCTAssertEqual(rate.hoursPerDay, 2.0, accuracy: 0.001)
        XCTAssertTrue(rate.isFasterThanPrior)
    }

    func testEastAndWestAreLearnedSeparatelyAndNeverAveraged() {
        // Adelantar y retrasar fase son fisiologías distintas: un único "tu jet
        // lag" promediando las dos esconde justo lo que hace útil el modelo.
        let episodes = [measuredTokyo(index: 0, destinationDays: 8, homeDays: 2),
                        measuredTokyo(index: 1, destinationDays: 8, homeDays: 2)]
        let profile = TravelLearningEngine.profile(episodes: episodes)
        // Ida: 8 h al este en 8 días = 1.0 h/día, igual que el prior.
        XCTAssertEqual(profile.advance?.hoursPerDay, 1.0)
        // Vuelta: 8 h al oeste en 2 días = 4.0, acotado a ×2 del prior (1.5) = 3.0.
        XCTAssertEqual(profile.delay?.medianHoursPerDay, 4.0)
        XCTAssertEqual(profile.delay?.hoursPerDay, 3.0)
        XCTAssertEqual(profile.delay?.isBounded, true)
        // Y las dos direcciones llegan separadas a las tasas inyectables.
        XCTAssertEqual(profile.rates.advanceHoursPerDay, 1.0)
        XCTAssertEqual(profile.rates.delayHoursPerDay, 3.0)
    }

    func testOneDirectionCanBeLearnedWhileTheOtherStaysOnThePrior() {
        // Esperar a tener las dos sería desperdiciar evidencia real: mezclar
        // una tasa medida con un prior es correcto, y la UI dice cuál es cuál.
        let episodes = [measuredTokyo(index: 0, destinationDays: 5, homeDays: nil),
                        measuredTokyo(index: 1, destinationDays: 5, homeDays: nil)]
        let profile = TravelLearningEngine.profile(episodes: episodes)
        XCTAssertNotNil(profile.advance)
        XCTAssertNil(profile.delay, "Sin tramos de vuelta medidos no se afirma nada sobre el oeste.")
        XCTAssertEqual(profile.rates.advanceHoursPerDay, 8.0 / 5.0, accuracy: 0.001)
        XCTAssertEqual(profile.rates.delayHoursPerDay, ReentrainmentRates.prior.delayHoursPerDay)
    }

    // MARK: - Barra de evidencia y topes

    func testOneMeasuredLegIsNotARate() {
        let profile = TravelLearningEngine.profile(episodes: [measuredTokyo(index: 0, destinationDays: 4, homeDays: 2)])
        XCTAssertNil(profile.advance, "Un tramo no es una tasa.")
        XCTAssertNil(profile.delay)
        XCTAssertFalse(profile.hasLearnedAnything)
        XCTAssertEqual(profile.rates, .prior, "Sin aprendizaje, exactamente el prior.")
        // Pero el tramo medido SÍ se muestra: hay algo que contar aunque no
        // haya todavía nada que afirmar.
        XCTAssertEqual(profile.measuredOutcomes.count, 2)
    }

    func testConfidenceRisesWithTheThirdMeasuredLeg() {
        let two = TravelLearningEngine.profile(episodes: (0...1).map {
            measuredTokyo(index: $0, destinationDays: 4, homeDays: nil) })
        let three = TravelLearningEngine.profile(episodes: (0...2).map {
            measuredTokyo(index: $0, destinationDays: 4, homeDays: nil) })
        XCTAssertEqual(two.advance?.episodesUsed, 2)
        XCTAssertEqual(three.advance?.episodesUsed, 3)
        XCTAssertGreaterThan(three.advance!.confidence.score, two.advance!.confidence.score)
        XCTAssertEqual(two.advance?.confidence.level, .medium)
        XCTAssertEqual(three.advance?.confidence.level, .high)
    }

    func testTheLearnedRateIsBoundedAgainstThePriorInBothDirections() {
        // Con dos muestras, un error de medición basta para producir una tasa
        // absurda. Los topes son ×0.5 y ×2 del prior.
        let absurdlyFast = TravelLearningEngine.profile(episodes: (0...1).map {
            measuredTokyo(index: $0, destinationDays: 0.25, homeDays: nil) })   // 8 h / 0.25 d = 32
        XCTAssertEqual(absurdlyFast.advance!.medianHoursPerDay, 32, accuracy: 0.001)
        XCTAssertEqual(absurdlyFast.advance!.hoursPerDay, 2.0, accuracy: 0.001, "×2 del prior de 1.0.")
        XCTAssertEqual(absurdlyFast.advance?.isBounded, true)

        let absurdlySlow = TravelLearningEngine.profile(episodes: (0...1).map {
            measuredTokyo(index: $0, destinationDays: 40, homeDays: nil) })     // 8 / 40 = 0.2
        XCTAssertEqual(absurdlySlow.advance!.hoursPerDay, 0.5, accuracy: 0.001, "×0.5 del prior.")
        // Y la mediana cruda se conserva para poder decirlo en la UI.
        XCTAssertEqual(absurdlySlow.advance!.medianHoursPerDay, 0.2, accuracy: 0.001)
    }

    func testMedianNotMeanSoOneBadTripDoesNotDragTheEstimate() {
        // Tres tramos: dos coherentes y uno disparatado. La mediana los
        // sobrevive; la media no lo haría.
        let episodes = [measuredTokyo(index: 0, destinationDays: 8, homeDays: nil),
                        measuredTokyo(index: 1, destinationDays: 8, homeDays: nil),
                        measuredTokyo(index: 2, destinationDays: 1, homeDays: nil)]
        let rate = TravelLearningEngine.profile(episodes: episodes).advance!
        XCTAssertEqual(rate.medianHoursPerDay, 1.0, accuracy: 0.001, "Mediana de [1.0, 1.0, 8.0].")
        XCTAssertEqual(rate.episodesUsed, 3)
    }

    // MARK: - Qué queda fuera

    func testConfoundedEpisodesAreExcludedFromTheEstimateAndCounted() {
        let episodes = [measuredTokyo(index: 0, destinationDays: 8, homeDays: nil),
                        measuredTokyo(index: 1, destinationDays: 8, homeDays: nil),
                        measuredTokyo(index: 2, destinationDays: 1, homeDays: nil,
                                      confounders: [.illness, .alcohol])]
        let rate = TravelLearningEngine.profile(episodes: episodes).advance!
        XCTAssertEqual(rate.episodesUsed, 2, "El episodio confundido no entra.")
        XCTAssertEqual(rate.episodesExcluded, 1)
        XCTAssertEqual(rate.medianHoursPerDay, 1.0, accuracy: 0.001, "Y no arrastra la mediana.")
        XCTAssertTrue(rate.confidence.reason.contains("confundido"))
        // Pero se sigue mostrando en el histórico, con su motivo: es
        // información, sólo no es evidencia.
        // El tramo de IDA concretamente: los outcomes vienen ordenados por
        // llegada descendente, así que el primero de este episodio es la
        // vuelta, que aquí no tiene medición.
        let outcome = TravelLearningEngine.outcomes(from: episodes)
            .first { $0.confounders.contains(.illness) && $0.leg == .outbound }
        XCTAssertNotNil(outcome)
        XCTAssertFalse(outcome!.isUsableForLearning)
        XCTAssertEqual(outcome!.actualDays, 1)
    }

    func testCancelledAndKeepHomeScheduleEpisodesNeverEnterTheEstimate() {
        var cancelled = measuredTokyo(index: 0, destinationDays: 4, homeDays: nil)
        cancelled.isCancelled = true
        // Estancia de 36 h: política automática = mantener horario de origen,
        // así que nunca se intentó adaptarse y medir su "tasa" daría un número
        // que no describe ninguna re-sincronización.
        let shortStay = TravelEpisode(
            title: "Reunión", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "America/New_York",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 6, 9),
                                      "America/New_York", local("America/New_York", 2026, 7, 6, 12))],
            returnFlights: [segment("America/New_York", local("America/New_York", 2026, 7, 7, 18),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 7, 8, 7))],
            measuredOutcome: TravelMeasuredOutcome(destinationStabilityDays: 1, homeStabilityDays: 1,
                                                   confoundersRawValue: 0,
                                                   lastMeasuredAt: local("Europe/Madrid", 2026, 7, 10, 12)))
        XCTAssertEqual(shortStay.resolvedStayPolicy, .keepHomeSchedule)
        XCTAssertTrue(TravelLearningEngine.outcomes(from: [cancelled, shortStay]).isEmpty)
        XCTAssertEqual(TravelLearningEngine.profile(episodes: [cancelled, shortStay]).rates, .prior)
    }

    func testALegThatNeverStabilisedIsNilNotALargeNumber() {
        // "No se confirmó estabilidad" es información distinta de "tardó
        // mucho", y sustituirla por un número grande sesgaría la tasa a la baja.
        let episodes = (0...1).map { measuredTokyo(index: $0, destinationDays: nil, homeDays: nil) }
        let outcomes = TravelLearningEngine.outcomes(from: episodes)
        XCTAssertEqual(outcomes.count, 4, "Los cuatro tramos existen...")
        XCTAssertTrue(outcomes.allSatisfy { $0.actualDays == nil }, "...pero ninguno tiene medición.")
        XCTAssertTrue(outcomes.allSatisfy { $0.observedHoursPerDay == nil })
        XCTAssertNil(TravelLearningEngine.profile(episodes: episodes).advance)
    }

    func testThePriorShownForComparisonIsAlwaysTheLiteratureOneNotWhatWasLearned() {
        // Si `priorDays` usara las tasas aprendidas, la pantalla "prior frente
        // a real" se convertiría en un espejo de sí misma.
        let episodes = (0...2).map { measuredTokyo(index: $0, destinationDays: 2, homeDays: nil) }
        let profile = TravelLearningEngine.profile(episodes: episodes)
        XCTAssertNotNil(profile.advance, "Sanity check: aquí ya hay tasa aprendida.")
        for outcome in profile.outcomes where outcome.leg == .outbound {
            XCTAssertEqual(outcome.priorDays, 8, accuracy: 0.001,
                           "8 h al este entre 1 h/día del PRIOR = 8 días, no los 2 medidos.")
            XCTAssertEqual(outcome.deltaVersusPriorDays!, -6, accuracy: 0.001)
        }
    }

    // MARK: - El store congela la medición

    func testTheFirstConfirmationWinsAndConfoundersAccumulate() {
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        store.save(TravelEpisode(id: episode.id, title: episode.title,
                                 homeTimeZoneID: episode.homeTimeZoneID,
                                 destinationTimeZoneID: episode.destinationTimeZoneID,
                                 outboundFlights: episode.outboundFlights,
                                 returnFlights: episode.returnFlights))

        store.recordStability(episodeID: episode.id, leg: .outbound, days: 4, confounders: .alcohol)
        XCTAssertEqual(store.episodes.first?.measuredOutcome?.destinationStabilityDays, 4)
        // Una segunda confirmación del MISMO tramo se ignora: medir otra vez
        // días después mediría cuántos llevas estable, no cuántos tardaste.
        store.recordStability(episodeID: episode.id, leg: .outbound, days: 9, confounders: .none)
        XCTAssertEqual(store.episodes.first?.measuredOutcome?.destinationStabilityDays, 4)
        // La vuelta es un tramo distinto y sí se registra, y los confusores se
        // acumulan en vez de reemplazarse.
        store.recordStability(episodeID: episode.id, leg: .homeReturn, days: 2, confounders: .illness)
        let outcome = store.episodes.first?.measuredOutcome
        XCTAssertEqual(outcome?.homeStabilityDays, 2)
        XCTAssertEqual(outcome?.confounders, [.alcohol, .illness])
    }

    func testMeasuredOutcomeSurvivesJSONSoLearningOutlivesTheNinetyDayWindow() {
        // La razón de ser de persistir la medición: las series de HRV y sueño
        // sólo llegan 90 días atrás, y con tres o cuatro viajes al año un
        // aprendiz que sólo leyera esa ventana casi nunca tendría dos tramos
        // comparables. Esto comprueba que la medición sobrevive al viaje de
        // ida y vuelta por disco.
        let episodes = (0...1).map { measuredTokyo(index: $0, destinationDays: 5, homeDays: 3) }
        let data = try! JSONEncoder().encode(episodes)
        let decoded = try! JSONDecoder().decode([TravelEpisode].self, from: data)
        XCTAssertEqual(decoded, episodes)
        XCTAssertEqual(TravelLearningEngine.profile(episodes: decoded).rates,
                       TravelLearningEngine.profile(episodes: episodes).rates)
        XCTAssertNotEqual(TravelLearningEngine.profile(episodes: decoded).rates, .prior,
                          "Y con esa medición ya se ha aprendido algo, o el test no prueba nada.")
    }

    // MARK: - Lo aprendido llega al gemelo por la ruta única

    func testLearnedRatesReachTheImpactThePhasesAndStepAlike() {
        // Tres tramos rápidos al este: la tasa aprendida es el tope, 2 h/día.
        let history = (0...2).map { measuredTokyo(index: $0, destinationDays: 2, homeDays: nil) }
        let learned = TravelLearningEngine.profile(episodes: history).rates
        XCTAssertEqual(learned.advanceHoursPerDay, 2.0, accuracy: 0.001)

        let episode = measuredTokyo(index: 3, destinationDays: nil, homeDays: nil)
        let arrival = episode.destinationArrival!

        // 1. La duración de la fase de adaptación se acorta: 8 h a 2 h/día = 4
        //    días, no los 8 del prior.
        XCTAssertEqual(episode.destinationAdaptationDays(), 8, accuracy: 0.001)
        XCTAssertEqual(episode.destinationAdaptationDays(rates: learned), 4, accuracy: 0.001)

        // 2. Y con ella, la fase que reporta el episodio en un día concreto.
        let day6 = arrival.addingTimeInterval(6 * 86_400)
        XCTAssertEqual(episode.phase(at: day6), .destinationAdaptation)
        XCTAssertEqual(episode.phase(at: day6, rates: learned), .destinationStable)

        // 3. El desajuste que queda a los 2 días: 6 h con el prior, 4 con lo
        //    aprendido.
        let day2 = arrival.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(TravelImpactEngine.impact(episode: episode, at: day2).circadianOffsetHours,
                       6, accuracy: 0.1)
        XCTAssertEqual(TravelImpactEngine.impact(episode: episode, at: day2, rates: learned).circadianOffsetHours,
                       4, accuracy: 0.1)

        // 4. Y step() decae a la misma tasa, no al prior — si no, hoy y mañana
        //    discreparían.
        var state = TwinPhysiology.baseline(asOf: arrival)
        state.circadianOffsetHours = 8
        XCTAssertEqual(step(state, session: nil, recoverySignals: .none, dtDays: 1).circadianOffsetHours,
                       7, accuracy: 0.001)
        XCTAssertEqual(step(state, session: nil, recoverySignals: .none, dtDays: 1, rates: learned).circadianOffsetHours,
                       6, accuracy: 0.001)
    }

    func testAssessUsesTheLearnedRatesAndPublishesThemForTheWeekAhead() {
        let history = (0...2).map { measuredTokyo(index: $0, destinationDays: 2, homeDays: nil) }
        let active = measuredTokyo(index: 3, destinationDays: nil, homeDays: nil)
        let now = active.destinationArrival!.addingTimeInterval(2 * 86_400)
        func assess(withHistory: Bool) -> TwinAssessment {
            TwinEngine.assess(health: HealthStore(), imports: ImportStore(persistToDisk: false), checkIn: nil,
                              context: TwinContext(profile: neutralProfile, events: [], reviews: [],
                                                   activeInjuries: [], calibration: neutralCalibration,
                                                   personalAnchor: neutralAnchor, travel: active,
                                                   travelHistory: withHistory ? history + [active] : [active]),
                              now: now)
        }
        let withPrior = assess(withHistory: false)
        let withLearned = assess(withHistory: true)

        XCTAssertEqual(withPrior.travelRates, .prior)
        XCTAssertEqual(withLearned.travelRates.advanceHoursPerDay, 2.0, accuracy: 0.001)
        // A los dos días quedan 6 h con el prior y 4 con lo aprendido, así que
        // el desajuste —y su coste— tienen que ser menores.
        XCTAssertLessThan(abs(withLearned.travel.circadianOffsetHours),
                          abs(withPrior.travel.circadianOffsetHours))
        XCTAssertGreaterThan(withLearned.travel.circadianReadinessCost,
                             withPrior.travel.circadianReadinessCost,
                             "Menos desajuste tiene que costar menos (los dos son negativos).")
        // Y la fisiología lleva el mismo estado que la señal, como en PR15.
        XCTAssertEqual(withLearned.physiology.circadianOffsetHours,
                       withLearned.travel.circadianOffsetHours, accuracy: 0.001)
    }

    // MARK: - La asociación de hábitos ya no lee un campo muerto

    func testTravelHabitOccurrencesComeFromEpisodePhasesNotTheDeadDailyField() {
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let after = episode.homeArrival!.addingTimeInterval(30 * 86_400)
        let occurrences = HabitAssociationEngine.travelOccurrences(episodes: [episode], now: after)
        XCTAssertFalse(occurrences.isEmpty, "El campo diario ya no se escribe: si esto sale vacío, la asociación está muerta.")
        XCTAssertTrue(occurrences.allSatisfy { $0.kind == .travel })
        // Sólo las fases que de verdad cargan. La estancia estable no cuenta:
        // si contara, un viaje de tres semanas etiquetaría veinte días como
        // "viaje" y la asociación mediría días normales en otro país.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for occurrence in occurrences {
            let phase = episode.phase(at: occurrence.date)
            XCTAssertTrue([.outboundTransit, .destinationAdaptation, .returnTransit, .homeReadaptation].contains(phase),
                          "\(occurrence.date) está en fase \(phase.rawValue), que no carga.")
        }
        // Y siempre marcadas como solapadas: un día de viaje trae sueño
        // alterado, comida distinta y a veces alcohol, así que la atribución
        // nunca es limpia y ConfidenceEngine tiene que saberlo.
        XCTAssertTrue(occurrences.allSatisfy(\.overlapsOtherFactors))
        // Un viaje cancelado no genera ninguna.
        var cancelled = episode
        cancelled.isCancelled = true
        XCTAssertTrue(HabitAssociationEngine.travelOccurrences(episodes: [cancelled], now: after).isEmpty)
    }
}
