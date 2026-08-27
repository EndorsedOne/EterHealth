import XCTest
@testable import EterHealth

// PR15. El impacto del viaje sobre el gemelo: las dos magnitudes separadas, su
// decaimiento, el techo de intensidad, y —lo que el brief pide explícitamente—
// que la recomendación principal, la planificación semanal, el simulador y el
// reloj digan lo mismo.
@MainActor
final class TravelImpactTests: XCTestCase {

    private let neutralProfile = AthletePlanProfile.angelDefault
    private let neutralCalibration = TwinCalibration.none
    private let neutralAnchor = PersonalReadinessAnchor.provisional

    private func local(_ zone: String, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = h; components.minute = min
        components.timeZone = TimeZone(identifier: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: components)!
    }

    private func segment(_ from: String, _ departure: Date, _ to: String, _ arrival: Date) -> FlightSegment {
        FlightSegment(departure: departure, arrival: arrival, originTimeZoneID: from, destinationTimeZoneID: to)
    }

    /// Madrid → Tokio, 8 h al este, salida diurna. El caso de referencia.
    private func tokyoEpisode() -> TravelEpisode {
        TravelEpisode(
            title: "Tokio", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Asia/Tokyo",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 3, 2, 11),
                                      "Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 3, 8))],
            returnFlights: [segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 24, 10),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 3, 24, 16))])
    }

    private func context(_ episode: TravelEpisode?, profile: AthletePlanProfile? = nil) -> TwinContext {
        TwinContext(profile: profile ?? neutralProfile, events: [], reviews: [], activeInjuries: [],
                    calibration: neutralCalibration, personalAnchor: neutralAnchor, travel: episode)
    }

    // MARK: - Las dos magnitudes son independientes

    func testTransitFatigueAndCircadianOffsetAreSeparateAndCanDisagreeCompletely() {
        // El caso que un solo número nunca podía representar, y la razón de que
        // el brief pida separarlos: Madrid–Johannesburgo es un vuelo nocturno
        // de 11 h que fatiga mucho y NO desajusta nada (los dos husos están en
        // +2 en julio). Con la penalización antigua —función sólo de la
        // diferencia horaria— este viaje costaba exactamente cero.
        let johannesburg = TravelEpisode(
            title: "Johannesburgo", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Africa/Johannesburg",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 21),
                                      "Africa/Johannesburg", local("Africa/Johannesburg", 2026, 7, 11, 8))],
            expectedStayEndDate: local("Africa/Johannesburg", 2026, 7, 25, 9))
        let onArrival = TravelImpactEngine.impact(episode: johannesburg, at: local("Africa/Johannesburg", 2026, 7, 11, 10))
        XCTAssertEqual(onArrival.circadianOffsetHours, 0, accuracy: 0.001, "Mismo huso: no hay nada que re-sincronizar.")
        XCTAssertGreaterThan(onArrival.travelFatigue, 0.3, "11 h nocturnas fatigan de verdad.")
        XCTAssertTrue(onArrival.factors.contains { if case .overnightFlight = $0 { return true } else { return false } })
        XCTAssertLessThan(onArrival.fatigueReadinessCost, 0)
        XCTAssertEqual(onArrival.circadianReadinessCost, 0)

        // Y el contrario: Madrid–Nueva York diurno, 8 h de vuelo, 6 h de
        // desajuste. Poca fatiga, desajuste grande.
        let newYork = TravelEpisode(
            title: "Nueva York", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "America/New_York",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 10),
                                      "America/New_York", local("America/New_York", 2026, 7, 10, 13))],
            expectedStayEndDate: local("America/New_York", 2026, 7, 25, 9))
        let nyArrival = TravelImpactEngine.impact(episode: newYork, at: local("America/New_York", 2026, 7, 10, 15))
        XCTAssertEqual(nyArrival.circadianOffsetHours, -6, accuracy: 0.2)
        XCTAssertLessThan(nyArrival.travelFatigue, onArrival.travelFatigue,
                          "Un vuelo diurno de 8 h fatiga menos que uno nocturno de 11.")
        XCTAssertLessThan(nyArrival.circadianReadinessCost, 0)
    }

    func testALongHaulWithLayoverAndALostNightFatiguesMoreThanAShortDayFlight() {
        let short = [segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 10),
                             "Europe/London", local("Europe/London", 2026, 7, 10, 11))]
        let longWithLayover = [
            segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 10, 20),
                    "Asia/Qatar", local("Asia/Qatar", 2026, 7, 11, 5)),
            segment("Asia/Qatar", local("Asia/Qatar", 2026, 7, 11, 9),
                    "Pacific/Auckland", local("Pacific/Auckland", 2026, 7, 12, 12))
        ]
        let shortPeak = TravelImpactEngine.peakFatigue(
            flights: short, transitDuration: short[0].arrival.timeIntervalSince(short[0].departure))
        let longPeak = TravelImpactEngine.peakFatigue(
            flights: longWithLayover,
            transitDuration: longWithLayover[1].arrival.timeIntervalSince(longWithLayover[0].departure))
        XCTAssertLessThan(shortPeak, 0.15)
        XCTAssertGreaterThan(longPeak, 0.7)
        // Y acotada: ni el peor tránsito imaginable pasa de 1.
        XCTAssertLessThanOrEqual(longPeak, 1.0)
    }

    func testTravelFatigueDecaysWithTheSameHalfLifeStepAlreadyUsesForMuscleFatigue() {
        let episode = tokyoEpisode()
        let arrival = episode.destinationArrival!
        let atArrival = TravelImpactEngine.transitFatigue(episode: episode, at: arrival)
        let oneHalfLife = TravelImpactEngine.transitFatigue(
            episode: episode, at: arrival.addingTimeInterval(TravelImpactEngine.fatigueHalfLifeDays * 86_400))
        XCTAssertGreaterThan(atArrival, 0)
        XCTAssertEqual(oneHalfLife, atArrival / 2, accuracy: 0.01, "Una vida media es exactamente la mitad.")
        // Reutilizada a propósito, no una segunda constante parecida.
        XCTAssertEqual(TravelImpactEngine.fatigueHalfLifeDays, 1.5)
    }

    // MARK: - Este vs oeste, ida vs vuelta

    func testTheSameOffsetResolvesFasterWestwardThanEastward() {
        let episode = tokyoEpisode()
        let arrival = episode.destinationArrival!
        let homeArrival = episode.homeArrival!
        // Tres días después de llegar a Tokio (8 h al este, 1 h/día): quedan 5.
        let inTokyo = TravelImpactEngine.impact(episode: episode, at: arrival.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(inTokyo.circadianOffsetHours, 5, accuracy: 0.1)
        // Tres días después de volver (8 h al oeste, 1.5 h/día): quedan 3.5.
        let backHome = TravelImpactEngine.impact(episode: episode, at: homeArrival.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(backHome.circadianOffsetHours, -3.5, accuracy: 0.1)
        XCTAssertLessThan(abs(backHome.circadianOffsetHours), abs(inTokyo.circadianOffsetHours),
                          "La vuelta al oeste se resuelve más rápido: es la asimetría del prior, no una constante.")
        // Y los signos son opuestos: ida al este, vuelta al oeste.
        XCTAssertGreaterThan(inTokyo.circadianOffsetHours, 0)
        XCTAssertLessThan(backHome.circadianOffsetHours, 0)
    }

    func testTheReturnLegRecomputesFatigueInsteadOfReusingTheOutbound() {
        // Ida directa y diurna; vuelta con escala y nocturna. La fatiga del
        // tramo de vuelta tiene que salir de SUS propios vuelos: si reutilizara
        // el resultado de la ida, estos dos números serían iguales.
        let episode = TravelEpisode(
            title: "Tokio", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "Asia/Tokyo",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 3, 2, 11),
                                      "Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 3, 8))],
            returnFlights: [segment("Asia/Tokyo", local("Asia/Tokyo", 2026, 3, 24, 22),
                                    "Asia/Qatar", local("Asia/Qatar", 2026, 3, 25, 4)),
                            segment("Asia/Qatar", local("Asia/Qatar", 2026, 3, 25, 8),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 3, 25, 14))])
        let outboundFatigue = TravelImpactEngine.transitFatigue(episode: episode, at: episode.destinationArrival!)
        let returnFatigue = TravelImpactEngine.transitFatigue(episode: episode, at: episode.homeArrival!)
        XCTAssertGreaterThan(returnFatigue, outboundFatigue + 0.1,
                             "La vuelta lleva escala y noche perdida: no puede salir el mismo número que la ida.")
        XCTAssertTrue(episode.hasOvernightReturn)
        XCTAssertFalse(episode.hasOvernightOutbound)
    }

    // MARK: - Estancia corta

    func testAShortStayProducesTransitFatigueButNoCircadianOffsetAtAll() {
        // 36 h en Nueva York: la política automática mantiene el horario de
        // origen, así que el reloj no se mueve y no hay desajuste PROPIO que
        // resolver. Lo que queda es la fatiga de los dos vuelos.
        let short = TravelEpisode(
            title: "Reunión", homeTimeZoneID: "Europe/Madrid", destinationTimeZoneID: "America/New_York",
            outboundFlights: [segment("Europe/Madrid", local("Europe/Madrid", 2026, 7, 6, 9),
                                      "America/New_York", local("America/New_York", 2026, 7, 6, 12))],
            returnFlights: [segment("America/New_York", local("America/New_York", 2026, 7, 7, 18),
                                    "Europe/Madrid", local("Europe/Madrid", 2026, 7, 8, 7))])
        XCTAssertEqual(short.resolvedStayPolicy, .keepHomeSchedule)
        let inDestination = TravelImpactEngine.impact(episode: short, at: local("America/New_York", 2026, 7, 6, 20))
        XCTAssertEqual(inDestination.circadianOffsetHours, 0, accuracy: 0.001)
        XCTAssertGreaterThan(inDestination.travelFatigue, 0)
        XCTAssertTrue(inDestination.factors.contains(.keepHomeSchedule))
        // Y al volver, tampoco hay readaptación: no se fingió adaptación.
        XCTAssertEqual(short.homeReadaptationDays(), 0)
    }

    // MARK: - Estabilidad y confusores

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

    func testSustainedStabilityClosesTheOffsetEarlyAndOneGoodNightDoesNot() {
        let episode = tokyoEpisode()
        let arrival = episode.destinationArrival!
        let day = { (offset: Int) in arrival.addingTimeInterval(Double(offset) * 86_400) }
        func signals(goodDays: [Int]) -> TravelSignalContext {
            TravelSignalContext(
                baseline: baseline(sleepFloor: 7, hrvFloor: 60),
                sleepHistory: goodDays.map { TrendPoint(date: day($0), value: 7.8) },
                hrvHistory: goodDays.map { TrendPoint(date: day($0), value: 72) },
                restingHeartRateHistory: [], confounders: .none)
        }
        // Sin datos: manda el prior, quedan ~6 h a los dos días.
        let priorOnly = TravelImpactEngine.impact(episode: episode, at: day(2))
        XCTAssertEqual(priorOnly.circadianOffsetHours, 6, accuracy: 0.2)

        // Una sola noche buena no es estabilidad.
        let oneNight = TravelImpactEngine.impact(episode: episode, at: day(2), signals: signals(goodDays: [1]))
        XCTAssertNil(oneNight.stabilizedAt)
        XCTAssertEqual(oneNight.circadianOffsetHours, 6, accuracy: 0.2)

        // Tres consecutivas sí: el desajuste se cierra antes que el prior.
        let threeNights = TravelImpactEngine.impact(episode: episode, at: day(3), signals: signals(goodDays: [1, 2, 3]))
        XCTAssertNotNil(threeNights.stabilizedAt)
        XCTAssertEqual(threeNights.circadianOffsetHours, 0, accuracy: 0.001)
        XCTAssertGreaterThan(threeNights.confidence.score, priorOnly.confidence.score,
                             "Confirmar con señales propias sube la confianza; el prior solo la deja baja.")

        // Un hueco ROMPE la racha: tres días con el de en medio sin dato no
        // son tres consecutivos, y afirmar estabilidad con huecos sería
        // inventarse el día que falta.
        let withGap = TravelImpactEngine.impact(episode: episode, at: day(3), signals: signals(goodDays: [1, 3]))
        XCTAssertNil(withGap.stabilizedAt)
    }

    func testSignalsCanOnlyShortenThePriorNeverExtendIt() {
        // A los 10 días de llegar, el prior de 8 días ya dio el desajuste por
        // resuelto. Con señales todavía fuera de banda, el desajuste NO se
        // alarga —atribuirlo al viaje sería una afirmación insostenible— lo
        // que baja es la confianza.
        let episode = tokyoEpisode()
        let late = episode.destinationArrival!.addingTimeInterval(10 * 86_400)
        let badSignals = TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60),
            sleepHistory: [TrendPoint(date: late, value: 5.1)],
            hrvHistory: [TrendPoint(date: late, value: 41)],
            restingHeartRateHistory: [], confounders: .none)
        let impact = TravelImpactEngine.impact(episode: episode, at: late, signals: badSignals)
        XCTAssertEqual(impact.circadianOffsetHours, 0, accuracy: 0.001,
                       "El prior manda el techo: las señales no pueden alargar el desajuste.")
        // Pero las señales SÍ aparecen en la explicación, para que el atleta
        // sepa por qué se le limita la sesión aunque el viaje ya no cuente.
        XCTAssertTrue(impact.signalFactors.contains { if case .hrvBelowBand = $0 { return true } else { return false } })
        XCTAssertTrue(impact.signalFactors.contains { if case .shortSleep = $0 { return true } else { return false } })
    }

    func testAConfoundedEpisodeIsFlaggedAndLosesConfidence() {
        let episode = tokyoEpisode()
        let date = episode.destinationArrival!.addingTimeInterval(86_400)
        let clean = TravelImpactEngine.impact(episode: episode, at: date, signals: TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60), sleepHistory: [], hrvHistory: [],
            restingHeartRateHistory: [], confounders: .none))
        let confounded = TravelImpactEngine.impact(episode: episode, at: date, signals: TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60), sleepHistory: [], hrvHistory: [],
            restingHeartRateHistory: [], confounders: [.illness, .alcohol]))
        XCTAssertFalse(clean.isPotentiallyConfounded)
        XCTAssertTrue(confounded.isPotentiallyConfounded)
        XCTAssertLessThan(confounded.confidence.score, clean.confidence.score)
        XCTAssertTrue(confounded.confidence.reason.contains("enfermedad declarada"))
        XCTAssertTrue(confounded.confidence.reason.contains("alcohol registrado"))
        // Y el desajuste no cambia: un confusor no altera la estimación, sólo
        // lo que se puede afirmar sobre ella.
        XCTAssertEqual(confounded.circadianOffsetHours, clean.circadianOffsetHours, accuracy: 0.001)
    }

    // MARK: - Techo de intensidad

    func testTheTravelCeilingLimitsIntensityWithoutEverBlockingTrainingBlindly() {
        let episode = tokyoEpisode()
        // En vuelo: el tier alto. Fuera la calidad, la tirada larga, el
        // híbrido y el brick — pero se sustituye por carrera suave, no por
        // recuperación, y la fuerza no se prohíbe: se rebaja.
        let inFlight = TravelImpactEngine.impact(episode: episode, at: local("Asia/Tokyo", 2026, 3, 3, 2))
        guard let ceiling = SessionIntensityCeiling.fromTravel(inFlight) else {
            return XCTFail("Un tránsito transoceánico tiene que producir techo.")
        }
        XCTAssertEqual(ceiling.substitute, .easyRun, "Nunca a recuperación: el brief pide permitir sesión ligera.")
        XCTAssertTrue(ceiling.capsStrengthIntensity)
        XCTAssertFalse(ceiling.excludes(.strength), "La fuerza se rebaja, no se sustituye.")
        XCTAssertFalse(ceiling.excludes(.easyRun))
        XCTAssertFalse(ceiling.excludes(.recovery))
        for kind: PlannedSessionKind in [.qualityRun, .longRun, .hybrid, .brick] {
            XCTAssertTrue(ceiling.excludes(kind), "\(kind.rawValue) no toca en pleno tránsito.")
        }
        // Y la explicación es concreta, no "porque has viajado".
        XCTAssertFalse(ceiling.explanation.isEmpty)
        XCTAssertFalse(ceiling.explanation.localizedCaseInsensitiveContains("porque has viajado"))
        XCTAssertTrue(ceiling.explanation.contains("puerta a puerta"))

        // Ya recuperado: ningún techo.
        let recovered = TravelImpactEngine.impact(episode: episode, at: local("Europe/Madrid", 2026, 4, 20, 12))
        XCTAssertNil(SessionIntensityCeiling.fromTravel(recovered))
    }

    func testTravelNeverOverridesRaceDayNoMatterHowBadTheTransitWas() {
        // La regla que no se negocia: has volado PARA competir. Un override
        // duro por viaje cancelaría la carrera, porque en status() el gate de
        // señales va antes del gate de evento.
        let raceDate = local("Asia/Tokyo", 2026, 3, 3, 9)
        var profile = neutralProfile
        profile.goals = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Maratón de Tokio",
                                      date: raceDate, targetValue: nil, unit: "min",
                                      priority: .primary, isActive: true)]
        let episode = tokyoEpisode()
        let impact = TravelImpactEngine.impact(episode: episode, at: raceDate)
        XCTAssertTrue(impact.isMeaningful, "Sanity check: este viaje sí tiene impacto, o el test no prueba nada.")
        // Ningún techo excluye el día de competición.
        if let ceiling = SessionIntensityCeiling.fromTravel(impact) {
            XCTAssertFalse(ceiling.excludes(.raceDay))
        }
        let status = TrainingPlanEngine.status(
            health: HealthStore(), imports: ImportStore(persistToDisk: false), readiness: 85,
            muscles: [], checkIn: nil, context: context(episode, profile: profile),
            travel: impact, now: raceDate)
        XCTAssertEqual(status.nextSession, .raceDay)
    }

    func testGoodSignalsRelaxTheCeilingButNotWhileStillInTheAir() {
        let episode = tokyoEpisode()
        let arrival = episode.destinationArrival!
        // Un día después de llegar: 7 h de desajuste, tier alto por magnitud.
        let dayAfter = arrival.addingTimeInterval(86_400)
        let noSignals = TravelImpactEngine.impact(episode: episode, at: dayAfter)
        let highRisk = SessionIntensityCeiling.fromTravel(noSignals)
        XCTAssertEqual(highRisk?.excludes(.longRun), true)

        // Mismo desajuste, pero sueño y HRV dentro de banda y sin confusores:
        // el tier baja y la tirada larga en Z2 vuelve a ser asumible. Es el
        // "no bloquear de forma ciega" del brief.
        let reassuring = TravelImpactEngine.impact(episode: episode, at: dayAfter, signals: TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60),
            sleepHistory: [TrendPoint(date: dayAfter, value: 8.1)],
            hrvHistory: [TrendPoint(date: dayAfter, value: 75)],
            restingHeartRateHistory: [], confounders: .none))
        let relaxed = SessionIntensityCeiling.fromTravel(reassuring)
        XCTAssertEqual(relaxed?.excludes(.longRun), false, "Con señales buenas, la tirada larga sigue en pie.")
        XCTAssertEqual(relaxed?.excludes(.qualityRun), true, "La calidad no: exige ritmo objetivo sobre un reloj desajustado.")

        // En vuelo NO se relaja: no hay señal del día que pueda tranquilizar.
        let inFlight = TravelImpactEngine.impact(episode: episode, at: local("Asia/Tokyo", 2026, 3, 3, 2),
                                                 signals: TravelSignalContext(
            baseline: baseline(sleepFloor: 7, hrvFloor: 60),
            sleepHistory: [], hrvHistory: [], restingHeartRateHistory: [], confounders: .none))
        XCTAssertEqual(SessionIntensityCeiling.fromTravel(inFlight)?.excludes(.longRun), true)
    }

    func testAlertAndTravelCeilingsMergeSoBothReasonsAreShown() {
        let alert = PhysiologicalAlert(
            severity: .caution, title: "Atención", summary: "HRV y pulso se apartan de tu rango.",
            action: "Reduce la intensidad hoy.", signals: [],
            confidence: ConfidenceAssessment(score: 70, level: .medium, reason: ""))
        let episode = tokyoEpisode()
        let impact = TravelImpactEngine.impact(episode: episode, at: episode.destinationArrival!.addingTimeInterval(86_400))
        guard let merged = SessionIntensityCeiling.resolve(alert: alert, travel: impact) else {
            return XCTFail("Con alerta y viaje tiene que haber techo.")
        }
        XCTAssertTrue(merged.explanation.contains("HRV y pulso se apartan de tu rango."))
        XCTAssertTrue(merged.reasons.count >= 2, "Los dos motivos, no el primero que se compruebe: \(merged.reasons)")
        XCTAssertTrue(merged.capsStrengthIntensity, "Gana el más restrictivo de cada cosa.")
    }

    // MARK: - Una sola definición del coste

    func testTodayAndTomorrowChargeTheSameCostForTheSameTravelState() {
        // La propiedad que impide la divergencia que había entre la app y el
        // widget: assess() y TwinReadout.derive llaman a las MISMAS dos
        // funciones. Si alguien añade una tercera fórmula, esto no lo detecta
        // — pero sí detecta que las dos que existen sigan siendo una sola.
        for offset in [-9.0, -6.0, -2.0, 0, 2.0, 6.0, 9.0] {
            let physiology = { () -> TwinPhysiology in
                var state = TwinPhysiology.baseline(asOf: Date(timeIntervalSince1970: 1_700_000_000))
                state.circadianOffsetHours = offset
                return state
            }()
            let readout = TwinReadout.derive(from: physiology, anchor: neutralAnchor, calibration: .none)
            let clean = TwinReadout.derive(from: TwinPhysiology.baseline(asOf: physiology.asOf),
                                           anchor: neutralAnchor, calibration: .none)
            let expected = TravelImpact.circadianReadinessCost(offsetHours: offset)
            XCTAssertEqual(readout.score - clean.score, expected,
                           "Con \(offset) h de desajuste, la proyección tiene que costar \(expected) pt.")
        }
        // Y el techo del coste es el mismo −12 que tenía el modelo anterior
        // para la diferencia horaria, así que un viaje grande cuesta hoy lo
        // que costaba antes.
        XCTAssertEqual(TravelImpact.circadianReadinessCost(offsetHours: 12), -12)
        XCTAssertEqual(TravelImpact.circadianReadinessCost(offsetHours: -12), -12)
        XCTAssertEqual(TravelImpact.circadianReadinessCost(offsetHours: 0), 0)
        XCTAssertEqual(TravelImpact.fatigueReadinessCost(1), -8)
        XCTAssertEqual(TravelImpact.fatigueReadinessCost(0), 0)
    }

    func testStepDecaysTravelStateDirectionallyAndNewInformationWins() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        var eastward = TwinPhysiology.baseline(asOf: today)
        eastward.circadianOffsetHours = 8
        eastward.travelFatigue = 0.8
        var westward = TwinPhysiology.baseline(asOf: today)
        westward.circadianOffsetHours = -8

        let eastTomorrow = step(eastward, session: nil, recoverySignals: .none, dtDays: 1)
        let westTomorrow = step(westward, session: nil, recoverySignals: .none, dtDays: 1)
        XCTAssertEqual(eastTomorrow.circadianOffsetHours, 7, accuracy: 0.001, "1 h/día adelantando fase.")
        XCTAssertEqual(westTomorrow.circadianOffsetHours, -6.5, accuracy: 0.001, "1.5 h/día retrasándola.")
        XCTAssertLessThan(abs(westTomorrow.circadianOffsetHours), abs(eastTomorrow.circadianOffsetHours))
        // El signo no se pierde por el camino.
        XCTAssertGreaterThan(eastTomorrow.circadianOffsetHours, 0)
        XCTAssertLessThan(westTomorrow.circadianOffsetHours, 0)
        // La fatiga decae por vida media, no linealmente.
        XCTAssertEqual(eastTomorrow.travelFatigue, 0.8 * pow(0.5, 1 / 1.5), accuracy: 0.001)
        // Nunca cruza el cero: 20 días después sigue siendo 0, no −12.
        let muchLater = step(eastward, session: nil, recoverySignals: .none, dtDays: 20)
        XCTAssertEqual(muchLater.circadianOffsetHours, 0, accuracy: 0.001)

        // Y una medición nueva del episodio manda sobre la decaída.
        let episode = tokyoEpisode()
        let measured = TravelImpactEngine.impact(episode: episode, at: episode.destinationArrival!)
        let withNews = step(eastward, session: nil,
                            recoverySignals: RecoverySignals(hrvDeviation: nil, restingHeartRateDeviation: nil,
                                                             sleepDeficitHours: nil, checkIn: nil,
                                                             physiologicalAlert: nil, travel: measured),
                            dtDays: 1)
        XCTAssertEqual(withNews.circadianOffsetHours, measured.circadianOffsetHours, accuracy: 0.001)
    }

    // MARK: - Consistencia entre superficies

    func testMainRecommendationWeekAheadWatchAndSimulatorAllSeeTheSameTravel() {
        // El criterio explícito del brief. Un episodio en pleno tránsito, y las
        // cuatro superficies tienen que coincidir — no "parecerse".
        let episode = tokyoEpisode()
        let inFlight = local("Asia/Tokyo", 2026, 3, 3, 2)
        let health = HealthStore()
        let imports = ImportStore(persistToDisk: false)
        let travelContext = context(episode)

        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: nil,
                                           context: travelContext, now: inFlight)
        XCTAssertTrue(assessment.travel.isMeaningful, "assess() tiene que ver el viaje.")
        XCTAssertEqual(assessment.physiology.circadianOffsetHours, assessment.travel.circadianOffsetHours, accuracy: 0.001,
                       "La fisiología lleva el MISMO estado que la señal de hoy, no una segunda estimación.")

        // 1. Recomendación principal.
        let plan = TrainingPlanEngine.status(health: health, imports: imports, readiness: assessment.score,
                                             muscles: assessment.muscles, checkIn: nil, context: travelContext,
                                             physiologicalAlert: assessment.physiologicalAlert,
                                             travel: assessment.travel, now: inFlight)
        let ceiling = SessionIntensityCeiling.resolve(alert: assessment.physiologicalAlert, travel: assessment.travel)
        XCTAssertNotNil(ceiling)
        XCTAssertFalse(ceiling!.excludes(plan.nextSession),
                       "El plan no puede proponer una sesión que su propio techo excluye: propuso \(plan.nextSession.rawValue).")

        // 2. Planificación semanal: ningún día simulado propone algo que su
        // propio techo de ese día excluya.
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil,
                                                context: travelContext, now: inFlight)
        for day in week {
            let dayTravel = TravelImpactEngine.impact(episode: episode, at: day.date, signals: .none)
            if let dayCeiling = SessionIntensityCeiling.resolve(alert: nil, travel: dayTravel) {
                XCTAssertFalse(dayCeiling.excludes(day.kind),
                               "\(day.date): la semana propone \(day.kind.rawValue), que su techo excluye.")
            }
        }
        XCTAssertEqual(week.first?.kind, plan.nextSession, "El día 0 de la semana ES la recomendación de hoy.")

        // 3. Reloj: su actividad se deriva del kind del plan, así que no puede
        // discrepar — y con el techo puesto, no puede ser una de calidad.
        let watchActivity = TrainingPlanEngine.watchActivity(for: plan.nextSession)
        XCTAssertEqual(watchActivity, TrainingPlanEngine.watchActivity(for: week.first!.kind))

        // 4. Simulador: ve el viaje. La misma decisión simulada con y sin
        // episodio no puede dar el mismo mañana.
        func simulate(_ travel: TravelEpisode?) -> DecisionSimulation {
            DecisionSimulatorEngine.simulate(.longRun, health: health, imports: imports, checkIn: nil,
                                             profile: neutralProfile, events: [], reviews: [], activeInjuries: [],
                                             calibration: neutralCalibration, personalAnchor: neutralAnchor,
                                             travel: travel, now: inFlight)
        }
        XCTAssertLessThan(simulate(episode).tomorrowReadiness, simulate(nil).tomorrowReadiness,
                          "Si el simulador no ve el viaje, dirá que una tirada larga sale gratis mientras el plan la limita.")
    }

    func testWithoutAnActiveEpisodeNothingAboutTheTwinChanges() {
        // Regresión-cero: el mismo assess con y sin campo de viaje (nil) tiene
        // que dar exactamente lo mismo, porque es el estado en el que está la
        // app el 99% de los días.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let health = HealthStore()
        let imports = ImportStore(persistToDisk: false)
        let withoutTravel = TwinEngine.assess(health: health, imports: imports, checkIn: nil,
                                              context: context(nil), now: now)
        XCTAssertEqual(withoutTravel.travel, .none)
        XCTAssertEqual(withoutTravel.physiology.circadianOffsetHours, 0)
        XCTAssertEqual(withoutTravel.physiology.travelFatigue, 0)
        XCTAssertFalse(withoutTravel.signals.contains { $0.name == "Desajuste circadiano" || $0.name == "Fatiga de viaje" })
        XCTAssertNil(SessionIntensityCeiling.resolve(alert: nil, travel: .none))
        // Y un episodio cancelado o ya recuperado se comporta igual que no
        // tener ninguno.
        var cancelled = tokyoEpisode()
        cancelled.isCancelled = true
        XCTAssertEqual(TravelImpactEngine.impact(episode: cancelled, at: now), .none)
        XCTAssertEqual(TravelImpactEngine.impact(episode: tokyoEpisode(),
                                                 at: local("Europe/Madrid", 2027, 1, 1, 12)), .none)
    }
}
