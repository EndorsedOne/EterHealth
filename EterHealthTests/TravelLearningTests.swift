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

    // MARK: - PR17: los cinco puntos de la review

    /// Bandas personales de fixture. Duplicado de TravelImpactTests a
    /// propósito: son dos suites con fixtures independientes, y compartirlo
    /// las acoplaría sin ganar nada.
    private func baseline(sleepFloor: Double, hrvFloor: Double) -> PersonalBaselineProfile {
        func metric(_ name: String, lower: Double, upper: Double) -> PersonalMetricBaseline {
            PersonalMetricBaseline(name: name, current: nil, expected: (lower + upper) / 2,
                                   lowerNormal: lower, upperNormal: upper, deviation: 0,
                                   samples: 30, confidence: 80, context: "", measuredAt: nil)
        }
        return PersonalBaselineProfile(
            hrv: metric("HRV", lower: hrvFloor, upper: 120),
            restingHeartRate: metric("Pulso", lower: 40, upper: 58),
            sleep: metric("Sueño", lower: sleepFloor, upper: 9),
            wristTemperature: metric("Temperatura", lower: 35, upper: 37),
            respiratoryRate: metric("Respiratoria", lower: 12, upper: 18),
            muscleRecoveryHours: [:]
        )
    }

    func testEditingATripNeverWipesTheMeasuredOutcome() {
        // El peor de los cinco: el editor reconstruía el episodio sin
        // `measuredOutcome`, así que cambiar una nota borraba los días de
        // estabilidad ya medidos — y para un viaje pasado la pérdida es
        // permanente, porque las series que los demostraban ya no están en la
        // ventana de 90 días de HealthKit.
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        let measured = measuredTokyo(index: 0, destinationDays: 4, homeDays: 2)
        store.save(measured)
        XCTAssertNotNil(store.episodes.first?.measuredOutcome)

        // Una edición que NO trae la medición (exactamente lo que hacía el
        // editor) no puede perderla: el store la conserva por construcción.
        var edited = measured
        edited.note = "cambio una nota y nada más"
        edited.measuredOutcome = nil
        store.save(edited)
        XCTAssertEqual(store.episodes.first?.note, "cambio una nota y nada más")
        XCTAssertEqual(store.episodes.first?.measuredOutcome?.destinationStabilityDays, 4,
                       "La medición sobrevive a un save que no la trae.")
        XCTAssertEqual(store.episodes.first?.measuredOutcome?.homeStabilityDays, 2)
        // Y el aprendizaje sigue en pie después de la edición.
        XCTAssertEqual(TravelLearningEngine.outcomes(from: store.episodes)
                        .first { $0.leg == .outbound }?.actualDays, 4)
    }

    func testTheStoreDecidesTheActiveEpisodeWithTheLearnedRatesNotThePrior() {
        // Si el store cierra el episodio con el prior mientras el gemelo evalúa
        // con una tasa aprendida más LENTA, el motor se queda sin episodio
        // mientras todavía quedaba desajuste que contar.
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        // Tres tramos de vuelta LENTOS: 8 h al oeste en 10 días = 0.8 h/día.
        // Dentro del suelo (×0.5 del prior de 1.5 = 0.75), así que no se acota
        // — pero bastante más lento que el prior, que es lo que este test
        // necesita: la readaptación aprendida dura casi el doble.
        for index in 0...2 { store.save(measuredTokyo(index: index, destinationDays: 4, homeDays: 10)) }
        let learned = TravelLearningEngine.profile(episodes: store.episodes).rates
        XCTAssertEqual(learned.delayHoursPerDay, 0.8, accuracy: 0.001)
        XCTAssertLessThan(learned.delayHoursPerDay, ReentrainmentRates.prior.delayHoursPerDay)

        // Un cuarto viaje, ya de vuelta en casa desde 7 días: el prior (5.3
        // días) lo daría por recuperado; la tasa aprendida (10.6) no.
        let recent = measuredTokyo(index: 3, destinationDays: nil, homeDays: nil)
        store.save(recent)
        let sevenDaysHome = recent.homeArrival!.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(recent.phase(at: sevenDaysHome), .recovered, "Con el prior ya estaría recuperado.")
        XCTAssertEqual(recent.phase(at: sevenDaysHome, rates: learned), .homeReadaptation)
        XCTAssertEqual(store.currentEpisode(at: sevenDaysHome)?.id, recent.id,
                       "El store tiene que seguir entregándolo, o el motor se queda sin episodio.")
    }

    func testRecoveredMeansMeasuredStabilityWhenThereIsOneAndSaysWhenItDoesNot() {
        // "Recuperado" significaba "se agotó la duración estimada". Ahora la
        // fase cierra en la estabilidad MEDIDA cuando existe, y `phaseBasis`
        // distingue las dos cosas sin que haya que adivinarlo.
        let unmeasured = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let arrival = unmeasured.destinationArrival!
        // Sin medición: la adaptación dura lo estimado (8 días) y la base lo dice.
        XCTAssertEqual(unmeasured.phase(at: arrival.addingTimeInterval(4 * 86_400)), .destinationAdaptation)
        XCTAssertEqual(unmeasured.phaseBasis(at: arrival.addingTimeInterval(4 * 86_400)), .inProgress)
        XCTAssertEqual(unmeasured.phase(at: arrival.addingTimeInterval(9 * 86_400)), .destinationStable)
        XCTAssertEqual(unmeasured.phaseBasis(at: arrival.addingTimeInterval(9 * 86_400)),
                       .estimatedDurationElapsed, "Nadie confirmó nada: es una predicción cumplida.")

        // Con medición de 3 días: la fase cierra ahí, cinco días antes, y la
        // base pasa a ser una medición.
        let measured = measuredTokyo(index: 0, destinationDays: 3, homeDays: nil)
        XCTAssertEqual(measured.phase(at: arrival.addingTimeInterval(4 * 86_400)), .destinationStable)
        XCTAssertEqual(measured.phaseBasis(at: arrival.addingTimeInterval(4 * 86_400)), .measuredStability)

        // Y la fase NO se alarga con el margen de gracia: la línea temporal no
        // puede decir "Adaptación" más tiempo del que la tarjeta prometió.
        XCTAssertEqual(unmeasured.destinationAdaptationDays(), 8, accuracy: 0.001)
        XCTAssertEqual(unmeasured.phase(at: arrival.addingTimeInterval(8.5 * 86_400)), .destinationStable)
        // El margen vive sólo en la ventana de medición.
        XCTAssertEqual(unmeasured.stabilityMeasurableUntil(leg: .outbound),
                       arrival.addingTimeInterval(16 * 86_400))
        XCTAssertNil(measured.stabilityMeasurableUntil(leg: .outbound),
                     "Ya medido: no hay nada que seguir buscando.")
    }

    func testASlowerThanPredictedStabilisationCanStillBeMeasured() {
        // El sesgo sistemático que el margen de gracia arregla: sin él, la
        // estabilidad sólo se evaluaba dentro de la fase, así que una respuesta
        // MÁS LENTA que el prior nunca podía registrarse y el aprendiz sólo veía
        // respuestas iguales o más rápidas.
        let episode = measuredTokyo(index: 0, destinationDays: 4, homeDays: nil)
        let homeArrival = episode.homeArrival!
        // Ocho días después de volver: el prior daba 5.3, así que la fase ya es
        // .recovered — pero la ventana de gracia (10.6) sigue abierta.
        let lateDay = homeArrival.addingTimeInterval(8 * 86_400)
        XCTAssertEqual(episode.phase(at: lateDay), .recovered)
        XCTAssertNotNil(episode.stabilityMeasurableUntil(leg: .homeReturn))

        let good = (6...8).map { TrendPoint(date: homeArrival.addingTimeInterval(Double($0) * 86_400), value: 7.9) }
        let hrv = (6...8).map { TrendPoint(date: homeArrival.addingTimeInterval(Double($0) * 86_400), value: 71) }
        let impact = TravelImpactEngine.impact(episode: episode, at: lateDay, signals: TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60), sleepHistory: good, hrvHistory: hrv,
            restingHeartRateHistory: [], sleepSchedule: [], confounders: .none))
        XCTAssertNotNil(impact.stabilizedAt, "Una estabilización tardía tiene que poder medirse.")
        // Pero sin impacto: el episodio está recuperado, así que no puede
        // limitar nada ni aparecer como señal.
        XCTAssertEqual(impact.circadianOffsetHours, 0)
        XCTAssertEqual(impact.travelFatigue, 0)
        XCTAssertFalse(impact.isMeaningful)
        XCTAssertNil(SessionIntensityCeiling.fromTravel(impact))
    }

    func testStabilityNeedsRestingHeartRateAndLocalSleepTimingWhenThereIsData() {
        // Duración y HRV no distinguen "me he adaptado a Tokio" de "duermo bien
        // a la hora de Madrid mientras estoy en Tokio", y esa distinción ES la
        // re-sincronización circadiana.
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let arrival = episode.destinationArrival!
        let days = (1...3).map { arrival.addingTimeInterval(Double($0) * 86_400) }
        let sleep = days.map { TrendPoint(date: $0, value: 7.9) }
        let hrv = days.map { TrendPoint(date: $0, value: 71) }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        func schedule(bedtimeHourLocal: Int, zone: TimeZone) -> [NightlySleepSchedule] {
            days.map { night in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let bedtime = calendar.date(bySettingHour: bedtimeHourLocal, minute: 0, second: 0, of: night)!
                return NightlySleepSchedule(night: night, bedtime: bedtime, wakeTime: bedtime.addingTimeInterval(8 * 3_600))
            }
        }
        func stabilized(resting: [TrendPoint], schedule: [NightlySleepSchedule]) -> Date? {
            TravelImpactEngine.stabilizedDate(
                episode: episode, at: days.last!,
                signals: TravelSignalContext(baseline: baseline(sleepFloor: 7, hrvFloor: 60),
                                             sleepHistory: sleep, hrvHistory: hrv,
                                             restingHeartRateHistory: resting, sleepSchedule: schedule,
                                             confounders: .none))
        }
        // Horario consistente en hora de Tokio: estabilizado.
        XCTAssertNotNil(stabilized(resting: [], schedule: schedule(bedtimeHourLocal: 23, zone: tokyo)))
        // Pulso en reposo por encima de la banda: no cuenta, aunque duerma y
        // el HRV estén bien.
        let highResting = days.map { TrendPoint(date: $0, value: 70) }   // banda 40…58
        XCTAssertNil(stabilized(resting: highResting, schedule: schedule(bedtimeHourLocal: 23, zone: tokyo)))
        // Y sin dato de pulso, no penaliza: confirma cuando hay, no exige.
        XCTAssertNotNil(stabilized(resting: [], schedule: schedule(bedtimeHourLocal: 23, zone: tokyo)))
    }

    func testTheShortestAngularDifferenceKeepsMidnightCrossingNightsTogether() {
        // Acostarse a las 23:50 y a las 00:10 son 20 minutos de diferencia, no
        // 1420. Sin esto, cualquier noche que cruza medianoche rompía la racha.
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let arrival = episode.destinationArrival!
        let days = (1...3).map { arrival.addingTimeInterval(Double($0) * 86_400) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 23:50, 00:10 y 23:55 en hora de Tokio: todas la "misma" hora.
        let bedtimes = [(23, 50), (0, 10), (23, 55)]
        let schedule = zip(days, bedtimes).map { night, time in
            let bedtime = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: night)!
            return NightlySleepSchedule(night: night, bedtime: bedtime, wakeTime: bedtime.addingTimeInterval(8 * 3_600))
        }
        let stabilized = TravelImpactEngine.stabilizedDate(
            episode: episode, at: days.last!,
            signals: TravelSignalContext(baseline: baseline(sleepFloor: 7, hrvFloor: 60),
                                         sleepHistory: days.map { TrendPoint(date: $0, value: 7.9) },
                                         hrvHistory: days.map { TrendPoint(date: $0, value: 71) },
                                         restingHeartRateHistory: [], sleepSchedule: schedule,
                                         confounders: .none))
        XCTAssertNotNil(stabilized, "Tres noches a la misma hora, aunque una cruce medianoche.")
    }

    func testTheLegacyDailyTravelFieldIsInertEverywhere() {
        // El campo del cuestionario diario se conserva sólo para decodificar
        // datos antiguos. Este test es lo que impide que vuelva a la vida — más
        // útil que un @available(deprecated), que sólo habría añadido warnings
        // permanentes sobre el propio archivo que tiene que declararlo.
        let store = LifestyleFactorStore.shared
        let before = store.events.count
        var legacyOnly = LifestyleEvent.empty
        legacyOnly.date = Date(timeIntervalSince1970: 1_700_000_000)
        legacyOnly.timeZoneDifference = 9
        legacyOnly.travelDirection = .east
        // 1. Un evento cuyo ÚNICO contenido es el campo legado no es
        //    significativo: no se guarda.
        store.save(legacyOnly)
        XCTAssertEqual(store.events.count, before,
                       "Un campo que nada escribe no puede hacer significativo a un evento.")
        // 2. Y no aparece en el resumen.
        XCTAssertFalse(legacyOnly.summary.localizedCaseInsensitiveContains("viaje"))
        XCTAssertFalse(legacyOnly.summary.contains("9 h"))
        // 3. Las ocurrencias de viaje para la asociación de hábitos salen de
        //    los episodios, nunca del campo.
        XCTAssertTrue(HabitAssociationEngine.travelOccurrences(episodes: [], now: Date()).isEmpty)
    }

    // MARK: - PR18: el recorrido completo, no sólo el motor

    /// Un HealthStore con 60 días de sueño, HRV, pulso y horarios reales, para
    /// que PersonalBaselineEngine pueda producir bandas de verdad. El test de
    /// PR17 ejercía TravelImpactEngine en aislamiento y por eso no vio que el
    /// store nunca le entregaba el episodio.
    private func seededHealth(bedtimeHourHome: Int, from start: Date,
                              destinationNights: [(day: Int, bedtimeHourLocal: Int, zone: String)] = [],
                              poorHrvDays: Set<Int> = []) -> HealthStore {
        let health = HealthStore()
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Madrid")!; return c }()
        var sleep: [TrendPoint] = [], hrv: [TrendPoint] = [], resting: [TrendPoint] = []
        var schedule: [NightlySleepSchedule] = []
        for offset in -60...30 {
            let night = start.addingTimeInterval(Double(offset) * 86_400)
            sleep.append(TrendPoint(date: night, value: 7.8))
            // Días deliberadamente malos, para poder representar a alguien que
            // tarda MÁS que el prior en estabilizar — que es el caso que el
            // margen de gracia existe para poder medir.
            hrv.append(TrendPoint(date: night, value: poorHrvDays.contains(offset) ? 38 : 70))
            resting.append(TrendPoint(date: night, value: 48))
            let bedtime = homeCalendar.date(bySettingHour: bedtimeHourHome, minute: 30, second: 0, of: night)!
            schedule.append(NightlySleepSchedule(night: night, bedtime: bedtime,
                                                 wakeTime: bedtime.addingTimeInterval(8 * 3_600)))
        }
        // Noches concretas en destino con su propio horario local declarado.
        for override in destinationNights {
            let night = start.addingTimeInterval(Double(override.day) * 86_400)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: override.zone)!
            let bedtime = calendar.date(bySettingHour: override.bedtimeHourLocal, minute: 30, second: 0, of: night)!
            schedule.removeAll { Calendar.current.isDate($0.night, inSameDayAs: night) }
            schedule.append(NightlySleepSchedule(night: night, bedtime: bedtime,
                                                 wakeTime: bedtime.addingTimeInterval(8 * 3_600)))
        }
        health.sleepHistory = sleep
        health.hrvHistory = hrv
        health.restingHeartRateHistory = resting
        health.sleepScheduleHistory = schedule.sorted { $0.night < $1.night }
        return health
    }

    func testTheStoreActuallyHandsARecoveredEpisodeToTheTwinSoLateMeasurementHappens() {
        // EL fallo de la review: TravelImpactEngine sabía medir en la ventana de
        // gracia con la fase ya en .recovered, pero currentEpisode() excluía
        // precisamente los recuperados — así que el dashboard nunca inyectaba
        // ese viaje y la medición tardía no ocurría en uso real. El test de
        // PR17 no lo vio porque llamaba al motor directamente.
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        // Un viaje cuya IDA sí se midió y cuya VUELTA quedó sin medir.
        let episode = measuredTokyo(index: 0, destinationDays: 4, homeDays: nil)
        store.save(episode)
        let homeArrival = episode.homeArrival!
        // Ocho días después de volver: el prior daba 5.3, así que la fase ya es
        // .recovered, pero la ventana de gracia (10.6) sigue abierta.
        let lateDay = homeArrival.addingTimeInterval(8 * 86_400)
        XCTAssertEqual(episode.phase(at: lateDay), .recovered)

        // 1. currentEpisode NO lo devuelve — y eso es correcto, un viaje
        //    terminado no es "el viaje actual".
        XCTAssertNil(store.currentEpisode(at: lateDay))
        // 2. pero episodeForEvaluation SÍ, que es lo que el gemelo necesita.
        XCTAssertEqual(store.episodeForEvaluation(at: lateDay)?.id, episode.id,
                       "Sin esto la medición tardía es código inalcanzable.")

        // 3. El recorrido completo: contexto construido como lo construye la
        //    app, assess de verdad, y la persistencia al final.
        // Los seis primeros días en casa con el HRV hundido: este atleta tarda
        // más de lo que el prior predijo (5.3 días), que es exactamente el caso
        // que antes era imposible de registrar.
        let health = seededHealth(bedtimeHourHome: 23, from: homeArrival,
                                  poorHrvDays: Set(0...5))
        let context = TwinContext(profile: neutralProfile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor,
                                  travel: store.episodeForEvaluation(at: lateDay),
                                  travelHistory: store.episodes)
        let assessment = TwinEngine.assess(health: health, imports: ImportStore(persistToDisk: false),
                                           checkIn: nil, context: context, now: lateDay)
        XCTAssertNotNil(assessment.travel.stabilizedAt,
                        "El motor tiene que confirmar estabilidad con estas señales.")
        // Y el episodio recuperado no aporta impacto ninguno: no puede limitar
        // nada ni aparecer como señal.
        XCTAssertFalse(assessment.travel.isMeaningful)
        XCTAssertEqual(assessment.travel.circadianOffsetHours, 0)

        store.recordStabilityIfConfirmed(assessment.travel, at: lateDay)
        guard let outcome = store.episodes.first(where: { $0.id == episode.id })?.measuredOutcome else {
            return XCTFail("La medición tardía tiene que llegar al disco.")
        }
        XCTAssertNotNil(outcome.homeStabilityDays, "La vuelta pasa a estar medida.")
        XCTAssertEqual(outcome.destinationStabilityDays, 4, "Y la ida no se toca.")
        // Que es lo que rompía el sesgo: una respuesta MÁS LENTA que el prior
        // (5.3 días) queda registrada.
        XCTAssertGreaterThan(outcome.homeStabilityDays!, 5.3)
    }

    func testKeepingTheHomeScheduleAbroadIsNotStability() {
        // El segundo punto de la review: comparar cada noche contra la mediana
        // de esas mismas noches medía REGULARIDAD, no adaptación. Tres noches
        // seguidas a las 07:00 en Tokio son regulares y son exactamente lo
        // contrario de haberse adaptado — son las 23:30 de Madrid.
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let arrival = episode.destinationArrival!
        let days = [1, 2, 3]

        func stabilized(destinationBedtimeHour: Int) -> Date? {
            let health = seededHealth(
                bedtimeHourHome: 23, from: arrival,
                destinationNights: days.map { (day: $0, bedtimeHourLocal: destinationBedtimeHour, zone: "Asia/Tokyo") })
            return TravelImpactEngine.stabilizedDate(
                episode: episode, at: arrival.addingTimeInterval(3 * 86_400),
                signals: TravelSignalContext(
                    baseline: baseline(sleepFloor: 7, hrvFloor: 60),
                    sleepHistory: health.sleepHistory, hrvHistory: health.hrvHistory,
                    restingHeartRateHistory: health.restingHeartRateHistory,
                    sleepSchedule: health.sleepScheduleHistory, confounders: .none))
        }

        // El ancla es 23:30 en hora de casa, aprendida de las noches previas.
        let anchor = TravelImpactEngine.habitualBedtimeMinutes(
            episode: episode,
            signals: TravelSignalContext(
                baseline: nil, sleepHistory: [], hrvHistory: [], restingHeartRateHistory: [],
                sleepSchedule: seededHealth(bedtimeHourHome: 23, from: arrival).sleepScheduleHistory,
                confounders: .none))
        XCTAssertEqual(anchor, 23 * 60 + 30, "23:30 en hora de casa.")

        // Acostándose a las 23:30 en hora de TOKIO: adaptado.
        XCTAssertNotNil(stabilized(destinationBedtimeHour: 23))
        // Acostándose a las 07:30 en hora de Tokio (= 23:30 en Madrid, ocho
        // horas de diferencia): regular como un reloj, y sin adaptar nada.
        XCTAssertNil(stabilized(destinationBedtimeHour: 7),
                     "Mantener el horario de casa en destino no es estabilidad.")
    }

    func testTheCircularMedianDoesNotPutTheHabitInTheAfternoon() {
        // Una mediana aritmética de [23:40, 00:10, 23:50] da las 15:53, que no
        // es la hora a la que se acuesta nadie.
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let departure = episode.outboundDeparture!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let nights = [(23, 40), (0, 10), (23, 50), (23, 45), (0, 5)]
        let schedule = nights.enumerated().map { index, time -> NightlySleepSchedule in
            let night = departure.addingTimeInterval(Double(-index - 1) * 86_400)
            let bedtime = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: night)!
            return NightlySleepSchedule(night: night, bedtime: bedtime,
                                        wakeTime: bedtime.addingTimeInterval(8 * 3_600))
        }
        let anchor = TravelImpactEngine.habitualBedtimeMinutes(
            episode: episode,
            signals: TravelSignalContext(baseline: nil, sleepHistory: [], hrvHistory: [],
                                         restingHeartRateHistory: [], sleepSchedule: schedule,
                                         confounders: .none))!
        // Cerca de medianoche por cualquiera de los dos lados, nunca por la tarde.
        XCTAssertTrue(anchor > 23 * 60 || anchor < 60, "Salió \(anchor) minutos desde medianoche.")
    }

    func testWithoutEnoughPreTravelNightsTheScheduleCheckDoesNotPenalise() {
        // Sin ancla no se afirma nada sobre adaptación de horario — que es
        // distinto de afirmar que no hubo. Misma convención que el pulso.
        let episode = measuredTokyo(index: 0, destinationDays: nil, homeDays: nil)
        let arrival = episode.destinationArrival!
        let days = [1, 2, 3]
        let sleep = days.map { TrendPoint(date: arrival.addingTimeInterval(Double($0) * 86_400), value: 7.9) }
        let hrv = days.map { TrendPoint(date: arrival.addingTimeInterval(Double($0) * 86_400), value: 71) }
        // Horario en destino a una hora "no adaptada", pero SIN noches previas
        // con las que construir el ancla.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let schedule = days.map { day -> NightlySleepSchedule in
            let night = arrival.addingTimeInterval(Double(day) * 86_400)
            let bedtime = calendar.date(bySettingHour: 7, minute: 30, second: 0, of: night)!
            return NightlySleepSchedule(night: night, bedtime: bedtime,
                                        wakeTime: bedtime.addingTimeInterval(8 * 3_600))
        }
        XCTAssertNil(TravelImpactEngine.habitualBedtimeMinutes(
            episode: episode,
            signals: TravelSignalContext(baseline: nil, sleepHistory: [], hrvHistory: [],
                                         restingHeartRateHistory: [], sleepSchedule: schedule,
                                         confounders: .none)))
        XCTAssertNotNil(TravelImpactEngine.stabilizedDate(
            episode: episode, at: arrival.addingTimeInterval(3 * 86_400),
            signals: TravelSignalContext(baseline: baseline(sleepFloor: 7, hrvFloor: 60),
                                         sleepHistory: sleep, hrvHistory: hrv,
                                         restingHeartRateHistory: [], sleepSchedule: schedule,
                                         confounders: .none)),
            "Sin ancla, el horario no puede impedir la estabilidad.")
    }

    // MARK: - PR19: transparencia del cierre, donde se puede leer

    func testCurrentEpisodeNeverReturnsARecoveredOneSoTheCardCannotShowIt() {
        // La invariante que hacía INALCANZABLE la rama de `.recovered` dentro de
        // CurrentTravelCard: la tarjeta sólo recibe lo que devuelve
        // currentEpisode, y currentEpisode excluye los recuperados por diseño.
        // Se fija aquí para que nadie vuelva a escribir esa rama creyendo que
        // se muestra.
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        let episode = measuredTokyo(index: 0, destinationDays: 4, homeDays: 2)
        store.save(episode)
        let wellAfter = episode.homeArrival!.addingTimeInterval(60 * 86_400)
        XCTAssertEqual(episode.phase(at: wellAfter), .recovered)
        XCTAssertNil(store.currentEpisode(at: wellAfter),
                     "Un viaje terminado no es el viaje actual, así que la tarjeta no puede verlo.")
        // Y sí aparece en el historial, que es donde la transparencia del
        // cierre tiene que leerse.
        XCTAssertEqual(store.completedEpisodes(at: wellAfter).map(\.id), [episode.id])
    }

    func testEveryEpisodeInTheHistoryHasATerminalClosureBasisToShow() {
        // La fila del historial siempre tiene algo que decir: para todo
        // episodio que el store considera completado, phaseBasis devuelve una
        // base TERMINAL (medida o estimada), nunca .inProgress ni
        // .notApplicable. Sin esta invariante la fila podría quedarse sin
        // texto justo en el caso que la review pedía hacer visible.
        let store = TravelEpisodeStore()
        for episode in store.episodes { store.delete(id: episode.id) }
        defer { for episode in store.episodes { store.delete(id: episode.id) } }

        let confirmed = measuredTokyo(index: 0, destinationDays: 4, homeDays: 2)
        let unconfirmed = measuredTokyo(index: 1, destinationDays: nil, homeDays: nil)
        store.save(confirmed)
        store.save(unconfirmed)
        let wellAfter = unconfirmed.homeArrival!.addingTimeInterval(60 * 86_400)

        let completed = store.completedEpisodes(at: wellAfter)
        XCTAssertEqual(completed.count, 2)
        for episode in completed {
            let basis = episode.phaseBasis(at: wellAfter)
            XCTAssertTrue([.measuredStability, .estimatedDurationElapsed].contains(basis),
                          "\(episode.title) cerró con base \(basis), que la fila no sabría explicar.")
        }
        // Y las dos bases son distinguibles, que es el punto: uno se confirmó y
        // el otro sólo agotó la predicción.
        XCTAssertEqual(confirmed.phaseBasis(at: wellAfter), .measuredStability)
        XCTAssertEqual(unconfirmed.phaseBasis(at: wellAfter), .estimatedDurationElapsed)
        // El no confirmado tampoco aporta nada al aprendizaje, que es lo que la
        // fila dice ahora en voz alta.
        XCTAssertNil(TravelLearningEngine.outcomes(from: [unconfirmed])
                        .first { $0.leg == .homeReturn }?.actualDays)
    }
}
