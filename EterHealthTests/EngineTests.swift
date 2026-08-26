import XCTest
@testable import EterHealth

@MainActor
final class EngineTests: XCTestCase {
    // TwinCore PR1: assess/status/weekAhead/balance no longer read the
    // GoalStore/LifestyleFactorStore/WorkoutReviewStore/InjuryStore/
    // TwinStateStore singleton instances internally — tests supply
    // neutral, deterministic defaults for these below instead of
    // depending on whatever real state happens to be persisted on this
    // machine (the actual mechanism behind this suite's own pre-existing,
    // hard-to-reproduce flakiness before this refactor). A test that
    // needs specific goal-portfolio behavior still constructs its own
    // AthletePlanProfile value and passes it directly — same intent as
    // the old GoalStore.shared.save(...) pattern, just an explicit
    // argument now instead of a hidden global read.
    private let neutralProfile = AthletePlanProfile.angelDefault
    private let neutralCalibration = TwinCalibration.none
    private let neutralAnchor = PersonalReadinessAnchor.provisional
    // PR1.5: assess/status/weekAhead/balance all take one TwinContext now
    // instead of six separate parameters — this is the neutral-fixture
    // bundle for tests that don't care about goal-portfolio, lifestyle,
    // review, injury or calibration behavior. A test that does care
    // builds its own TwinContext (usually with a locally-constructed
    // profile) instead of using this one.
    private var neutralContext: TwinContext {
        TwinContext(profile: neutralProfile, events: [], reviews: [], activeInjuries: [],
                   calibration: neutralCalibration, personalAnchor: neutralAnchor)
    }

    func testPersonalAnchorNeedsSevenMorningsBeforeLearning() {
        let anchor = PersonalReadinessAnchor.derive(scores: [52, 55, 54, 53, 56, 10])
        XCTAssertEqual(anchor.score, 70)
        XCTAssertEqual(anchor.confidence, 0)
    }

    func testPersonalAnchorProgressivelyReplacesUniversalBaseline() {
        let partial = PersonalReadinessAnchor.derive(scores: Array(repeating: 58, count: 12))
        let mature = PersonalReadinessAnchor.derive(scores: Array(repeating: 58, count: 30))
        XCTAssertGreaterThan(partial.score, 58)
        XCTAssertEqual(mature.score, 58)
        XCTAssertEqual(mature.confidence, 100)
    }

    func testPersonalAnchorIsRobustToSingleExtremeDay() {
        let anchor = PersonalReadinessAnchor.derive(scores: Array(repeating: 72, count: 29) + [0])
        XCTAssertEqual(anchor.score, 72)
        XCTAssertEqual(anchor.personalMedian, 72)
    }

    // PR2: step()/TwinReadout.derive replace TwinStateStore's old
    // predictedTomorrow(from:) string match — these test the actual
    // physiological mechanism directly, independent of assess()'s own
    // real-signal score (which stays unchanged, see TwinAssessment's
    // comment).
    func testStepWithHardSessionLowersReadinessTomorrow() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        // A well-established, moderately fresh baseline — some fitness,
        // little fatigue — so a hard session has real fatigue to add
        // rather than starting from zero on both sides.
        let baseline = TwinPhysiology(fitnessAerobic: 200, fatigueAerobic: 40, fitnessStrength: 150, fatigueStrength: 20,
                                      muscleFatigue: [:], sleepDebtHours: 0, illness: false, asOf: today)
        let restReadout = TwinReadout.derive(from: baseline, anchor: neutralAnchor, calibration: neutralCalibration)

        let hard = step(baseline, session: SessionLoad.forecast(.longRun), recoverySignals: .none, dtDays: 1)
        let hardReadout = TwinReadout.derive(from: hard, anchor: neutralAnchor, calibration: neutralCalibration)

        XCTAssertGreaterThan(hard.fatigueAerobic, baseline.fatigueAerobic,
                             "A real hard aerobic session must raise fatigueAerobic, not leave it where it started.")
        XCTAssertLessThan(hardReadout.score, restReadout.score,
                          "A hard session today must predict a LOWER readiness tomorrow than doing nothing would.")
    }

    func testStepWithRestRaisesReadinessTomorrow() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        // Real accumulated fatigue on both channels — this is what a rest
        // day should measurably drain.
        let fatigued = TwinPhysiology(fitnessAerobic: 200, fatigueAerobic: 180, fitnessStrength: 150, fatigueStrength: 130,
                                      muscleFatigue: ["Cuádriceps": 70], sleepDebtHours: 3, illness: false, asOf: today)
        let fatiguedReadout = TwinReadout.derive(from: fatigued, anchor: neutralAnchor, calibration: neutralCalibration)

        let rested = step(fatigued, session: .none, recoverySignals: .none, dtDays: 1)
        let restedReadout = TwinReadout.derive(from: rested, anchor: neutralAnchor, calibration: neutralCalibration)

        XCTAssertLessThan(rested.fatigueAerobic, fatigued.fatigueAerobic, "A rest day must drain fatigue, not hold it constant.")
        XCTAssertLessThan(rested.muscleFatigue["Cuádriceps"] ?? 100, fatigued.muscleFatigue["Cuádriceps"] ?? 100)
        XCTAssertGreaterThan(restedReadout.score, fatiguedReadout.score,
                             "A real rest day must predict a HIGHER readiness tomorrow than staying just as fatigued would.")
    }

    func testStepIsPureAndDeterministic() {
        let state = TwinPhysiology(fitnessAerobic: 100, fatigueAerobic: 50, fitnessStrength: 80, fatigueStrength: 30,
                                   muscleFatigue: ["Pecho": 20], sleepDebtHours: 1, illness: false, asOf: Date(timeIntervalSince1970: 1_700_000_000))
        let signals = RecoverySignals(hrvDeviation: -0.1, restingHeartRateDeviation: 0.05, sleepDeficitHours: 2, checkIn: nil, physiologicalAlert: nil)
        let first = step(state, session: SessionLoad.forecast(.strength), recoverySignals: signals, dtDays: 1)
        let second = step(state, session: SessionLoad.forecast(.strength), recoverySignals: signals, dtDays: 1)
        XCTAssertEqual(first, second, "Same (state, session, recoverySignals, dtDays) must always produce the same next state.")
    }

    // The exact regression this replaces: predictedTomorrow used to be
    // `recommendation.contains("tirada larga") ? -4 : ...` — a fixed delta
    // keyed on the Spanish copy, identical for every "tirada larga" no
    // matter how fatigued the athlete actually was. Two physiologies that
    // would both propose the SAME session kind (so the same old string
    // would have matched) but start from genuinely different real fatigue
    // must now predict genuinely different tomorrows.
    func testPredictedTomorrowReflectsRealStateNotFixedTextDelta() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = TwinPhysiology(fitnessAerobic: 200, fatigueAerobic: 20, fitnessStrength: 150, fatigueStrength: 10,
                                   muscleFatigue: [:], sleepDebtHours: 0, illness: false, asOf: today)
        let alreadyStrained = TwinPhysiology(fitnessAerobic: 200, fatigueAerobic: 170, fitnessStrength: 150, fatigueStrength: 120,
                                             muscleFatigue: ["Isquios": 60], sleepDebtHours: 4, illness: false, asOf: today)

        // Same session kind for both — the exact case the old string-match
        // treated identically regardless of real state.
        let freshTomorrow = step(fresh, session: SessionLoad.forecast(.longRun), recoverySignals: .none, dtDays: 1)
        let strainedTomorrow = step(alreadyStrained, session: SessionLoad.forecast(.longRun), recoverySignals: .none, dtDays: 1)
        let freshReadout = TwinReadout.derive(from: freshTomorrow, anchor: neutralAnchor, calibration: neutralCalibration)
        let strainedReadout = TwinReadout.derive(from: strainedTomorrow, anchor: neutralAnchor, calibration: neutralCalibration)

        XCTAssertNotEqual(freshReadout.score, strainedReadout.score,
                          "Two athletes proposed the same 'tirada larga' from genuinely different real fatigue must not get the same predicted tomorrow.")
        XCTAssertGreaterThan(freshReadout.score, strainedReadout.score,
                             "The already-strained athlete must predict a lower tomorrow than the fresh one, not an identical fixed delta.")
    }

    func testMultiDayProjectionRecoversWhileAcuteLoadDecays() {
        let trajectory = DecisionSimulatorEngine.projectTrajectory(
            tomorrowReadiness: 48, projectedAcuteLoad: 150,
            projectedChronicLoad: 100, days: 4
        )

        XCTAssertEqual(trajectory.count, 4)
        XCTAssertGreaterThan(trajectory.last?.readiness ?? 0, trajectory.first?.readiness ?? 100)
        XCTAssertLessThan(trajectory.last?.acuteLoad ?? 1_000, trajectory.first?.acuteLoad ?? 0)
        XCTAssertLessThan(trajectory.last?.loadRatio ?? 10, trajectory.first?.loadRatio ?? 0)
    }

    func testEnergyConfidenceFallsWhenCoreSignalsAreMissing() {
        let sparse = ConfidenceEngine.energy(
            baselineConfidence: 20, hasSleep: false, hasSleepStages: false,
            hasHRV: false, hasRestingHeartRate: false, hasCheckIn: false,
            activityEvents: 0, updatedAt: nil
        )
        let complete = ConfidenceEngine.energy(
            baselineConfidence: 85, hasSleep: true, hasSleepStages: true,
            hasHRV: true, hasRestingHeartRate: true, hasCheckIn: true,
            activityEvents: 2, updatedAt: Date(), now: Date()
        )

        XCTAssertEqual(sparse.level, .low)
        XCTAssertEqual(complete.level, .high)
        XCTAssertGreaterThan(complete.score, sparse.score)
    }

    func testReadinessConfidenceRewardsPersonalHistoryAndCheckIn() {
        let sparse = ConfidenceEngine.readiness(
            baselineConfidence: 15, signalCount: 1, hasCheckIn: false, updatedAt: nil
        )
        let complete = ConfidenceEngine.readiness(
            baselineConfidence: 90, signalCount: 7, hasCheckIn: true,
            updatedAt: Date(), now: Date()
        )
        XCTAssertEqual(sparse.level, .low)
        XCTAssertEqual(complete.level, .high)
        XCTAssertGreaterThan(complete.score, sparse.score)
    }

    func testTrainingLoadConfidenceRequiresEnoughObservedDays() {
        let early = ConfidenceEngine.trainingLoad(observedDays: 5, sessions: 2)
        let mature = ConfidenceEngine.trainingLoad(observedDays: 28, sessions: 9)
        XCTAssertEqual(early.level, .low)
        XCTAssertEqual(mature.level, .high)
    }

    func testPhysiologicalAlertIgnoresSingleModerateDeviation() {
        let now = Date()
        let alert = PhysiologicalAlertEngine.evaluate(
            signals: [alertSignal("HRV", deviation: -1.2, date: now)],
            illness: false, hasCheckIn: false, now: now
        )
        XCTAssertNil(alert)
    }

    func testPhysiologicalAlertTurnsConcordantSignalsIntoAction() {
        let now = Date()
        let alert = PhysiologicalAlertEngine.evaluate(
            signals: [
                alertSignal("HRV", deviation: -1.3, date: now),
                alertSignal("Pulso en reposo", deviation: -1.4, date: now)
            ], illness: false, hasCheckIn: true, now: now
        )
        XCTAssertEqual(alert?.severity, .caution)
        XCTAssertEqual(alert?.signals.count, 2)
        XCTAssertTrue(alert?.action.contains("intensidad") == true)
    }

    func testPhysiologicalAlertRejectsStaleSignals() {
        let now = Date()
        let stale = now.addingTimeInterval(-72 * 3_600)
        let alert = PhysiologicalAlertEngine.evaluate(
            signals: [
                alertSignal("HRV", deviation: -2.1, date: stale),
                alertSignal("Sueño", deviation: -2.0, date: stale)
            ], illness: false, hasCheckIn: false, now: now
        )
        XCTAssertNil(alert)
    }

    func testHabitAssociationNeedsTwoMatchedMornings() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-20 * 86_400)
        let occurrence = HabitOccurrence(kind: .alcohol, date: start.addingTimeInterval(20 * 3_600), overlapsOtherFactors: false)
        let hrv = (0..<12).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: $0 == 1 ? 40 : 50) }

        let result = HabitAssociationEngine.analyze(
            occurrences: [occurrence], hrv: hrv,
            restingHeartRate: [], sleep: [], now: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testHabitAssociationLearnsDirectionFromPersonalPriorBaseline() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        let exposureDays = [10, 20, 30]
        let occurrences = exposureDays.map {
            HabitOccurrence(kind: .alcohol, date: start.addingTimeInterval(Double($0) * 86_400 + 20 * 3_600), overlapsOtherFactors: false)
        }
        let hrv = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 40 : 50)
        }
        let sleep = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 6.5 : 8)
        }

        let result = HabitAssociationEngine.analyze(
            occurrences: occurrences, hrv: hrv,
            restingHeartRate: [], sleep: sleep, now: Date()
        )
        let alcohol = result.first { $0.kind == .alcohol }
        XCTAssertEqual(alcohol?.samples, 3)
        XCTAssertEqual(alcohol?.direction, .adverse)
        XCTAssertLessThan(alcohol?.compositeChange ?? 0, -10)
    }

    func testHabitAssociationTracksEachSupplementIndependently() {
        // Same learned-association mechanism sauna/agua fría already use —
        // no assumed acute effect, just a real pattern in this person's
        // own sleep data across enough matched mornings.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        let exposureDays = [10, 20, 30]
        let events = exposureDays.map { day in
            LifestyleEvent(id: UUID(), date: start.addingTimeInterval(Double(day) * 86_400 + 22 * 3_600),
                           alcoholDrinks: 0, saunaMinutes: 0, saunaTemperatureC: 80, coldMinutes: 0, coldTemperatureC: 12,
                           timeZoneDifference: 0, travelDirection: .east, caffeineMg: 0, caffeineDate: nil,
                           foodQuality: .notRecorded, fastingHours: 0, trainedFasted: false, lateDinner: false, heavyDinner: false,
                           hydration: .notRecorded, electrolytes: false, digestiveSymptoms: [],
                           supplements: [.magnesiumGlycinate], note: "")
        }
        let sleep = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 8.2 : 6.5)
        }

        let result = HabitAssociationEngine.analyze(events: events, alcohol: [], hrv: [], restingHeartRate: [], sleep: sleep, now: Date())
        guard let association = result.first(where: { $0.kind == .magnesiumGlycinate }) else {
            XCTFail("Expected a magnesium association to be learned from 3 matched mornings.")
            return
        }
        XCTAssertEqual(association.samples, 3)
        XCTAssertEqual(association.direction, .favorable)
        // Nothing else in this data implies a melatonin pattern — the two
        // supplements must not bleed into each other's learned association.
        XCTAssertNil(result.first(where: { $0.kind == .melatonin }))
    }

    func testSupplementKindNoLongerOffersCreatine() {
        // Removed: creatine's real, replicated evidence (strength/power/
        // lean-mass gains) has no plausible mechanistic path to HRV,
        // resting heart rate, or sleep — the only three signals this
        // learned-association mechanism actually observes.
        XCTAssertFalse(SupplementKind.allCases.contains { $0.rawValue == "Creatina" })
    }

    func testLifestyleEventDecodingDropsUnknownSupplementValuesInsteadOfFailingTheWholeEvent() {
        // A raw value that no longer maps to any case (like the removed
        // "Creatina") must not throw and lose the whole decoded event —
        // decodeIfPresent only guards a *missing* key, not an
        // unrecognized value for a key that IS present.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000000","date":1000000,"alcoholDrinks":0,"saunaMinutes":0,\
        "coldMinutes":0,"timeZoneDifference":0,"travelDirection":"Hacia el este","note":"",\
        "supplements":["Creatina","Melatonina"]}
        """.data(using: .utf8)!
        let event = try! JSONDecoder().decode(LifestyleEvent.self, from: json)
        XCTAssertEqual(event.supplements, [.melatonin])
    }

    func testLateCaffeineFallsBackToEventDateWhenCaffeineDateIsNotSet() {
        // caffeineDate is only an explicit override of the "Hora de
        // consumo" picker — most entries never touch it, so the
        // late-caffeine detection (and the caffeine effect itself) must
        // still work from the event's own date, not silently disappear.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        let exposureDays = [10, 20, 30]
        let events = exposureDays.map { day in
            LifestyleEvent(id: UUID(), date: start.addingTimeInterval(Double(day) * 86_400 + 22 * 3_600),
                           alcoholDrinks: 0, saunaMinutes: 0, saunaTemperatureC: 80, coldMinutes: 0, coldTemperatureC: 12,
                           timeZoneDifference: 0, travelDirection: .east, caffeineMg: 150, caffeineDate: nil,
                           foodQuality: .notRecorded, fastingHours: 0, trainedFasted: false, lateDinner: false, heavyDinner: false,
                           hydration: .notRecorded, electrolytes: false, digestiveSymptoms: [], supplements: [], note: "")
        }
        let sleep = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 6.0 : 7.5)
        }
        let result = HabitAssociationEngine.analyze(events: events, alcohol: [], hrv: [], restingHeartRate: [], sleep: sleep, now: Date())
        guard let association = result.first(where: { $0.kind == .lateCaffeine }) else {
            XCTFail("caffeineDate being nil must not silently drop the late-caffeine occurrence — it should fall back to event.date's own hour (22:00, well past the 14:00 cutoff).")
            return
        }
        XCTAssertEqual(association.samples, 3)
    }

    func testSupplementsUseTheirOwnTimestampInsteadOfTheSharedEventDate() {
        // A dose logged at 1am is a different calendar day than the event's
        // own `date` (set to 8am the same "day" the entry is filed under) —
        // supplementsDate exists exactly so the "day after" comparison
        // tracks when the dose was actually taken, not the day-level date
        // every other unrelated factor in the same entry shares.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-42 * 86_400)
        let exposureDays = [10, 20, 30]
        let events = exposureDays.map { day in
            LifestyleEvent(id: UUID(), date: start.addingTimeInterval(Double(day) * 86_400 + 8 * 3_600),
                           alcoholDrinks: 0, saunaMinutes: 0, saunaTemperatureC: 80, coldMinutes: 0, coldTemperatureC: 12,
                           timeZoneDifference: 0, travelDirection: .east, caffeineMg: 0, caffeineDate: nil,
                           foodQuality: .notRecorded, fastingHours: 0, trainedFasted: false, lateDinner: false, heavyDinner: false,
                           hydration: .notRecorded, electrolytes: false, digestiveSymptoms: [], supplements: [.melatonin],
                           supplementsDate: start.addingTimeInterval(Double(day) * 86_400 + 25 * 3_600), note: "")
        }
        // day+1 (the wrong "day after" if the bug used event.date's own
        // calendar day) reads badly; day+2 (the real day after
        // supplementsDate, which is already past midnight) reads well.
        let sleep = (0..<40).map { day -> TrendPoint in
            let value: Double
            if exposureDays.map({ $0 + 2 }).contains(day) { value = 8.2 }
            else if exposureDays.map({ $0 + 1 }).contains(day) { value = 6.0 }
            else { value = 7.0 }
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: value)
        }
        let result = HabitAssociationEngine.analyze(events: events, alcohol: [], hrv: [], restingHeartRate: [], sleep: sleep, now: Date())
        guard let association = result.first(where: { $0.kind == .melatonin }) else {
            XCTFail("Expected a melatonin association from 3 matched mornings.")
            return
        }
        XCTAssertEqual(association.samples, 3)
        XCTAssertEqual(association.direction, .favorable,
                       "The day-after comparison must anchor on supplementsDate (crossing into the next calendar day), not on the shared event.date — otherwise it reads the wrong morning's sleep and comes out adverse instead of favorable.")
    }

    func testTwinEngineCaffeineFallsBackToEventDateInsteadOfBeingSilentlyDropped() {
        let now = Date()
        let event = LifestyleEvent(id: UUID(), date: now.addingTimeInterval(-2 * 3_600),
                                   alcoholDrinks: 0, saunaMinutes: 0, saunaTemperatureC: 80, coldMinutes: 0, coldTemperatureC: 12,
                                   timeZoneDifference: 0, travelDirection: .east, caffeineMg: 200, caffeineDate: nil,
                                   foodQuality: .notRecorded, fastingHours: 0, trainedFasted: false, lateDinner: false, heavyDinner: false,
                                   hydration: .notRecorded, electrolytes: false, digestiveSymptoms: [], supplements: [], note: "")
        LifestyleFactorStore.shared.save(event)
        defer { LifestyleFactorStore.shared.delete(event) }

        // TwinCore PR1: assess no longer reads LifestyleFactorStore.shared
        // internally — the saved event above is passed explicitly instead,
        // same real data, just an explicit argument now.
        let assessment = TwinEngine.assess(health: HealthStore(), imports: ImportStore(), checkIn: nil,
                                           context: TwinContext(profile: neutralProfile, events: LifestyleFactorStore.shared.events, reviews: [],
                                                                activeInjuries: [], calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                           now: now)
        XCTAssertTrue(assessment.signals.contains { $0.name == "Cafeína" },
                      "Caffeine with no explicit caffeineDate override must still be counted, falling back to the event's own date instead of being silently skipped.")
    }

    func testHabitAssociationLearnsFromRespiratoryRateAndWristTemperature() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        let exposureDays = [10, 20, 30]
        let occurrences = exposureDays.map {
            HabitOccurrence(kind: .alcohol, date: start.addingTimeInterval(Double($0) * 86_400 + 20 * 3_600), overlapsOtherFactors: false)
        }
        // Both rise the morning after exposure — the adverse direction for
        // favorableHigh: false metrics, same convention PhysiologicalAlertEngine
        // already uses for these two signals.
        let respiratoryRate = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 18 : 14)
        }
        let wristTemperature = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 34.5 : 33.5)
        }

        let result = HabitAssociationEngine.analyze(
            occurrences: occurrences, hrv: [], restingHeartRate: [], sleep: [],
            respiratoryRate: respiratoryRate, wristTemperature: wristTemperature, now: Date()
        )
        let alcohol = result.first { $0.kind == .alcohol }
        XCTAssertEqual(alcohol?.direction, .adverse)
        XCTAssertTrue(alcohol?.effects.contains { $0.name == "Respiración" } ?? false)
        XCTAssertTrue(alcohol?.effects.contains { $0.name == "Temperatura de muñeca" } ?? false)
    }

    func testHabitAssociationHeadlineNamesTheDominantMetricNotJustAnAverage() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        let exposureDays = [8, 16, 24, 32]
        let occurrences = exposureDays.map {
            HabitOccurrence(kind: .fasting, date: start.addingTimeInterval(Double($0) * 86_400 + 20 * 3_600), overlapsOtherFactors: false)
        }
        // Only sleep moves after exposure; HRV stays flat — an isolated
        // effect, not a whole-body one. A plain average of the two would
        // hide that distinction; the headline should name it explicitly.
        // 4 exposures (not 3) so this clears the "samples < 4" tentative
        // branch and actually exercises the isolated-vs-systemic breakdown.
        let hrv = (0..<36).map { day in TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: 50) }
        let sleep = (0..<36).map { day -> TrendPoint in
            let isAfterExposure = exposureDays.contains(day - 1)
            return TrendPoint(date: start.addingTimeInterval(Double(day) * 86_400), value: isAfterExposure ? 9.2 : 8)
        }

        let result = HabitAssociationEngine.analyze(occurrences: occurrences, hrv: hrv, restingHeartRate: [], sleep: sleep, now: Date())
        let fasting = result.first { $0.kind == .fasting }
        XCTAssertEqual(fasting?.direction, .favorable)
        XCTAssertTrue(fasting?.headline.localizedCaseInsensitiveContains("sueño") == true, "Headline should name sleep as the metric actually driving this, not just report an average.")
        XCTAssertTrue(fasting?.headline.localizedCaseInsensitiveContains("concentrado") == true || fasting?.headline.localizedCaseInsensitiveContains("apenas") == true,
                      "Since HRV stayed flat, the headline should say this is an isolated effect, not a whole-body pattern.")
    }

    func testHabitAssociationConfidencePenalizesOverlappingFactors() {
        let isolated = ConfidenceEngine.habitAssociation(samples: 6, metrics: 3, overlapRatio: 0, consistency: 0.8)
        let confounded = ConfidenceEngine.habitAssociation(samples: 6, metrics: 3, overlapRatio: 1, consistency: 0.8)
        XCTAssertGreaterThan(isolated.score, confounded.score)
    }

    func testHabitAssociationOnlyChangesReadinessWithEnoughConfidence() {
        let low = HabitAssociation(
            kind: .sauna, samples: 3, effects: [], compositeChange: 16,
            direction: .favorable,
            confidence: ConfidenceAssessment(score: 35, level: .low, reason: "Hipótesis"),
            headline: "Primer patrón"
        )
        let medium = HabitAssociation(
            kind: .sauna, samples: 6, effects: [], compositeChange: 16,
            direction: .favorable,
            confidence: ConfidenceAssessment(score: 58, level: .medium, reason: "Patrón"),
            headline: "Patrón repetido"
        )
        let highAdverse = HabitAssociation(
            kind: .lateCaffeine, samples: 12, effects: [], compositeChange: -40,
            direction: .adverse,
            confidence: ConfidenceAssessment(score: 82, level: .high, reason: "Patrón maduro"),
            headline: "Patrón repetido"
        )

        XCTAssertEqual(HabitAssociationEngine.readinessImpact(low), 0)
        XCTAssertEqual(HabitAssociationEngine.readinessImpact(medium), 3)
        XCTAssertEqual(HabitAssociationEngine.readinessImpact(highAdverse), -5, "El aprendizaje siempre queda acotado")
    }

    func testElectrolytesMitigateOnlyCompatibleStressors() {
        XCTAssertEqual(HabitAssociationEngine.electrolyteMitigation(
            hydrationLow: false, saunaMinutes: 0, prolongedExerciseMinutes: 30
        ), 0)
        XCTAssertEqual(HabitAssociationEngine.electrolyteMitigation(
            hydrationLow: true, saunaMinutes: 20, prolongedExerciseMinutes: 100
        ), 3, "La mitigación combinada debe quedar limitada")
    }

    func testWristTemperatureCannotTriggerAlertByItself() {
        let now = Date()
        let temperature = PhysiologicalAlertSignal(
            name: "Temperatura de muñeca", value: "36,8 °C",
            favorableDeviation: -2.4, confidence: 90, measuredAt: now,
            corroboratingOnly: true
        )

        XCTAssertNil(PhysiologicalAlertEngine.evaluate(
            signals: [temperature], illness: false, hasCheckIn: false, now: now
        ))
    }

    func testWristTemperatureStrengthensAnotherAdverseSignal() {
        let now = Date()
        let temperature = PhysiologicalAlertSignal(
            name: "Temperatura de muñeca", value: "36,8 °C",
            favorableDeviation: -1.8, confidence: 85, measuredAt: now,
            corroboratingOnly: true
        )
        let alert = PhysiologicalAlertEngine.evaluate(
            signals: [alertSignal("HRV", deviation: -1.2, date: now), temperature],
            illness: false, hasCheckIn: true, now: now
        )

        XCTAssertEqual(alert?.severity, .caution)
        XCTAssertTrue(alert?.signals.contains { $0.name == "Temperatura de muñeca" } == true)
        XCTAssertFalse(alert?.summary.lowercased().contains("enfermedad") == true)
    }

    func testLongevityIndexNormalizesOnlyAvailableDimensionsButReportsCoverage() {
        let dimensions = [
            LongevityDimension(name: "Capacidad aeróbica", pillar: .functional, score: 80,
                               weight: 0.18, confidence: .high, evidence: "VO2"),
            LongevityDimension(name: "Cardiovascular", pillar: .protection, score: 60,
                               weight: 0.14, confidence: .medium, evidence: "Tensión")
        ]
        let index = LongevityEngine.combine(dimensions: dimensions)

        XCTAssertEqual(index.coverage, 32)
        XCTAssertNil(index.score, "No debe publicar un índice global con menos del 40% de cobertura")
        XCTAssertEqual(index.pillars.count, 2)
    }

    func testLongevityHybridScoreKeepsPillarsAuditable() {
        let dimensions = [
            LongevityDimension(name: "Capacidad aeróbica", pillar: .functional, score: 90,
                               weight: 0.20, confidence: .high, evidence: "VO2"),
            LongevityDimension(name: "Cardiovascular", pillar: .protection, score: 60,
                               weight: 0.20, confidence: .high, evidence: "Tensión"),
            LongevityDimension(name: "Recuperación", pillar: .resilience, score: 75,
                               weight: 0.20, confidence: .high, evidence: "Sueño")
        ]
        let index = LongevityEngine.combine(dimensions: dimensions)

        XCTAssertEqual(index.score, 75)
        XCTAssertEqual(index.coverage, 60)
        XCTAssertEqual(index.pillars.first { $0.pillar == .functional }?.score, 90)
        XCTAssertNotNil(index.priority)
    }

    func testExerciseCatalogFlagsHoldsAndCarriesAsTimedNotReps() {
        XCTAssertTrue(ExerciseCatalog.descriptor(for: "Plank").isTimed)
        XCTAssertTrue(ExerciseCatalog.descriptor(for: "Side Plank").isTimed)
        XCTAssertTrue(ExerciseCatalog.descriptor(for: "Farmer Carry").isTimed)
        XCTAssertTrue(ExerciseCatalog.descriptor(for: "Wall Sit").isTimed, "recae en el heurístico por nombre, no está en el catálogo fijo")
        XCTAssertTrue(ExerciseCatalog.descriptor(for: "Plancha lateral").isTimed, "debe reconocer también el nombre en español")
        XCTAssertFalse(ExerciseCatalog.descriptor(for: "Dead Bug").isTimed, "es un movimiento con repeticiones, no una plancha")
        XCTAssertFalse(ExerciseCatalog.descriptor(for: "Squat (Barbell)").isTimed)
    }

    func testCardioFactorGivesSwimmingItsOwnWeight() {
        XCTAssertEqual(PerformanceEngine.cardioFactor("Natación"), 1.10)
        XCTAssertNotEqual(PerformanceEngine.cardioFactor("Natación"), PerformanceEngine.cardioFactor("Entrenamiento"),
                          "antes de mapear .swimming, toda natación caía en el genérico 'Entrenamiento'")
    }

    func testGradeAdjustedPaceMakesUphillRunsLookFasterOnTheFlat() {
        let flat = RunningPerformanceEngine.gradeAdjustedMinutes(minutes: 30, kilometers: 5, elevationMeters: 0)
        let uphill = RunningPerformanceEngine.gradeAdjustedMinutes(minutes: 30, kilometers: 5, elevationMeters: 150) // 3% avg grade
        let negligible = RunningPerformanceEngine.gradeAdjustedMinutes(minutes: 30, kilometers: 5, elevationMeters: 5)
        let noElevationData = RunningPerformanceEngine.gradeAdjustedMinutes(minutes: 30, kilometers: 5, elevationMeters: nil)

        XCTAssertEqual(flat, 30, "sin desnivel, la corrección no debe cambiar nada")
        XCTAssertLessThan(uphill, 30, "una carrera con subida real debe traducirse en un tiempo equivalente en llano más rápido")
        XCTAssertEqual(negligible, 30, accuracy: 0.01, "una pendiente media insignificante no debe introducir ruido")
        XCTAssertEqual(noElevationData, 30, "sin dato de desnivel, se devuelve el tiempo original sin inventar nada")
    }

    func testBiologicalAgeReturnsNilWithoutBirthDateOrConsistentDraw() {
        let day = testDate(2026, 1, 26)
        let complete = [
            labResult("Glucosa", 83.00, date: day), labResult("Creatinina", 1.11, date: day),
            labResult("Leucocitos", 4.11, date: day), labResult("Linfocitos %", 35.30, date: day),
            labResult("Volumen Corpuscular Medio (MCV)", 88.70, date: day),
            labResult("Amplitud distribución eritrocitaria (RDW)", 12.20, date: day)
        ]
        XCTAssertNil(BiologicalAgeEngine.calculate(labs: complete, birthDate: nil), "sin fecha de nacimiento no debe inventar una edad")

        let incomplete = Array(complete.dropLast(2)) // sin MCV ni RDW
        XCTAssertNil(BiologicalAgeEngine.calculate(labs: incomplete, birthDate: testDate(1983, 7, 23)), "sin todos los marcadores de una misma extracción no debe estimar nada")
    }

    func testBiologicalAgeNeverMixesBiomarkersFromDifferentDraws() {
        // The bug this guards against: the same "latest" label picking each
        // marker independently across two separate blood draws instead of one
        // internally consistent set — caught while building this same feature
        // for the web dashboard.
        let olderCompleteDraw = testDate(2026, 1, 26)
        let newerIncompleteDraw = testDate(2026, 6, 10)
        let labs = [
            // A newer draw that only has glucose/creatinine — never gathered
            // enough evidence on its own, so must NOT be blended with the older one.
            labResult("Glucosa", 90.00, date: newerIncompleteDraw),
            labResult("Creatinina", 1.05, date: newerIncompleteDraw),
            labResult("Glucosa", 83.00, date: olderCompleteDraw), labResult("Creatinina", 1.11, date: olderCompleteDraw),
            labResult("Leucocitos", 4.11, date: olderCompleteDraw), labResult("Linfocitos %", 35.30, date: olderCompleteDraw),
            labResult("Volumen Corpuscular Medio (MCV)", 88.70, date: olderCompleteDraw),
            labResult("Amplitud distribución eritrocitaria (RDW)", 12.20, date: olderCompleteDraw)
        ]
        let draw = BiologicalAgeEngine.mostRecentConsistentDraw(in: labs)
        XCTAssertEqual(draw?.date, Calendar.current.startOfDay(for: olderCompleteDraw))
        XCTAssertEqual(draw?.glucoseMgDl, 83.00, "debe usar la glucosa de la extracción completa, no la más reciente e incompleta")
    }

    func testBiologicalAgeMatchesVerifiedPhenoAgeFormula() throws {
        // Same inputs already verified against ajsteele/bioage (CC0) for the
        // web dashboard's equivalent feature; the expected numbers below were
        // computed independently in Python from the published formula, not
        // copied from this engine, so this catches a transcription error.
        let draw = testDate(2026, 1, 26)
        let birthDate = testDate(1983, 7, 23)
        let labs = [
            labResult("Glucosa", 83.00, date: draw), labResult("Creatinina", 1.11, date: draw),
            labResult("Leucocitos", 4.11, date: draw), labResult("Linfocitos %", 35.30, date: draw),
            labResult("Volumen Corpuscular Medio (MCV)", 88.70, date: draw),
            labResult("Amplitud distribución eritrocitaria (RDW)", 12.20, date: draw)
        ]
        let estimate = try XCTUnwrap(BiologicalAgeEngine.calculate(labs: labs, birthDate: birthDate))

        XCTAssertEqual(estimate.chronologicalAge, 42)
        XCTAssertEqual(estimate.estimatedAge, 33.44, accuracy: 0.05)
        XCTAssertEqual(estimate.delta, -8.56, accuracy: 0.05)
        XCTAssertEqual(estimate.uncertainty, 1.59, accuracy: 0.05)
        XCTAssertEqual(estimate.imputedMarkers.count, 3, "siempre imputa albúmina, PCR y fosfatasa alcalina hasta que se pidan en una analítica")
        XCTAssertEqual(estimate.confidence, .medium)
    }

    func testHyroxRunPenaltyNarrowsWithSpecificEvidence() {
        let unknown = HyroxForecastEngine.compromisedRunPenalty(stationCoverage: 0, specificSessions: 0)
        let trained = HyroxForecastEngine.compromisedRunPenalty(stationCoverage: 8, specificSessions: 4)

        XCTAssertLessThan(trained.lowerBound, unknown.lowerBound)
        XCTAssertLessThan(trained.upperBound, unknown.upperBound)
    }

    func testHyroxForecastRequiresRunningEvidence() {
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 0, priorKilometers7Days: 0,
            fiveK: nil, tenK: nil, halfMarathon: nil, marathon: nil,
            easyPercentage: 0, hardPercentage: 0, hasZoneData: false
        )

        XCTAssertNil(HyroxForecastEngine.forecast(running: running, workouts: []))
    }

    func testHyroxBottleneckFlagsLowVO2MaxAsTheRealLimiterOverStationCoverage() {
        // Brandt et al. 2025: VO2max correlates with total HYROX time
        // (ρ=-0.71) more than anything else — this must take priority
        // over the old "not enough stations observed" bottleneck once a
        // real VO2max reading exists and is below the reference band.
        let race = RaceForecast(distanceName: "10 km", seconds: 3_000, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        let forecast = HyroxForecastEngine.forecast(running: running, workouts: [], vo2Max: 30)
        XCTAssertTrue(forecast?.bottleneck.contains("aeróbica") ?? false, "Expected the VO2max bottleneck: \(forecast?.bottleneck ?? "nil")")
    }

    func testHyroxBottleneckFlagsHighBodyFatWhenVO2MaxIsFine() {
        let race = RaceForecast(distanceName: "10 km", seconds: 3_000, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        let forecast = HyroxForecastEngine.forecast(running: running, workouts: [], vo2Max: 45, bodyFatPercentage: 32)
        XCTAssertTrue(forecast?.bottleneck.contains("composición corporal") ?? false, "Expected the body-fat bottleneck: \(forecast?.bottleneck ?? "nil")")
    }

    func testHyroxBottleneckFallsBackToStationCoverageWithoutVO2MaxOrBodyFatData() {
        let race = RaceForecast(distanceName: "10 km", seconds: 3_000, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        let forecast = HyroxForecastEngine.forecast(running: running, workouts: [])
        XCTAssertTrue(forecast?.bottleneck.contains("estaciones") ?? false, "No VO2max/body-fat data supplied — must fall back honestly: \(forecast?.bottleneck ?? "nil")")
    }

    func testHyroxForecastStaysLowConfidenceWithoutSpecificSessions() {
        let race = RaceForecast(distanceName: "10 km", seconds: 3_000, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        let forecast = HyroxForecastEngine.forecast(running: running, workouts: [])

        XCTAssertEqual(forecast?.confidence.level, .low)
        XCTAssertEqual(forecast?.stations.filter(\.observed).count, 0)
        XCTAssertGreaterThan(forecast?.conservativeSeconds ?? 0, forecast?.optimisticSeconds ?? 1)
    }

    func testTriathlonForecastRequiresRunningEvidence() {
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 0, priorKilometers7Days: 0,
            fiveK: nil, tenK: nil, halfMarathon: nil, marathon: nil,
            easyPercentage: 0, hardPercentage: 0, hasZoneData: false
        )
        XCTAssertNil(TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: []))
    }

    func testTriathlonForecastUsesGenericPaceWithoutSwimBikeHistory() {
        let race = RaceForecast(distanceName: "10 km", seconds: 2_400, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        let forecast = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: [])

        XCTAssertNotNil(forecast)
        XCTAssertFalse(forecast?.swimIsPersonal ?? true)
        XCTAssertFalse(forecast?.bikeIsPersonal ?? true)
        XCTAssertEqual(forecast?.confidence.level, .low)
        XCTAssertTrue(forecast?.bottleneck.localizedCaseInsensitiveContains("genérico") == true)
    }

    func testTriathlonForecastUsesPersonalPaceFromOwnSwimAndBikeHistory() {
        let race = RaceForecast(distanceName: "10 km", seconds: 2_400, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        // 2:00/100 m swim pace, 30 km/h bike speed — both distinctly
        // different from the generic 2:15/100m and 24 km/h fallbacks, so a
        // real personal number must move the forecast away from them.
        let swims = (0..<3).map { healthWorkout(activity: "Natación", kilometers: 1.5, minutes: 30, date: Date().addingTimeInterval(Double(-$0 - 1) * 86_400)) }
        let bikes = (0..<3).map { healthWorkout(activity: "Ciclismo", kilometers: 40, minutes: 80, date: Date().addingTimeInterval(Double(-$0 - 1) * 86_400)) }
        let forecast = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: swims + bikes)

        XCTAssertTrue(forecast?.swimIsPersonal ?? false)
        XCTAssertTrue(forecast?.bikeIsPersonal ?? false)
        XCTAssertEqual(forecast?.swimSeconds ?? 0, 1_800, accuracy: 1)
        XCTAssertEqual(forecast?.bikeSeconds ?? 0, 4_800, accuracy: 1)
    }

    func testTriathlonRunOffBikePenaltyNarrowsWithBrickEvidence() {
        let unknown = TriathlonForecastEngine.runOffBikePenalty(brickSessions: 0)
        let trained = TriathlonForecastEngine.runOffBikePenalty(brickSessions: 6)
        XCTAssertGreaterThan(unknown, trained)
        XCTAssertEqual(trained, 0.03, accuracy: 0.001)
    }

    func testTriathlonBrickSessionDetectsRunImmediatelyAfterBike() {
        let bike = healthWorkout(activity: "Ciclismo", kilometers: 30, minutes: 60, date: Date(timeIntervalSince1970: 1_000_000))
        let closeRun = healthWorkout(activity: "Carrera", kilometers: 3, minutes: 20, date: bike.date.addingTimeInterval(bike.durationMinutes * 60 + 10 * 60))
        let laterRun = healthWorkout(activity: "Carrera", kilometers: 5, minutes: 30, date: bike.date.addingTimeInterval(bike.durationMinutes * 60 + 5 * 3_600))

        XCTAssertEqual(TriathlonForecastEngine.brickSessionCount([bike, closeRun], now: closeRun.date.addingTimeInterval(3_600)), 1)
        XCTAssertEqual(TriathlonForecastEngine.brickSessionCount([bike, laterRun], now: laterRun.date.addingTimeInterval(3_600)), 0)
    }

    func testResolvedTriathlonDistanceDefaultsSensibly() {
        var ironman = TrainingGoal(id: UUID(), kind: .ironman, title: "Ironman", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true)
        // Even if a stale/incorrect distance were ever stored, "Ironman" as
        // a challenge name must always resolve to the full iron distance.
        ironman.triathlonDistance = .sprint
        XCTAssertEqual(ironman.resolvedTriathlonDistance, .full)

        let triathlonWithoutChoice = TrainingGoal(id: UUID(), kind: .triathlon, title: "Triatlón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true)
        XCTAssertEqual(triathlonWithoutChoice.resolvedTriathlonDistance, .olympic)

        var triathlonSprint = TrainingGoal(id: UUID(), kind: .triathlon, title: "Triatlón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true)
        triathlonSprint.triathlonDistance = .sprint
        XCTAssertEqual(triathlonSprint.resolvedTriathlonDistance, .sprint)

        let marathon = TrainingGoal(id: UUID(), kind: .marathon, title: "Maratón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true)
        XCTAssertNil(marathon.resolvedTriathlonDistance)
    }

    func testGoalFocusWeightsTriathlonAcrossRunningStrengthAndTriathlon() {
        let profile = AthletePlanProfile(goals: [
            TrainingGoal(id: UUID(), kind: .ironman, title: "Ironman", date: Calendar.current.date(byAdding: .day, value: 200, to: Date()),
                         targetValue: nil, unit: "min", priority: .primary, isActive: true)
        ], gymAvailable: true, trainingDaysPerWeek: 6, preferredLongRunWeekday: 7, maximumHeartRate: nil)

        let focus = TrainingPlanEngine.goalFocus(for: profile, on: Date())

        XCTAssertEqual(focus.triathlon, 0.55, accuracy: 0.01)
        XCTAssertEqual(focus.running, 0.30, accuracy: 0.01)
        XCTAssertEqual(focus.strength, 0.15, accuracy: 0.01)
        XCTAssertEqual(focus.leadingGoal, "Ironman")
    }

    func testSwimAndBikeBandsScaleUpForIronmanDistance() {
        let olympicSwim = WorkoutPlanner.swimBand(phase: .buildSpecific, targetKilometers: TriathlonDistance.olympic.swimKilometers)
        let ironmanSwim = WorkoutPlanner.swimBand(phase: .buildSpecific, targetKilometers: TriathlonDistance.full.swimKilometers)
        let olympicBike = WorkoutPlanner.bikeBand(phase: .buildSpecific, targetKilometers: TriathlonDistance.olympic.bikeKilometers)
        let ironmanBike = WorkoutPlanner.bikeBand(phase: .buildSpecific, targetKilometers: TriathlonDistance.full.bikeKilometers)

        XCTAssertGreaterThan(ironmanSwim.max, olympicSwim.max)
        XCTAssertGreaterThan(ironmanBike.max, olympicBike.max)
        // The bike leg's distance jump (180 vs 40 km, 4.5x) is much bigger
        // than the swim leg's (3.8 vs 1.5 km, 2.5x), so the bike band must
        // widen proportionally more — the wider cap exists precisely so
        // this doesn't get clipped to the same ratio as the swim band.
        XCTAssertGreaterThan(ironmanBike.max / olympicBike.max, ironmanSwim.max / olympicSwim.max)
    }

    func testBalancedDecisionPicksOverdueDisciplineForTriathlonGoal() {
        let focus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0, triathlon: 0.55, leadingGoal: "Ironman")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, daysSinceSwim: 10, daysSinceBike: 2,
            hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
            goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .swim)
        XCTAssertTrue(decision.rationale.localizedCaseInsensitiveContains("natación"))
    }

    func testBalancedDecisionOffersBrickOnlyDuringBuildOrTaperPhase() {
        let focus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0, triathlon: 0.55, leadingGoal: "Ironman")
        let base = TrainingBlock(name: "Base", phase: .base, start: Date(), end: Date().addingTimeInterval(30 * 86_400),
                                 objective: "", runningSessions: 0...0, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        let build = TrainingBlock(name: "Build", phase: .buildSpecific, start: Date(), end: Date().addingTimeInterval(30 * 86_400),
                                  objective: "", runningSessions: 0...0, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        func decide(_ block: TrainingBlock) -> PlannedSessionKind {
            TrainingPlanEngine.balancedDecision(
                runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
                daysSinceStrength: 2, daysSinceSwim: 2, daysSinceBike: 2,
                hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 80, muscles: muscles(legs: 80),
                block: block, goalFocus: focus
            ).kind
        }
        // Base training doesn't need race-specific bike-then-run fatigue yet.
        XCTAssertNotEqual(decide(base), .brick)
        XCTAssertEqual(decide(build), .brick)
    }

    func testBalancedDecisionWithholdsQualityRunWhenRecentIntensityAlreadyExceedsThePolarizedTarget() {
        // Closes the loop between RunningPerformanceEngine's own polarized
        // target (already computed and shown elsewhere) and what actually
        // gets proposed: a real recent hard% of 50 is already well past
        // the base phase's own 12–32% upper bound, so another quality
        // session must not be the answer even though its own score would
        // otherwise win comfortably.
        let base = TrainingBlock(name: "Base", phase: .base, start: Date(), end: Date().addingTimeInterval(30 * 86_400),
                                 objective: "", runningSessions: 0...0, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        let focus = GoalTrainingFocus(running: 0.75, strength: 0.20, hybrid: 0.05, leadingGoal: "10k")
        func decide(recentHardPercentage: Double?) -> PlannedSessionKind {
            TrainingPlanEngine.balancedDecision(
                runs: 2, targetRuns: 4, strength: 1, targetStrength: 1, quality: 0, targetQuality: 2,
                daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
                recentHardPercentage: recentHardPercentage,
                lateWeek: false, readiness: 75, muscles: muscles(legs: 80),
                block: base, goalFocus: focus
            ).kind
        }
        XCTAssertEqual(decide(recentHardPercentage: nil), .qualityRun, "Without real intensity data, the honest fallback must still allow it.")
        XCTAssertEqual(decide(recentHardPercentage: 50), .easyRun, "50% hard already busts the base phase's 12–32% target — must not add another quality session.")
    }

    private func healthWorkout(activity: String, kilometers: Double, minutes: Double, date: Date = Date(),
                               muscleGroups: [String: Double] = [:]) -> HealthWorkout {
        HealthWorkout(id: UUID(), date: date, durationMinutes: minutes, calories: nil,
                      distanceKilometers: kilometers, averageHeartRate: 140, elevationMeters: nil,
                      activity: activity, muscleGroups: muscleGroups, source: "Apple Watch")
    }

    func testTrainingBlockProgressRampsLinearlyAcrossThePhase() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(28 * 86_400) // a 4-week block
        let block = TrainingBlock(name: "Test", phase: .buildSpecific, start: start, end: end,
                                  objective: "", runningSessions: 1...1, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        XCTAssertEqual(block.progress(on: start), 0, accuracy: 0.001)
        XCTAssertEqual(block.progress(on: end), 1, accuracy: 0.001)
        XCTAssertEqual(block.progress(on: start.addingTimeInterval(14 * 86_400)), 0.5, accuracy: 0.01)
        // Never extrapolates past the block's own edges, even for a date
        // outside it (e.g. this same block queried after it's already over).
        XCTAssertEqual(block.progress(on: end.addingTimeInterval(86_400)), 1)
        XCTAssertEqual(block.progress(on: start.addingTimeInterval(-86_400)), 0)
    }

    func testQualitySessionRampsRepsByPhaseProgressAndNeverInventsAPaceWithoutHistory() {
        let noHistory = HealthStore()
        let earlyBase = WorkoutPlanner.intervalPrescription(phase: .base, progress: 0, health: noHistory, hrFloor: "")
        let lateBase = WorkoutPlanner.intervalPrescription(phase: .base, progress: 1, health: noHistory, hrFloor: "")
        // With zero run history, RunningPerformanceEngine has no forecast to
        // anchor a pace on — this must fall back to the generic prescription
        // rather than inventing a number, same principle as the forecast fix
        // earlier this session.
        XCTAssertTrue(earlyBase.prescription.localizedCaseInsensitiveContains("controladas"))
        XCTAssertFalse(earlyBase.prescription.contains("min/km"))
        XCTAssertTrue(earlyBase.basisNote.localizedCaseInsensitiveContains("sin marca de referencia"))
        // Rep count should still ramp with phase progress even in the
        // fallback text (4 at the start of base, 6 by the end).
        XCTAssertTrue(earlyBase.prescription.hasPrefix("4 "))
        XCTAssertTrue(lateBase.prescription.hasPrefix("6 "))
    }

    func testQualitySessionCalibratesPaceToOwnForecastWhenHistoryExists() {
        let health = HealthStore()
        // Several recent 5K-ish runs at a real, consistent pace (5:00/km) so
        // RunningPerformanceEngine's Riegel fallback (fastest of the last 60
        // days) has something concrete to anchor on.
        health.workoutHistory = (0..<4).map { index in
            HealthWorkout(id: UUID(), date: Date().addingTimeInterval(Double(-index - 1) * 5 * 86_400),
                         durationMinutes: 25, calories: nil, distanceKilometers: 5, averageHeartRate: 160,
                         elevationMeters: nil, activity: "Carrera", muscleGroups: ["Piernas": 1], source: "Apple Watch")
        }
        health.recentWorkouts = health.workoutHistory
        let build = WorkoutPlanner.intervalPrescription(phase: .buildSpecific, progress: 0.5, health: health, hrFloor: "")
        XCTAssertTrue(build.prescription.contains("min/km"), "Should compute a real target pace once a forecast exists, not the generic fallback.")
        XCTAssertTrue(build.prescription.contains("1000 m"), "Build-specific phase should prescribe threshold-length reps, not base's short 400m ones.")
        XCTAssertTrue(build.basisNote.localizedCaseInsensitiveContains("riegel"))
    }

    func testQualitySessionModalityRotatesThroughFourModalitiesInBasePhase() {
        // Real half-marathon periodization doesn't run the same flat-ground
        // interval template every single quality session all block long —
        // base phase specifically rotates in short sprints/strides, hill
        // repeats, and a VO2max-specific 4×4 block too. Deterministic by
        // full weeks since the block started, not random, so it's
        // explainable and testable.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let base = TrainingBlock(name: "Base", phase: .base, start: start, end: start.addingTimeInterval(84 * 86_400),
                                 objective: "", runningSessions: 1...1, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .base, block: base, now: start), .sprints)
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .base, block: base, now: start.addingTimeInterval(7 * 86_400)), .hillRepeats)
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .base, block: base, now: start.addingTimeInterval(14 * 86_400)), .vo2Max4x4)
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .base, block: base, now: start.addingTimeInterval(21 * 86_400)), .flatIntervals)
        // The cycle repeats rather than running out after 4 weeks.
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .base, block: base, now: start.addingTimeInterval(28 * 86_400)), .sprints)

        // Build-specific's job is race-pace-specific threshold work, and
        // taper's is short/fast sharpening — neither ever rotates away from
        // its own single, phase-correct template.
        let buildSpecific = TrainingBlock(name: "Build", phase: .buildSpecific, start: start, end: start.addingTimeInterval(84 * 86_400),
                                          objective: "", runningSessions: 1...1, strengthSessions: 0...0, qualitySessions: 0...0, emphasis: [])
        XCTAssertEqual(WorkoutPlanner.qualitySessionModality(phase: .buildSpecific, block: buildSpecific, now: start.addingTimeInterval(7 * 86_400)), .flatIntervals)
    }

    func testVO2Max4x4ModalityIsTimeAndHeartRateBasedNotPace() {
        // Helgerud/Wisløff's protocol was validated against heart rate,
        // not a flat-ground pace — must never claim a pace, and must name
        // the actual 4×4 structure.
        let prescription = WorkoutPlanner.intervalPrescription(phase: .base, progress: 0.5, health: HealthStore(), hrFloor: " · >165 ppm", modality: .vo2Max4x4)
        XCTAssertTrue(prescription.prescription.contains("4 × 4 min"))
        XCTAssertTrue(prescription.prescription.contains("90–95%"))
        XCTAssertTrue(prescription.prescription.contains(">165 ppm"))
        XCTAssertFalse(prescription.prescription.contains("min/km"), "Must never invent a pace for an HR-based protocol.")
    }

    func testSprintModalityPrescribesShortRepsWithNoInventedPace() {
        // Sprints are about neuromuscular power and economy, not aerobic
        // load — this must never touch the Riegel pace forecast at all,
        // with or without run history.
        let earlySprints = WorkoutPlanner.intervalPrescription(phase: .base, progress: 0, health: HealthStore(), hrFloor: "", modality: .sprints)
        let lateSprints = WorkoutPlanner.intervalPrescription(phase: .base, progress: 1, health: HealthStore(), hrFloor: "", modality: .sprints)
        XCTAssertTrue(earlySprints.prescription.contains("100 m"))
        XCTAssertFalse(earlySprints.prescription.contains("min/km"), "Sprints must never invent a flat-ground pace.")
        XCTAssertTrue(earlySprints.prescription.hasPrefix("6 "))
        XCTAssertTrue(lateSprints.prescription.hasPrefix("10 "))
    }

    func testHillRepeatModalityIsTimeBasedNotPaceBased() {
        // A gradient invalidates any flat-ground pace claim — this must be
        // effort/time-based, never a pace number this app can't compute
        // honestly on a hill.
        let earlyHills = WorkoutPlanner.intervalPrescription(phase: .base, progress: 0, health: HealthStore(), hrFloor: "", modality: .hillRepeats)
        let lateHills = WorkoutPlanner.intervalPrescription(phase: .base, progress: 1, health: HealthStore(), hrFloor: "", modality: .hillRepeats)
        XCTAssertTrue(earlyHills.prescription.contains("cuesta arriba"))
        XCTAssertTrue(earlyHills.prescription.contains("45–60 s"))
        XCTAssertFalse(earlyHills.prescription.contains("min/km"), "Hill repeats must never invent a flat-ground pace.")
        XCTAssertTrue(earlyHills.prescription.hasPrefix("5 "))
        XCTAssertTrue(lateHills.prescription.hasPrefix("8 "))
    }

    func testDistanceScaleAnchorsOnHalfMarathonAndCapsAtExtremes() {
        // No target (HYROX, strength, an unmodelled custom goal, or simply
        // no dated goal) must fall back to the original half-marathon
        // reference scale — never guess a distance.
        XCTAssertEqual(WorkoutPlanner.distanceScale(targetKilometers: nil), 1.0, accuracy: 0.001)
        XCTAssertEqual(WorkoutPlanner.distanceScale(targetKilometers: 21.0975), 1.0, accuracy: 0.001)
        // A marathon needs meaningfully more, but the ratio (~2.0) stays
        // under the 2.2 cap so it's the raw ratio, not the cap, driving it.
        XCTAssertEqual(WorkoutPlanner.distanceScale(targetKilometers: 42.195), 42.195 / 21.0975, accuracy: 0.001)
        // A 5K's raw ratio (~0.237) is far below what's physiologically
        // sane for a "long run" band, so the floor must kick in.
        XCTAssertEqual(WorkoutPlanner.distanceScale(targetKilometers: 5), 0.5, accuracy: 0.001)
        // An absurdly long ultra-style target must hit the ceiling, not
        // scale linearly forever.
        XCTAssertEqual(WorkoutPlanner.distanceScale(targetKilometers: 200), 2.2, accuracy: 0.001)
    }

    func testLongRunAndEasyRunBandsScaleWithTargetDistance() {
        let halfMarathonBand = WorkoutPlanner.longRunBand(phase: .buildSpecific, targetKilometers: 21.0975)
        let noTargetBand = WorkoutPlanner.longRunBand(phase: .buildSpecific)
        // A half marathon target must reproduce the original reference band
        // exactly — this feature was tuned against that distance first.
        XCTAssertEqual(halfMarathonBand.min, noTargetBand.min, accuracy: 0.01)
        XCTAssertEqual(halfMarathonBand.max, noTargetBand.max, accuracy: 0.01)

        let marathonBand = WorkoutPlanner.longRunBand(phase: .buildSpecific, targetKilometers: 42.195)
        // A marathon's peak long run must sit meaningfully above a half
        // marathon's — the concrete answer to "entiende la ambición y
        // recomienda el volumen necesario", not a flat number regardless
        // of race length.
        XCTAssertGreaterThan(marathonBand.min, halfMarathonBand.min)
        XCTAssertGreaterThan(marathonBand.max, halfMarathonBand.max)

        // Easy-run duration should scale far more gently (sqrt-dampened)
        // than the long run for the same distance jump.
        let easyHalf = WorkoutPlanner.easyRunBand(phase: .buildSpecific, targetKilometers: 21.0975)
        let easyMarathon = WorkoutPlanner.easyRunBand(phase: .buildSpecific, targetKilometers: 42.195)
        let longRatio = marathonBand.max / halfMarathonBand.max
        let easyRatio = easyMarathon.max / easyHalf.max
        XCTAssertLessThan(easyRatio, longRatio)
        XCTAssertGreaterThan(easyRatio, 1.0)
    }

    func testHyroxPhaseBandFollowsPeriodizationShape() {
        // Build-specific should ask for the most volume, taper/race the
        // least — the same shape the running bands already follow, applied
        // to a non-running goal instead of leaving it unmodelled.
        let base = WorkoutPlanner.hyroxPhaseBand(.base)
        let build = WorkoutPlanner.hyroxPhaseBand(.buildSpecific)
        let taper = WorkoutPlanner.hyroxPhaseBand(.taper)
        let race = WorkoutPlanner.hyroxPhaseBand(.race)
        XCTAssertGreaterThan(build.max, base.max)
        XCTAssertGreaterThan(base.max, taper.max)
        XCTAssertLessThanOrEqual(race.max, taper.max)
        XCTAssertTrue(base.min < base.max)
    }

    func testHyroxRotationCoversAllEightStationsDeterministically() {
        let now = Date()
        let firstCall = WorkoutPlanner.hyroxRotation(now: now)
        let secondCall = WorkoutPlanner.hyroxRotation(now: now)
        // Same instant must propose the same 5 stations both times — this
        // is a periodization decision, not something that should reshuffle
        // on every read of the same day.
        XCTAssertEqual(firstCall.map(\.name), secondCall.map(\.name))
        XCTAssertEqual(firstCall.count, 5)
        XCTAssertEqual(Set(firstCall.map(\.name)).count, 5, "Should never repeat a station within one session.")

        // Across a full year of weekly rotation, every one of the 8 real
        // stations must appear at least once — the design point being that
        // rotating a subset doesn't mean quietly dropping a station forever.
        var seen = Set<String>()
        for week in 0..<52 {
            let weekly = WorkoutPlanner.hyroxRotation(now: now.addingTimeInterval(Double(week) * 7 * 86_400))
            seen.formUnion(weekly.map(\.name))
        }
        XCTAssertEqual(seen.count, WorkoutPlanner.hyroxStations.count)
    }

    private func performanceSummary(acuteLoad: Double, habitualLoad: Double, observedLoadDays: Int = 20) -> PerformanceSummary {
        PerformanceSummary(
            sessions: 5, minutes: 300, calories: 2_000, strengthSets: 20, strengthVolume: 4_000,
            previousSessions: 5, daily: [], acuteLoad: acuteLoad, habitualLoad: habitualLoad,
            lowAerobic: 70, highAerobic: 25, anaerobic: 5,
            observedLoadDays: observedLoadDays, sustainedLoadWeeks: 0
        )
    }

    func testTrainingScenarioSimulateReturnsEmptyWithoutRealLoadHistory() {
        XCTAssertTrue(TrainingScenarioEngine.simulate(health: HealthStore(), imports: ImportStore(), currentPace: .optimal).isEmpty,
                     "No real load history at all — must not fabricate three futures out of nothing.")
    }

    // The concrete link between "Tres futuros" and the real plan: the
    // scenario matching the athlete's actual ProgressionPace must be
    // flagged, and only that one — this is the trajectory
    // TrainingPlanEngine.progressedCeiling is actually ramping the real
    // week's ceilings along, not just one of three equal hypotheticals.
    func testTrainingScenarioFlagsExactlyTheAthletesOwnCurrentPace() {
        let health = HealthStore()
        health.recentWorkouts = (0..<10).map { offset in
            healthWorkout(activity: "Carrera", kilometers: 8, minutes: 45, date: Date().addingTimeInterval(-Double(offset) * 86_400))
        }
        let scenarios = TrainingScenarioEngine.simulate(health: health, imports: ImportStore(), currentPace: .aggressive)
        guard !scenarios.isEmpty else { return }
        XCTAssertEqual(scenarios.filter(\.isCurrentPace).count, 1, "Exactly one scenario must be flagged as the athlete's real current pace.")
        XCTAssertEqual(scenarios.first { $0.isCurrentPace }?.name, ProgressionPace.aggressive.rawValue)
    }

    func testTrainingScenarioAggressiveRampsFasterThanConservative() {
        let baseline = performanceSummary(acuteLoad: 300, habitualLoad: 300)
        let now = Date()
        let conservative = TrainingScenarioEngine.scenario(name: "Conservador", growth: ProgressionPace.conservative.weeklyGrowthRate, baseline: baseline, weeks: 8, now: now)
        let aggressive = TrainingScenarioEngine.scenario(name: "Agresivo", growth: ProgressionPace.aggressive.weeklyGrowthRate, baseline: baseline, weeks: 8, now: now)
        XCTAssertGreaterThan(aggressive.peakLoadRatio, conservative.peakLoadRatio)
        XCTAssertGreaterThan(aggressive.habitualLoadChangePercent, conservative.habitualLoadChangePercent)
        XCTAssertEqual(conservative.weeks.count, 8)
    }

    func testTrainingScenarioOverloadDetectionActuallyFires() {
        // Not a claim that real training reaches this — 50%/week is a
        // synthetic extreme used only to prove the guidance path actually
        // fires when a trajectory does cross into overload, since the
        // named "Agresivo" policy itself (see test below) is deliberately
        // bounded by periodized deloads and, correctly, never gets there
        // within a normal block.
        let baseline = performanceSummary(acuteLoad: 300, habitualLoad: 300)
        let extreme = TrainingScenarioEngine.scenario(name: "Extremo (solo test)", growth: 0.5, baseline: baseline, weeks: 8, now: Date())
        XCTAssertGreaterThan(extreme.weeksAtRisk, 0)
        XCTAssertTrue(extreme.weeks.contains { $0.guidance == .overload })
    }

    func testTrainingScenarioAggressivePolicyStaysBoundedByItsOwnPeriodizedDeloads() {
        // A real, useful finding this simulator surfaces: even the
        // bounded "Agresivo" ceiling (15%/week, at the edge of what this
        // app treats as defensible elsewhere), combined with the same
        // every-4th-week deload convention used across the app, doesn't
        // itself cross into overload within a normal 8-week block — the
        // periodization is doing its job. This is what makes "agresivo
        // ≠ imprudente" a real property of the model, not just a claim
        // in a comment.
        let baseline = performanceSummary(acuteLoad: 300, habitualLoad: 300)
        let aggressive = TrainingScenarioEngine.scenario(name: "Agresivo", growth: ProgressionPace.aggressive.weeklyGrowthRate, baseline: baseline, weeks: 8, now: Date())
        XCTAssertFalse(aggressive.weeks.contains { $0.guidance == .overload })
    }

    func testTrainingScenarioNeverCompoundsGrowthPastItsOwnOverloadPoint() {
        // Even the aggressive policy must hold its weekly load flat once
        // its own ratio has already crossed into overload, rather than
        // compounding 15%/week indefinitely regardless of what that
        // ratio says — the whole point of comparing scenarios is showing
        // WHEN each one hits the wall, not modeling past it.
        let baseline = performanceSummary(acuteLoad: 500, habitualLoad: 300)
        let aggressive = TrainingScenarioEngine.scenario(name: "Agresivo", growth: ProgressionPace.aggressive.weeklyGrowthRate, baseline: baseline, weeks: 8, now: Date())
        let loads = aggressive.weeks.map(\.weeklyLoad)
        // Once in overload, non-deload weeks must not exceed the prior week's load.
        for index in 1..<loads.count where !aggressive.weeks[index].isDeloadWeek && aggressive.weeks[index - 1].guidance == .overload {
            XCTAssertLessThanOrEqual(loads[index], loads[index - 1] + 0.001)
        }
    }

    func testTrainingScenarioEveryFourthWeekDeloads() {
        let baseline = performanceSummary(acuteLoad: 300, habitualLoad: 300)
        let scenario = TrainingScenarioEngine.scenario(name: "Óptimo", growth: ProgressionPace.optimal.weeklyGrowthRate, baseline: baseline, weeks: 8, now: Date())
        XCTAssertTrue(scenario.weeks[4].isDeloadWeek, "The 5th week (index 4) must be the deload week.")
        XCTAssertLessThan(scenario.weeks[4].weeklyLoad, scenario.weeks[3].weeklyLoad)
    }

    func testPaceChangeBandIsWideCappedAndNeverPositive() {
        let none = TrainingScenarioEngine.paceChangeBand(habitualLoadChangePercent: 0)
        XCTAssertEqual(none, 0...0)
        let extreme = TrainingScenarioEngine.paceChangeBand(habitualLoadChangePercent: 1_000)
        XCTAssertEqual(extreme.lowerBound, -6, accuracy: 0.001)
        XCTAssertEqual(extreme.upperBound, -6, accuracy: 0.001)
        let modest = TrainingScenarioEngine.paceChangeBand(habitualLoadChangePercent: 20)
        XCTAssertLessThan(modest.lowerBound, 0, "A real load increase must never project a slower (positive) pace change.")
        XCTAssertLessThanOrEqual(modest.lowerBound, modest.upperBound)
    }

    func testGoalDistanceUsesCorrectDirectionForTimeAndStrength() {
        XCTAssertEqual(GoalDistanceEngine.runningGap(forecastSeconds: 1_260, targetSeconds: 1_200), 60)
        XCTAssertEqual(GoalDistanceEngine.strengthGap(currentKilograms: 92.5, targetKilograms: 100), 7.5)
    }

    func testTenKIsACompleteRunningGoalKind() throws {
        XCTAssertEqual(TrainingGoalKind.tenK.defaultUnit, "min")
        XCTAssertTrue(TrainingGoalKind.tenK.usesDate)
        let encoded = try JSONEncoder().encode(TrainingGoalKind.tenK)
        XCTAssertEqual(try JSONDecoder().decode(TrainingGoalKind.self, from: encoded), .tenK)
    }

    func testEWMAWeightsRecentTrainingMoreThanOldTraining() {
        let old = [100.0] + Array(repeating: 0.0, count: 27)
        let recent = Array(repeating: 0.0, count: 27) + [100.0]

        XCTAssertGreaterThan(
            PerformanceEngine.ewmaWeeklyEquivalent(loads: recent, timeConstant: 7),
            PerformanceEngine.ewmaWeeklyEquivalent(loads: old, timeConstant: 7)
        )
    }

    func testStableLoadProducesAcuteChronicRatioNearOne() {
        let loads = Array(repeating: 30.0, count: 84)
        let acute = PerformanceEngine.ewmaWeeklyEquivalent(loads: loads, timeConstant: 7)
        let chronic = PerformanceEngine.ewmaWeeklyEquivalent(loads: loads, timeConstant: 28)

        XCTAssertEqual(acute / chronic, 1, accuracy: 0.001)
        XCTAssertEqual(PerformanceEngine.loadGuidance(ratio: acute / chronic, sustainedWeeks: 2, observedDays: 30), .productive)
    }

    func testLoadGuidanceSeparatesAccumulatedDeloadFromAcuteOverload() {
        XCTAssertEqual(PerformanceEngine.loadGuidance(ratio: 1.12, sustainedWeeks: 3, observedDays: 24), .deload)
        XCTAssertEqual(PerformanceEngine.loadGuidance(ratio: 1.60, sustainedWeeks: 1, observedDays: 12), .overload)
    }

    func testDeloadRewritesWeeklyTargetsAndRemovesQuality() {
        let normal = TrainingPlanEngine.deloadAdjustment(
            runningSessions: 4, strengthSessions: 3, qualitySessions: 1, enabled: false
        )
        let deload = TrainingPlanEngine.deloadAdjustment(
            runningSessions: 4, strengthSessions: 3, qualitySessions: 1, enabled: true
        )

        XCTAssertEqual(normal, DeloadAdjustment(runningSessions: 4, strengthSessions: 3, qualitySessions: 1, volumeFactor: 1))
        XCTAssertEqual(deload.runningSessions, 3)
        XCTAssertEqual(deload.strengthSessions, 2)
        XCTAssertEqual(deload.qualitySessions, 0)
        XCTAssertEqual(deload.volumeFactor, 0.70, accuracy: 0.001)
    }

    func testTwinCalibrationRequiresEnoughObservations() {
        let calibration = TwinCalibration.derive(errors: [8, 7])

        XCTAssertEqual(calibration.observations, 2)
        XCTAssertEqual(calibration.scoreAdjustment, 0)
        XCTAssertEqual(calibration.confidence, 0)
    }

    func testTwinCalibrationLearnsBiasGraduallyAndIsBounded() {
        let early = TwinCalibration.derive(errors: Array(repeating: 12, count: 3))
        let learned = TwinCalibration.derive(errors: Array(repeating: 40, count: 20))

        XCTAssertEqual(early.scoreAdjustment, 1)
        XCTAssertEqual(early.confidence, 8)
        XCTAssertEqual(learned.scoreAdjustment, 8)
        XCTAssertEqual(learned.confidence, 100)
        XCTAssertEqual(learned.signedBias, 20, accuracy: 0.001)
    }

    func testSecondaryEarlierGoalDoesNotDisplacePrimaryPlan() {
        let calendar = Calendar(identifier: .gregorian)
        let secondaryDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let primaryDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        let profile = AthletePlanProfile(goals: [
            TrainingGoal(id: UUID(), kind: .custom, title: "Reto secundario", date: secondaryDate,
                         targetValue: nil, unit: "", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: primaryDate,
                         targetValue: nil, unit: "min", priority: .primary, isActive: true)
        ], gymAvailable: false, trainingDaysPerWeek: 5, preferredLongRunWeekday: 7, maximumHeartRate: nil)

        let blocks = TrainingPlanEngine.blocks(for: profile)

        XCTAssertTrue(blocks.first?.name.contains("Media maratón") == true)
        XCTAssertFalse(blocks.contains { $0.name == "Reto secundario" })
    }

    func testUnreviewedRunsProduceOnlyLowConfidenceForecast() {
        let run = healthRun(kilometers: 10, minutes: 50)

        let summary = RunningPerformanceEngine.summarize(workouts: [run], zones: [], reviews: [], now: run.date)

        XCTAssertEqual(summary.fiveK?.confidence, .low)
        // Wording changed (now names what it's actually based on — the
        // fastest recent comparable run — instead of just saying
        // "provisional"), but it must still read as clearly unverified.
        XCTAssertTrue(summary.fiveK?.basis.contains("sin test valorado") == true)
    }

    func testQualifiedRunDrivesForecastInsteadOfEasyRun() {
        let easy = healthRun(kilometers: 10, minutes: 70, date: Date(timeIntervalSince1970: 1_000))
        let test = healthRun(kilometers: 10, minutes: 45, date: Date(timeIntervalSince1970: 2_000))
        let reviews = [
            review(for: easy, effort: 4, purpose: .easy),
            review(for: test, effort: 9, purpose: .test)
        ]

        let summary = RunningPerformanceEngine.summarize(workouts: [easy, test], zones: [], reviews: reviews, now: test.date)

        XCTAssertTrue(summary.fiveK?.basis.contains("1 tests") == true)
        XCTAssertLessThan(summary.fiveK?.seconds ?? .greatestFiniteMagnitude, 1_500)
    }

    func testHealthKitStrengthMirrorIsDetectedButRunIsNot() {
        let store = ImportStore()
        let start = Date(timeIntervalSince1970: 10_000)
        let imported = ImportedWorkout(title: "Push", start: start, end: start.addingTimeInterval(3_600),
                                       exercises: [], muscleSets: ["Pecho": 4])
        store.restore(workouts: [imported], labs: [])

        let strength = HealthWorkout(id: UUID(), date: start.addingTimeInterval(30), durationMinutes: 60,
                                     calories: 400, distanceKilometers: nil, averageHeartRate: 120,
                                     elevationMeters: nil, activity: "Fuerza", muscleGroups: [:], source: "Éter")
        let run = HealthWorkout(id: UUID(), date: start.addingTimeInterval(30), durationMinutes: 60,
                                calories: 600, distanceKilometers: 10, averageHeartRate: 150,
                                elevationMeters: nil, activity: "Carrera", muscleGroups: [:], source: "Apple Watch")

        XCTAssertTrue(store.isHealthKitMirror(strength))
        XCTAssertFalse(store.isHealthKitMirror(run))
    }

    func testOverdueStrengthCanBeatLateWeekLongRun() {
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 2, targetRuns: 4,
            strength: 0, targetStrength: 1,
            quality: 1, targetQuality: 1,
            daysSinceStrength: 10,
            hoursSinceLong: 168, hoursSinceQuality: 96,
            lateWeek: true, readiness: 70, muscles: muscles(legs: 68),
            goalFocus: GoalTrainingFocus(running: 0.75, strength: 0.20, hybrid: 0.05, leadingGoal: "Media maratón")
        )

        XCTAssertEqual(decision.kind, .strength)
        XCTAssertTrue(decision.rationale.contains("10 días"))
    }

    func testLongRunWinsWhenStrengthMaintenanceIsCurrent() {
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 2, targetRuns: 4,
            strength: 1, targetStrength: 1,
            quality: 1, targetQuality: 1,
            daysSinceStrength: 2,
            hoursSinceLong: 168, hoursSinceQuality: 96,
            lateWeek: true, readiness: 72, muscles: muscles(legs: 76),
            goalFocus: GoalTrainingFocus(running: 0.75, strength: 0.20, hybrid: 0.05, leadingGoal: "Media maratón")
        )

        XCTAssertEqual(decision.kind, .longRun)
    }

    func testGoalPortfolioChangesTrainingFocus() {
        let strengthProfile = AthletePlanProfile(goals: [
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil,
                         targetValue: 100, unit: "kg", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .fiveK, title: "5K", date: nil,
                         targetValue: 20, unit: "min", priority: .maintenance, isActive: true)
        ], gymAvailable: true, trainingDaysPerWeek: 5, preferredLongRunWeekday: 7, maximumHeartRate: nil)

        let focus = TrainingPlanEngine.goalFocus(for: strengthProfile, on: Date())

        XCTAssertGreaterThan(focus.strength, focus.running)
        XCTAssertEqual(focus.leadingGoal, "Banca")
    }

    func testApproachingEventIncreasesItsSpecificWeight() {
        let now = Date()
        let profile = AthletePlanProfile(goals: [
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media", date: Calendar.current.date(byAdding: .day, value: 10, to: now),
                         targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil,
                         targetValue: 100, unit: "kg", priority: .primary, isActive: true)
        ], gymAvailable: true, trainingDaysPerWeek: 5, preferredLongRunWeekday: 7, maximumHeartRate: nil)

        let focus = TrainingPlanEngine.goalFocus(for: profile, on: now)

        XCTAssertGreaterThan(focus.running, focus.strength)
        XCTAssertEqual(focus.leadingGoal, "Media")
    }

    func testBenchPressGoalProgressIgnoresInclineAndDumbbellVariations() {
        // A real flat-barbell bench PR from 27 days ago (still inside the
        // 28-day recency window) vs. an incline dumbbell variation trained
        // far more recently and frequently — bare "bench press" substring
        // matching used to let matchingExercise's recency-sorted search
        // pick the incline variation instead, silently replacing a real
        // ~105% (90kg × 5 reps) progress estimate with the incline one's
        // much lower estimate, just because it had more recent sets.
        let now = Date()
        let barbellSession = ImportedWorkout(
            title: "Push", start: now.addingTimeInterval(-27 * 86_400), end: now.addingTimeInterval(-27 * 86_400 + 3_600),
            exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 3, volume: 270, totalReps: 15, averageWeight: 90,
                                         setDetails: (0..<3).map { _ in ImportedSet(weight: 90, reps: 5, type: "normal", rpe: nil) })],
            muscleSets: ["Pecho": 3, "Tríceps": 1.5]
        )
        let inclineSessions = [3, 20].map { daysAgo -> ImportedWorkout in
            let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            return ImportedWorkout(
                title: "Push", start: date, end: date.addingTimeInterval(3_600),
                exercises: [ImportedExercise(name: "Incline Bench Press (Dumbbell)", sets: 3, volume: 90, totalReps: 45, averageWeight: 30,
                                             setDetails: (0..<3).map { _ in ImportedSet(weight: 30, reps: 15, type: "normal", rpe: nil) })],
                muscleSets: ["Pecho": 3, "Hombros": 1.5]
            )
        }

        let strength = StrengthProgressEngine.summarize([barbellSession] + inclineSessions, now: now)
        let goal = TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil, targetValue: 100, unit: "kg", priority: .primary, isActive: true)
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 0, priorKilometers7Days: 0,
            fiveK: nil, tenK: nil, halfMarathon: nil, marathon: nil,
            easyPercentage: 0, hardPercentage: 0, hasZoneData: false
        )
        let distances = GoalDistanceEngine.evaluate(goals: [goal], running: running, strength: strength, now: now)

        guard let distance = distances.first else { XCTFail("Expected a distance result."); return }
        // 90kg × 5 reps ≈ 105kg estimated 1RM against a 100kg target — must
        // win over the incline variation's own (much lower) estimate.
        XCTAssertEqual(distance.progress ?? 0, 1.0, accuracy: 0.01,
                       "Bench press goal progress must be derived from the real flat-barbell 1RM, not an incline dumbbell variation.")
    }

    func testDeadliftGoalTracksTheRealBarbellLift() {
        // "Peso muerto" used to have nowhere to live except .custom
        // ("Otro reto"), which GoalDistanceEngine can't model at all
        // (unmodelledDistance, no real forecast). It's now a first-class
        // tracked lift, matched the same precise way bench press and
        // squat already are.
        let now = Date()
        let session = ImportedWorkout(
            title: "Pull", start: now.addingTimeInterval(-2 * 86_400), end: now.addingTimeInterval(-2 * 86_400 + 3_600),
            exercises: [ImportedExercise(name: "Deadlift (Barbell)", sets: 3, volume: 360, totalReps: 15, averageWeight: 120,
                                         setDetails: (0..<3).map { _ in ImportedSet(weight: 120, reps: 5, type: "normal", rpe: nil) })],
            muscleSets: ["Isquios": 3, "Glúteos": 2.25, "Espalda": 1.5]
        )
        let strength = StrengthProgressEngine.summarize([session], now: now)
        let goal = TrainingGoal(id: UUID(), kind: .deadlift, title: "Peso muerto", date: nil, targetValue: 120, unit: "kg", priority: .primary, isActive: true)
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 0, priorKilometers7Days: 0,
            fiveK: nil, tenK: nil, halfMarathon: nil, marathon: nil,
            easyPercentage: 0, hardPercentage: 0, hasZoneData: false
        )
        let distances = GoalDistanceEngine.evaluate(goals: [goal], running: running, strength: strength, now: now)

        guard let distance = distances.first else { XCTFail("Expected a distance result."); return }
        // 120kg × 5 reps ≈ 140kg estimated 1RM against a 120kg target —
        // already met (progress is clamped at 1.0, state reflects the rest).
        XCTAssertNotEqual(distance.state, .insufficientData, "Deadlift must resolve to a real strength-progress estimate, not 'unmodelled'.")
        XCTAssertEqual(distance.state, .achieved)
        XCTAssertEqual(distance.progress ?? 0, 1.0, accuracy: 0.01)
    }

    func testGoalContextIsLiftSpecificityOnlyForTheExactTrackedLift() {
        // "100 kg de press banca" earns Bench Press (Barbell) itself a
        // low-rep, near-failure template — but must NOT leak onto every
        // exercise that happens to share the same muscle group. An incline
        // dumbbell variant on the same push day still serves hypertrophy.
        let goals = [TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil,
                                  targetValue: 100, unit: "kg", priority: .primary, isActive: true)]
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Bench Press (Barbell)", goals: goals), .liftSpecificity)
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Incline Bench Press (Dumbbell)", goals: goals), .hypertrophy)
        // An inactive goal must not trigger specificity either.
        let inactive = [TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil,
                                     targetValue: 100, unit: "kg", priority: .primary, isActive: false)]
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Bench Press (Barbell)", goals: inactive), .hypertrophy)
    }

    func testGoalContextIsEnduranceSupportOnlyWithoutACompetingStrengthGoal() {
        // A runner with no strength/hypertrophy goal is lifting purely to
        // stay durable — minimum effective dose, clear of failure.
        let enduranceOnly = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil,
                                          targetValue: nil, unit: "min", priority: .primary, isActive: true)]
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Squat (Barbell)", goals: enduranceOnly), .enduranceSupport)

        // The same runner also chasing an explicit hypertrophy goal is
        // training for muscle growth too — the competing goal must win,
        // not be silently overridden by "durability."
        let enduranceAndHypertrophy = enduranceOnly + [
            TrainingGoal(id: UUID(), kind: .hypertrophy, title: "Hipertrofia", date: nil, targetValue: nil, unit: "", priority: .secondary, isActive: true)
        ]
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Squat (Barbell)", goals: enduranceAndHypertrophy), .hypertrophy)

        // No goals at all — the old, always-hypertrophy default — must
        // still be the fallback.
        XCTAssertEqual(StrengthPrescriptionEngine.goalContext(for: "Squat (Barbell)", goals: []), .hypertrophy)
    }

    func testPrescribeAppliesLiftSpecificityRepRangeForTheTrackedLift() {
        // History logged at a hypertrophy-style rep count (8) — a tracked
        // 1RM goal must still pull this down into a real strength rep range
        // (3-5) and recompute the load upward to match, not just repeat
        // whatever reps happened to be logged last time.
        let now = Date()
        let workouts = [0, 7, 14].map { daysAgo -> ImportedWorkout in
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            let sets = (0..<3).map { _ in ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 7) }
            return ImportedWorkout(title: "Push", start: date, end: date.addingTimeInterval(3_600),
                                   exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 3, volume: 14_800,
                                                                totalReps: 24, averageWeight: 80, setDetails: sets)],
                                   muscleSets: ["Pecho": 2])
        }
        let goals = [TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil,
                                  targetValue: 100, unit: "kg", priority: .primary, isActive: true)]
        let source = RoutineExercise(name: "Bench Press (Barbell)", sets: [], restSeconds: 120)
        let result = try! XCTUnwrap(StrengthPrescriptionEngine.prescribe(
            source, workouts: workouts, readiness: 75,
            muscleReadiness: muscles(legs: 80), goals: goals, now: now
        ))

        XCTAssertTrue((3...5).contains(result.sets.first?.reps ?? 0), "A tracked-lift goal must clamp the prescribed reps into a real strength range (3-5), got \(result.sets.first?.reps ?? -1).")
        // 80kg × 8 reps ≈ e1RM 101.3 — at 5 reps that's ≈ 84.4 kg, clearly
        // heavier than the 80kg the history was logged at, since fewer reps
        // at the same estimated 1RM demands more weight.
        XCTAssertGreaterThan(result.sets.first?.weight ?? 0, 80, "Dropping to a specificity rep range without raising the load isn't specificity — it's just an easier version of the same set.")
        XCTAssertTrue(result.prescriptionNote?.contains("especificidad de fuerza") ?? false)
    }

    func testPrescribeAppliesEnduranceSupportRepRangeAndSkipsProgression() {
        // Same stable, high-readiness, low-RPE history that would normally
        // trigger the hypertrophy progression rule (+1 rep) — but with only
        // an endurance goal active, this must land in a high-rep,
        // clear-of-failure band instead, and skip progression entirely.
        let now = Date()
        let workouts = [0, 7, 14, 21, 28].map { daysAgo -> ImportedWorkout in
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            let sets = (0..<3).map { _ in ImportedSet(weight: 60, reps: 8, type: "normal", rpe: 6) }
            return ImportedWorkout(title: "Pierna", start: date, end: date.addingTimeInterval(3_600),
                                   exercises: [ImportedExercise(name: "Squat (Barbell)", sets: 3, volume: 10_800,
                                                                totalReps: 24, averageWeight: 60, setDetails: sets)],
                                   muscleSets: ["Cuádriceps": 3])
        }
        let goals = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil,
                                  targetValue: nil, unit: "min", priority: .primary, isActive: true)]
        let source = RoutineExercise(name: "Squat (Barbell)", sets: [], restSeconds: 120)
        let result = try! XCTUnwrap(StrengthPrescriptionEngine.prescribe(
            source, workouts: workouts, readiness: 80,
            muscleReadiness: muscles(legs: 80), goals: goals, now: now
        ))

        XCTAssertTrue((10...12).contains(result.sets.first?.reps ?? 0), "Endurance-support must land in the minimum-effective-dose rep band (10-12), got \(result.sets.first?.reps ?? -1).")
        XCTAssertTrue(result.prescriptionNote?.contains("apoyo de resistencia") ?? false)
        XCTAssertFalse(result.prescriptionNote?.contains("progresión") ?? true, "Endurance-support must not chase progressive overload at the expense of the athlete's actual sport.")
    }

    func testGymProposesPatternDiverseExercisesInsteadOfAllPressVariants() {
        // Six push-day exercises where three (Bench Press ×2, Push Up)
        // all share the exact same "Empuje horizontal" movement pattern —
        // muscle-group freshness alone would happily fill the whole
        // 5-exercise session with variations of the same press. Pattern
        // diversity must keep that from happening.
        let originalProfile = GoalStore.shared.profile
        defer { GoalStore.shared.save(originalProfile) }
        var profile = originalProfile
        profile.goals = []
        GoalStore.shared.save(profile)

        let imports = ImportStore()
        let now = Date()
        let names = ["Bench Press (Barbell)", "Bench Press (Dumbbell)", "Push Up",
                     "Standing Military Press (Barbell)", "Lateral Raise (Dumbbell)", "Triceps Extension (Cable)"]
        let session = ImportedWorkout(
            title: "Push", start: now.addingTimeInterval(-2 * 86_400), end: now.addingTimeInterval(-2 * 86_400 + 3_600),
            exercises: names.map { name in
                ImportedExercise(name: name, sets: 3, volume: 900, totalReps: 24, averageWeight: 40, setDetails: nil)
            },
            muscleSets: ["Pecho": 6, "Hombros": 4, "Tríceps": 4]
        )
        imports.restore(workouts: [session], labs: [])
        defer { imports.deleteWorkout(id: session.id) }

        let proposed = WorkoutPlanner.gym(for: "Empuje", imports: imports, light: false, muscles: muscles(legs: 80))
        let patterns = proposed.exercises.map { ExerciseCatalog.descriptor(for: $0.name).pattern }

        XCTAssertEqual(proposed.exercises.count, 5)
        XCTAssertGreaterThanOrEqual(Set(patterns).count, 4, "A push session built from 4 distinct patterns must not collapse into 1-2 repeated patterns: got \(patterns).")
        XCTAssertLessThanOrEqual(patterns.filter { $0 == "Empuje horizontal" }.count, 2, "Diversity must cap same-pattern repeats instead of filling the session with press variants: got \(patterns).")
    }

    func testStrengthPrescriptionDropsWarmupsAndUsesSeveralSessions() {
        let now = Date()
        let workouts = [0, 7, 14].map { daysAgo in
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            let sets = [
                ImportedSet(weight: 20, reps: 10, type: "warmup", rpe: nil),
                ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 8),
                ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 8)
            ]
            return ImportedWorkout(title: "Push", start: date, end: date.addingTimeInterval(3_600),
                                   exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 3, volume: 14_800,
                                                                totalReps: 26, averageWeight: nil, setDetails: sets)],
                                   muscleSets: ["Pecho": 2])
        }
        let source = RoutineExercise(name: "Bench Press (Barbell)", sets: [], restSeconds: 120)
        let result = try! XCTUnwrap(StrengthPrescriptionEngine.prescribe(
            source, workouts: workouts, readiness: 75,
            muscleReadiness: muscles(legs: 80), now: now
        ))

        XCTAssertEqual(result.historySessions, 3)
        XCTAssertEqual(result.sets.count, 2)
        XCTAssertTrue(result.sets.allSatisfy { $0.weight >= 80 && $0.type == "normal" })
        XCTAssertEqual(result.sets.first?.reps, 9)
    }

    func testWorkingSetsInfersAnAscendingWarmupRampWhenNothingIsTagged() {
        // "Las 3 primeras series subiendo el volumen para calentar, luego 3
        // o 4 series válidas" — no explicit set_type at all (every set
        // defaults to "normal", true for every éter-logged session and any
        // untagged Hevy one), so the only signal available is the ramp
        // itself: ascending weight that plateaus at the final, heaviest sets.
        let sets = [
            ImportedSet(weight: 40, reps: 10, type: "normal", rpe: nil),
            ImportedSet(weight: 60, reps: 8, type: "normal", rpe: nil),
            ImportedSet(weight: 80, reps: 5, type: "normal", rpe: nil),
            ImportedSet(weight: 100, reps: 6, type: "normal", rpe: 8),
            ImportedSet(weight: 100, reps: 6, type: "normal", rpe: 8),
            ImportedSet(weight: 100, reps: 5, type: "normal", rpe: 9)
        ]
        let working = StrengthProgressEngine.workingSets(sets)
        XCTAssertEqual(working.count, 3, "The three ascending ramp sets (well below the final working weight) must be inferred as warm-up, leaving only the plateaued working sets.")
        XCTAssertTrue(working.allSatisfy { $0.weight == 100 })
    }

    func testWorkingSetsDoesNotInventARampWhenWeightIsFlat() {
        // Same weight every set (no ramp at all, e.g. an isolation exercise
        // or someone who doesn't warm up in ascending steps) — nothing to
        // infer, so every set must still count.
        let sets = (0..<4).map { _ in ImportedSet(weight: 60, reps: 10, type: "normal", rpe: nil) }
        XCTAssertEqual(StrengthProgressEngine.workingSets(sets).count, 4)
    }

    func testWorkingSetsLeavesBodyweightMovementsAlone() {
        // No weight signal to ramp on at all (pull-ups, push-ups) — must
        // never be misclassified as a warm-up ramp.
        let sets = (0..<4).map { _ in ImportedSet(weight: 0, reps: 12, type: "normal", rpe: nil) }
        XCTAssertEqual(StrengthProgressEngine.workingSets(sets).count, 4)
    }

    func testWorkingSetsStillRespectsExplicitTaggingOverInference() {
        // Explicit tagging (the athlete or Hevy itself marked it) is the
        // source of truth and must never be second-guessed by the ramp
        // heuristic — including when the tagged warm-up set doesn't even
        // look like part of an ascending ramp.
        let sets = [
            ImportedSet(weight: 100, reps: 5, type: "warmup", rpe: nil),
            ImportedSet(weight: 100, reps: 5, type: "normal", rpe: 8),
            ImportedSet(weight: 100, reps: 5, type: "normal", rpe: 8)
        ]
        let working = StrengthProgressEngine.workingSets(sets)
        XCTAssertEqual(working.count, 2)
        XCTAssertTrue(working.allSatisfy { $0.type == "normal" })
    }

    func testWarmupIndicesInfersLeadingAscendingRampWhenUntagged() {
        // Same ramp `workingSets` already recognizes, but reported as the
        // indices that are warm-up — what the new workout detail screen
        // needs to mark "Serie 1 (calentamiento)" against the original,
        // unfiltered set list instead of a separately-filtered array.
        let sets = [
            ImportedSet(weight: 40, reps: 10, type: "normal", rpe: nil),
            ImportedSet(weight: 60, reps: 8, type: "normal", rpe: nil),
            ImportedSet(weight: 100, reps: 6, type: "normal", rpe: 8),
            ImportedSet(weight: 100, reps: 5, type: "normal", rpe: 9)
        ]
        XCTAssertEqual(StrengthProgressEngine.warmupIndices(sets), [0, 1])
    }

    func testWarmupIndicesMatchesExplicitTagsAtAnyPosition() {
        // Explicit tagging can mark a warm-up set anywhere, not just a
        // leading prefix (e.g. a technique set redone mid-session) — the
        // per-index result must follow the actual tags, not assume they
        // only ever appear at the front.
        let sets = [
            ImportedSet(weight: 40, reps: 10, type: "warmup", rpe: nil),
            ImportedSet(weight: 80, reps: 8, type: "normal", rpe: nil),
            ImportedSet(weight: 40, reps: 10, type: "warmup", rpe: nil),
            ImportedSet(weight: 80, reps: 8, type: "normal", rpe: nil)
        ]
        XCTAssertEqual(StrengthProgressEngine.warmupIndices(sets), [0, 2])
    }

    func testMuscleMapInvolvementGivesHalfCreditToSecondaryMovers() {
        // A row is a back exercise that also loads the biceps as a
        // synergist — real, but not the same as a dedicated curl set.
        // Giving every synergist full credit is what let two ordinary
        // sessions read as "219% brazos".
        let involvement = MuscleMap.involvement(for: "Seated Cable Row - Bar Grip")
        XCTAssertEqual(involvement["Espalda"], 1.0)
        XCTAssertEqual(involvement["Bíceps"], 0.5)
    }

    func testMuscleMapInvolvementGivesNoTricepsCreditToLateralRaise() {
        // Pure shoulder isolation — the elbow barely moves, unlike an
        // actual pressing movement, so triceps shouldn't get any credit.
        let involvement = MuscleMap.involvement(for: "Lateral Raise (Dumbbell)")
        XCTAssertEqual(involvement["Hombros"], 1.0)
        XCTAssertNil(involvement["Tríceps"])
    }

    func testMuscleMapInvolvementStillGivesTricepsCreditToARealPressingMovement() {
        let involvement = MuscleMap.involvement(for: "Military Press (Barbell)")
        XCTAssertEqual(involvement["Hombros"], 1.0)
        XCTAssertEqual(involvement["Tríceps"], 0.5)
    }

    func testEffortWeightScalesWithProximityToFailureAndStaysNeutralWithoutRPE() {
        let farFromFailure = ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 5)
        let nearFailure = ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 9)
        let noRPE = ImportedSet(weight: 80, reps: 8, type: "normal", rpe: nil)
        XCTAssertLessThan(StrengthProgressEngine.effortWeight(farFromFailure), StrengthProgressEngine.effortWeight(nearFailure))
        XCTAssertEqual(StrengthProgressEngine.effortWeight(noRPE), 1.0,
                       "No RPE logged must stay neutral (1.0), not assume an effort level nobody recorded.")
    }

    func testEffectiveMuscleSetsAppliesEffortWeighting() {
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let lowEffort = ImportedWorkout(
            title: "LowEffortTest", start: start, end: start.addingTimeInterval(3_600),
            exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 3, volume: 1_920, totalReps: 24, averageWeight: 80,
                                         setDetails: (0..<3).map { _ in ImportedSet(weight: 80, reps: 8, type: "normal", rpe: 5) })],
            muscleSets: [:]
        )
        // 3 sets at RPE 5 (0.55 each) rather than full credit (3.0).
        XCTAssertEqual(lowEffort.effectiveMuscleSets["Pecho"] ?? 0, 3 * 0.55, accuracy: 0.01)
    }

    func testAddStrengthWorkoutAppliesTheSameSecondaryMoverDiscountToMuscleSets() {
        let store = ImportStore()
        let title = "InvolvementTest-\(UUID().uuidString)"
        let exercises = [
            ImportedExercise(name: "Seated Cable Row - Bar Grip", sets: 6, volume: 600, totalReps: 60, averageWeight: 10, setDetails: nil),
            ImportedExercise(name: "Preacher Curl (Barbell)", sets: 5, volume: 250, totalReps: 50, averageWeight: 5, setDetails: nil)
        ]
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        store.addStrengthWorkout(title: title, start: start, end: start.addingTimeInterval(3_600), exercises: exercises)
        defer { store.deleteWorkout(id: "\(title)|\(start.timeIntervalSince1970)") }

        guard let workout = store.workouts.first(where: { $0.title == title }) else {
            XCTFail("Expected the workout to be saved.")
            return
        }
        // 6 row sets at half credit (3.0) + 5 direct curl sets at full
        // credit (5.0) — not 11 full-credit "bíceps sets".
        XCTAssertEqual(workout.muscleSets["Bíceps"] ?? 0, 8.0, accuracy: 0.01)
        XCTAssertEqual(workout.muscleSets["Espalda"] ?? 0, 6.0, accuracy: 0.01)
    }

    func testMuscleDistributionRecomputesFromExercisesInsteadOfTrustingStaleStoredMuscleSets() {
        // muscleSets is computed once and persisted at import/save time —
        // a session logged before a refinement to MuscleMap's weighting
        // (or to the warm-up filter) keeps its old numbers forever unless
        // something recomputes it. This reproduces exactly that: a stored
        // muscleSets as if saved before the secondary-mover discount
        // shipped (full, undiscounted credit), alongside the real
        // exercises/setDetails that should win instead.
        let store = ImportStore()
        let title = "StaleMuscleSetsTest-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let workout = ImportedWorkout(
            title: title, start: start, end: start.addingTimeInterval(3_600),
            exercises: [ImportedExercise(name: "Seated Cable Row - Bar Grip", sets: 6, volume: 600, totalReps: 60, averageWeight: 10,
                                         setDetails: (0..<6).map { _ in ImportedSet(weight: 10, reps: 10, type: "normal", rpe: nil) })],
            muscleSets: ["Espalda": 6, "Bíceps": 6]
        )
        store.restore(workouts: [workout], labs: [])
        defer { store.deleteWorkout(id: workout.id) }

        let distribution = store.muscleDistribution(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(7_200))
        XCTAssertEqual(distribution["Espalda"] ?? 0, 6.0, accuracy: 0.01)
        XCTAssertEqual(distribution["Brazos"] ?? 0, 3.0, accuracy: 0.01,
                       "Must recompute from exercises using the current MuscleMap weighting (0.5 for a row's biceps), not trust a persisted muscleSets that predates it (6.0).")
    }

    func testHevyImportCountsOnlyWorkingSetsTowardExerciseVolumeAndAverageWeight() {
        let store = ImportStore()
        // A unique title per run — ImportStore persists to disk, and a
        // fixed title could otherwise collide with a leftover from an
        // earlier failed attempt (before this test's own cleanup ran).
        let title = "WarmupImportTest-\(UUID().uuidString)"
        let csv = """
        title,start_time,end_time,exercise_title,weight_kg,reps,set_type,rpe
        \(title),"1 Jan 2024, 10:00","1 Jan 2024, 11:00",Bench Press (Barbell),40,10,,
        \(title),"1 Jan 2024, 10:00","1 Jan 2024, 11:00",Bench Press (Barbell),60,8,,
        \(title),"1 Jan 2024, 10:00","1 Jan 2024, 11:00",Bench Press (Barbell),100,6,,
        \(title),"1 Jan 2024, 10:00","1 Jan 2024, 11:00",Bench Press (Barbell),100,6,,
        """
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("hevy_warmup_\(UUID().uuidString).csv")
        try! csv.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        store.importFiles([tempURL])
        // importFiles parses off the main actor and publishes workouts
        // asynchronously — poll instead of guessing a fixed delay.
        let expectation = XCTestExpectation(description: "import settles")
        var attempts = 0
        func poll() {
            attempts += 1
            if store.workouts.contains(where: { $0.title == title }) || attempts > 40 {
                expectation.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
        wait(for: [expectation], timeout: 5)

        guard let workout = store.workouts.first(where: { $0.title == title }),
              let exercise = workout.exercises.first(where: { $0.name == "Bench Press (Barbell)" }) else {
            XCTFail("Expected the imported Bench Press workout to be present.")
            return
        }
        defer { store.deleteWorkout(id: workout.id) }
        XCTAssertEqual(exercise.sets, 2, "The two ascending warm-up rows must not count toward the exercise's working set total.")
        XCTAssertEqual(exercise.averageWeight ?? 0, 100, accuracy: 0.01,
                       "averageWeight must reflect only the working sets, not be dragged down by the warm-up ramp.")
    }

    func testStrengthPrescriptionDeloadsWhenTargetMuscleIsTired() {
        let now = Date()
        let exercise = ImportedExercise(name: "Squat (Barbell)", sets: 3, volume: 2_400, totalReps: 24, averageWeight: 100,
                                        setDetails: (0..<3).map { _ in ImportedSet(weight: 100, reps: 8, type: "normal", rpe: 9) })
        let workout = ImportedWorkout(title: "Pierna", start: now.addingTimeInterval(-86_400), end: now,
                                      exercises: [exercise], muscleSets: ["Cuádriceps": 3])
        let source = RoutineExercise(name: exercise.name, sets: [], restSeconds: 120)
        let tired = [MuscleReadiness(name: "Cuádriceps", readiness: 40, lastTrained: workout.start, recentSets: 3)]

        let result = try! XCTUnwrap(StrengthPrescriptionEngine.prescribe(
            source, workouts: [workout], readiness: 80,
            muscleReadiness: tired, now: now
        ))

        XCTAssertLessThan(result.sets.first?.weight ?? 100, 100)
        XCTAssertTrue(result.prescriptionNote?.contains("recuperación baja") == true)
    }

    func testLowerBodyRestrictionBlocksSquatButAllowsBenchPress() {
        let injury = InjuryRecord(id: UUID(), area: "Rodilla derecha", startedAt: Date(), resolvedAt: nil,
                                  severity: 3, restrictions: [.avoidLowerBody], note: "")

        XCTAssertFalse(InjurySafetyEngine.exerciseSafety("Squat (Barbell)", injuries: [injury]).allowed)
        XCTAssertTrue(InjurySafetyEngine.exerciseSafety("Bench Press (Barbell)", injuries: [injury]).allowed)
    }

    func testStrengthPrescriptionDoesNotCreateBlockedExercise() {
        let injury = InjuryRecord(id: UUID(), area: "Rodilla derecha", startedAt: Date(), resolvedAt: nil,
                                  severity: 3, restrictions: [.avoidLowerBody], note: "")
        let squat = RoutineExercise(name: "Squat (Barbell)", sets: [], restSeconds: 120)

        let result = StrengthPrescriptionEngine.prescribe(
            squat, workouts: [], readiness: 80,
            muscleReadiness: muscles(legs: 80), injuries: [injury]
        )

        XCTAssertNil(result)
    }

    func testRunningRestrictionReplacesRunWithCompatibleRecovery() {
        let injury = InjuryRecord(id: UUID(), area: "Aquiles", startedAt: Date(), resolvedAt: nil,
                                  severity: 2, restrictions: [.avoidRunning], note: "")
        let run = ProposedWorkout(title: "Tirada larga", duration: "75 min", intent: "Resistencia", exercises: [
            ProposedExercise(name: "Carrera continua", prescription: "60 min", cue: "Z2")
        ], note: "")

        let safe = InjurySafetyEngine.sanitize(run, injuries: [injury])

        XCTAssertEqual(safe.title, "Recuperación compatible")
        XCTAssertTrue(safe.note.contains("Carrera bloqueada"))
    }

    func testDecisionSimulatorOffersFourConcretePermutations() {
        XCTAssertEqual(SimulatedDecision.allCases.map(\.rawValue),
                       ["Descansar", "Intervalos", "Tirada larga", "Fuerza superior",
                        "2 cervezas esta noche", "Ayuno de 16 h", "Hidratación baja hoy", "Sauna 20 min"],
                       "Plan previsto' no era una permutación real de entrenamiento, sino 'lo que sea que ya esté programado' — se sustituye por Tirada larga. Lifestyle options added later use éter's own learned habit associations instead of a workout permutation.")
    }

    func testPhysiologicalAlertHardOverridesTheProposedSession() {
        // PR1.5: ImportStore(persistToDisk: false) starts genuinely empty
        // instead of loading this machine's real, disk-persisted Hevy
        // history — the previous plain ImportStore() here made this test's
        // outcome depend on whatever real history happened to be saved,
        // confirmed to fail identically on main before PR1 for exactly
        // that reason.
        let recoverAlert = PhysiologicalAlert(
            severity: .recover, title: "Prioriza recuperación",
            summary: "HRV y pulso en reposo se apartan a la vez de tu rango personal reciente.",
            action: "No añadas intensidad hoy.",
            signals: [], confidence: ConfidenceAssessment(score: 80, level: .medium, reason: "")
        )
        let health = HealthStore()
        let imports = ImportStore(persistToDisk: false)
        // Same call, same inputs, only the alert differs — proves the override
        // actually changes the outcome rather than the empty fixture already
        // landing on .recovery for unrelated reasons.
        let withoutAlert = TrainingPlanEngine.status(health: health, imports: imports, readiness: 85, muscles: [], checkIn: nil,
                                                      context: neutralContext)
        let withAlert = TrainingPlanEngine.status(health: health, imports: imports, readiness: 85, muscles: [], checkIn: nil,
                                                   context: neutralContext, physiologicalAlert: recoverAlert)

        XCTAssertNotEqual(withoutAlert.nextSession, .recovery, "High readiness with no alert should not already be recovery, or this test proves nothing.")
        XCTAssertEqual(withAlert.nextSession, .recovery, "A 'recover' severity alert must hard-override the proposal exactly like illness/very-low readiness does — this is the fix for the gap where the alert card and the actual plan could disagree.")
    }

    func testMeaningfulTrainingDaysIgnoresGenuinelyEasyActivity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Three days with *some* activity, but two of them are a short walk
        // and an easy Z1 recovery ride — load well under the "light" band
        // activityCalendar itself uses (<35). This used to force recovery
        // via a bare day-count regardless of how trivial the load was.
        let daily = [
            DailyTraining(date: now.addingTimeInterval(-1 * 86_400), sessions: 1, load: 8),   // easy Z1 ride ("paseo")
            DailyTraining(date: now.addingTimeInterval(-2 * 86_400), sessions: 1, load: 5),    // short walk
            DailyTraining(date: now.addingTimeInterval(-3 * 86_400), sessions: 1, load: 62)    // a real session
        ]
        XCTAssertEqual(TrainingPlanEngine.meaningfulTrainingDays72h(daily, now: now), 1,
                       "Only the genuinely loaded day should count toward the rest-day trigger.")

        // But three real, non-trivial days in the same window should still count.
        let allReal = daily.map { DailyTraining(date: $0.date, sessions: $0.sessions, load: 45) }
        XCTAssertEqual(TrainingPlanEngine.meaningfulTrainingDays72h(allReal, now: now), 3)
    }

    func testStepWeeklyEquivalentMatchesPlainDecayWithNoAddedLoad() {
        // With dayLoad: 0, the iterative step must reduce to the exact same
        // exponential decay projectTrajectory used inline before it started
        // accepting real future loads — no behavior change for any caller
        // that never assumes a future session.
        let stepped = PerformanceEngine.stepWeeklyEquivalent(140, dayLoad: 0, timeConstant: 7)
        XCTAssertEqual(stepped, 140 * exp(-1 / 7.0), accuracy: 0.001)
    }

    func testStepWeeklyEquivalentClimbsTowardSustainedLoad() {
        var value = 0.0
        for _ in 0..<200 { value = PerformanceEngine.stepWeeklyEquivalent(value, dayLoad: 40, timeConstant: 7) }
        // A sustained daily load of 40 should converge toward its weekly
        // equivalent (40 × 7 = 280), the same target ewmaWeeklyEquivalent
        // would reach given 200 identical days.
        XCTAssertEqual(value, 280, accuracy: 1)
    }

    func testProjectTrajectoryUsesFutureLoadsInsteadOfAssumingRest() {
        let rested = DecisionSimulatorEngine.projectTrajectory(
            tomorrowReadiness: 80, projectedAcuteLoad: 150, projectedChronicLoad: 140, days: 3
        )
        let trained = DecisionSimulatorEngine.projectTrajectory(
            tomorrowReadiness: 80, projectedAcuteLoad: 150, projectedChronicLoad: 140, days: 3,
            futureLoads: [60, 60]
        )
        // Assuming real training on days 2-3 instead of silent rest must
        // read as more fatigue, not less — both lower readiness and a
        // higher (or equal) acute load than the rest-only projection.
        XCTAssertLessThan(trained[1].readiness, rested[1].readiness)
        XCTAssertGreaterThan(trained[1].acuteLoad, rested[1].acuteLoad)
        // With zero future loads (the default), behavior must be identical
        // to the original rest-only projection — no regression for
        // existing callers.
        let explicitRest = DecisionSimulatorEngine.projectTrajectory(
            tomorrowReadiness: 80, projectedAcuteLoad: 150, projectedChronicLoad: 140, days: 3, futureLoads: [0, 0]
        )
        XCTAssertEqual(explicitRest.map(\.readiness), rested.map(\.readiness))
    }

    func testWeekAheadReturnsSevenConsecutiveDaysStartingToday() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)

        XCTAssertEqual(week.count, 7)
        let calendar = Calendar.current
        XCTAssertTrue(calendar.isDate(week[0].date, inSameDayAs: now))
        for index in 1..<week.count {
            XCTAssertEqual(calendar.dateComponents([.day], from: week[index - 1].date, to: week[index].date).day, 1,
                           "Each forecasted day must be exactly one day after the previous one.")
        }
        // Today's forecast must be the exact same recommendation status()
        // itself would give right now — not a second, silently-diverging
        // computation of "today".
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        let real = TrainingPlanEngine.status(health: health, imports: imports, readiness: assessment.score,
                                             muscles: assessment.muscles, checkIn: nil, context: neutralContext,
                                             physiologicalAlert: assessment.physiologicalAlert, now: now)
        XCTAssertEqual(week[0].kind, real.nextSession)
        for day in week { XCTAssertFalse(day.rationale.isEmpty) }
    }

    // What the week strip was missing: some sense of exigencia (ritmo/
    // duración/zona) per day, not just a bare kind + one-line rationale.
    func testWeekAheadDayForecastCarriesDurationAndIntensityPerKind() {
        let week = TrainingPlanEngine.weekAhead(health: HealthStore(), imports: ImportStore(), checkIn: nil, context: neutralContext, now: Date())
        for day in week {
            XCTAssertFalse(day.intensityLabel.isEmpty, "Every kind must carry a non-empty intensity label.")
            switch day.kind {
            // Kinds with a real phase-band duration in this app's model
            // must actually surface it, not silently drop to nil.
            case .easyRun, .qualityRun, .longRun, .swim, .bike, .brick:
                XCTAssertNotNil(day.targetMinutes, "\(day.kind) has a real duration band and must not read as nil.")
                XCTAssertGreaterThan(day.targetMinutes ?? 0, 0)
            // Kinds with no fixed duration in this app's model (strength
            // depends on chosen exercises; recovery/race day aren't a
            // phase-band session) — nil, not a fabricated number.
            case .strength, .recovery, .hybrid, .raceDay:
                XCTAssertNil(day.targetMinutes, "\(day.kind) has no fixed phase-band duration and must stay nil, not invent one.")
            }
        }
    }

    func testIntensityLabelMatchesTheSameZonesTodaysProposalUses() {
        XCTAssertEqual(TrainingPlanEngine.intensityLabel(for: .recovery), "Z1 · muy suave")
        XCTAssertEqual(TrainingPlanEngine.intensityLabel(for: .easyRun), "Z2 · suave")
        XCTAssertEqual(TrainingPlanEngine.intensityLabel(for: .qualityRun), "Z3–Z5 · calidad")
        XCTAssertEqual(TrainingPlanEngine.intensityLabel(for: .longRun), "Z2 · continuo")
        XCTAssertEqual(TrainingPlanEngine.intensityLabel(for: .strength), "Fuerza")
    }

    func testWeekAheadCanProposeQualityOrLongRunNotOnlyEasyRun() {
        // PR1.5: weekAhead never reads GoalStore.shared — profile is
        // constructed locally and passed directly below, so there's
        // nothing left for GoalStore.shared.save to exercise. Also uses
        // ImportStore(persistToDisk: false) instead of a plain ImportStore()
        // — the previous version still read this machine's real,
        // disk-persisted Hevy history despite passing profile explicitly,
        // confirmed to fail identically on main before PR1 for that reason.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón",
                                      date: Date().addingTimeInterval(60 * 86_400), targetValue: nil, unit: "min",
                                      priority: .primary, isActive: true)]
        profile.trainingDaysPerWeek = 5

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let week = TrainingPlanEngine.weekAhead(health: HealthStore(), imports: ImportStore(persistToDisk: false), checkIn: nil,
                                                context: context, now: Date())
        let kinds = Set(week.map(\.kind))
        // Passing `muscles: []` into balancedDecision's own shared fallback
        // used to resolve to a neutral 50/100 — below the 55-65 threshold
        // every one of quality/long run/hybrid/bike/brick requires — which
        // silently vetoed all of them for the entire simulated week
        // regardless of real deficits, spacing, or readiness. A real
        // half-marathon build block with zero history and a full week
        // ahead must be able to surface at least one of the two.
        XCTAssertTrue(kinds.contains(.qualityRun) || kinds.contains(.longRun),
                      "A week-long forecast for a real running goal must be able to propose quality or long run, not only easy runs.")
    }

    func testWeekAheadDecaysRealMuscleFatigueInsteadOfAssumingConstantFreshness() {
        // weekAhead's forward simulation used to hand balancedDecision a
        // constant "everything at 75/100" for legs on every single one of
        // the 6 simulated days, regardless of what actually happened today
        // or what the simulation itself scheduled — a real heavy leg day
        // logged an hour ago would have no effect at all on tomorrow's
        // simulated leg-fatigue gate. It must now seed from today's real
        // per-muscle assessment and decay it day by day.
        //
        // PR1.5: profile is constructed locally and passed directly below,
        // so there's nothing left for GoalStore.shared.save to exercise.
        // ImportStore(persistToDisk: false) below means this test's imports
        // are fully under its own control instead of merging on top of
        // this machine's real, disk-persisted Hevy history — confirmed to
        // fail identically on main before PR1 for that reason. With that
        // real history gone, a genuinely empty import history (nothing but
        // today's spike) tripped a DIFFERENT real gate instead — the
        // acute:chronic load-ratio ceiling reads a lone heavy day against
        // zero prior training as a huge spike and vetoes the whole week —
        // so `baseline` below seeds 8 weeks of a real, unrelated (push-day,
        // not leg) routine first, the same way an athlete who actually
        // trains regularly would never present a bare, empty history.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX de prueba", date: nil,
                                      targetValue: nil, unit: "min", priority: .primary, isActive: true)]

        let imports = ImportStore(persistToDisk: false)
        let now = Date()
        // A real, heavy leg day logged an hour ago — 4 leg exercises × 4
        // working sets each, all at a real working RPE so effort-weighting
        // doesn't discount them. Real quads/glutes/hamstring readiness
        // must land well below the 62/100 threshold every leg-sensitive
        // candidate (.hybrid, .qualityRun, .longRun) requires.
        let sets = (0..<4).map { _ in ImportedSet(weight: 100, reps: 6, type: "normal", rpe: 8) }
        let heavyLegDay = ImportedWorkout(
            title: "Pierna", start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800),
            exercises: [
                ImportedExercise(name: "Squat (Barbell)", sets: 4, volume: 2_400, totalReps: 24, averageWeight: 100, setDetails: sets),
                ImportedExercise(name: "Leg Press (Machine)", sets: 4, volume: 2_400, totalReps: 24, averageWeight: 100, setDetails: sets),
                ImportedExercise(name: "Romanian Deadlift (Barbell)", sets: 4, volume: 2_400, totalReps: 24, averageWeight: 100, setDetails: sets),
                ImportedExercise(name: "Leg Curl (Machine)", sets: 4, volume: 2_400, totalReps: 24, averageWeight: 100, setDetails: sets)
            ],
            muscleSets: ["Cuádriceps": 8, "Glúteos": 6, "Isquios": 4]
        )
        var baseline: [ImportedWorkout] = []
        for weekOffset in 1...8 {
            let day = now.addingTimeInterval(-Double(weekOffset) * 7 * 86_400 - 3 * 3_600)
            baseline.append(ImportedWorkout(
                title: "Empuje", start: day, end: day.addingTimeInterval(3_600),
                exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 1_600, totalReps: 32, averageWeight: 50, setDetails: nil),
                           ImportedExercise(name: "Press militar", sets: 4, volume: 800, totalReps: 32, averageWeight: 25, setDetails: nil),
                           ImportedExercise(name: "Fondos", sets: 4, volume: 400, totalReps: 32, averageWeight: 10, setDetails: nil)],
                muscleSets: ["Pecho": 4, "Hombros": 3, "Tríceps": 3]
            ))
        }
        imports.restore(workouts: baseline, labs: [])
        imports.restore(workouts: [heavyLegDay], labs: [])

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let week = TrainingPlanEngine.weekAhead(health: HealthStore(), imports: imports, checkIn: nil, context: context, now: now)

        let legSensitive: Set<PlannedSessionKind> = [.hybrid, .qualityRun, .longRun]
        XCTAssertFalse(legSensitive.contains(week[1].kind),
                       "The day immediately after a real heavy leg session must not get a leg-fatigue-gated session — got \(week[1].kind).")
        XCTAssertTrue(week.contains { legSensitive.contains($0.kind) },
                      "Leg fatigue must decay across the week instead of staying stuck at today's level — some later day should recover enough to unlock a leg-sensitive session again.")
    }

    func testBestStrengthPatternUsesRealRecentSetsNotAHardcodedZero() {
        // weekAhead's forward simulation used to hand bestStrengthPattern a
        // hardcoded recentSets: 0 for every muscle on every simulated day.
        // Since every muscle's own MEV is > 0, that reads as "real deficit"
        // uniformly for every candidate pattern — the +25 urgency bonus is
        // identical everywhere, so it cancels out of the ranking entirely
        // and silently collapses pattern selection back to readiness
        // alone (weekAhead itself now seeds and accumulates real
        // recentSets into the muscle array it passes here instead — this
        // proves the mechanism that fix depends on).
        func muscle(_ name: String, readiness: Int, recentSets: Int) -> MuscleReadiness {
            MuscleReadiness(name: name, readiness: readiness, lastTrained: nil, recentSets: recentSets)
        }
        // Deliberately gives Pecho HIGHER readiness than Espalda (92 vs 85)
        // — readiness alone favors "empuje" — while real weekly volume says
        // the opposite: Pecho (30 sets) is already past its own MRV (23),
        // Tríceps (15) is between its MAV/MRV, and Espalda/Bíceps (2/1
        // sets) are nowhere near their own MEV (8/4).
        // Legs sit exactly at their own MAV (no urgency either way) so
        // "pierna" stays out of contention and this is a clean two-way
        // comparison between empuje and tirón.
        let realMuscles = [
            muscle("Cuádriceps", readiness: 90, recentSets: 8), muscle("Glúteos", readiness: 90, recentSets: 6),
            muscle("Isquios", readiness: 90, recentSets: 4), muscle("Gemelos", readiness: 90, recentSets: 4),
            muscle("Pecho", readiness: 92, recentSets: 30), muscle("Hombros", readiness: 100, recentSets: 0),
            muscle("Tríceps", readiness: 96, recentSets: 15),
            muscle("Espalda", readiness: 85, recentSets: 2), muscle("Bíceps", readiness: 92, recentSets: 1),
            muscle("Core", readiness: 90, recentSets: 0),
        ]
        XCTAssertEqual(TrainingPlanEngine.bestStrengthPattern(realMuscles), "tirón",
                       "With real volume respected, tirón (under-dosed all week) must win despite empuje's higher raw readiness.")

        // The exact degenerate input weekAhead's old bug used to produce:
        // identical readiness numbers, but every recentSets forced to 0.
        // Sanity-checks the scenario itself — proving it's really the
        // recentSets data, not the readiness numbers, that flips the
        // answer above.
        let buggyMuscles = realMuscles.map { MuscleReadiness(name: $0.name, readiness: $0.readiness, lastTrained: nil, recentSets: 0) }
        XCTAssertEqual(TrainingPlanEngine.bestStrengthPattern(buggyMuscles), "empuje",
                       "With recentSets zeroed out (the old bug), readiness alone must win and wrongly pick empuje.")
    }

    func testCardioMuscleLoadGivesRunningAndCyclingRealButLighterLegLoadThanStrength() {
        // Running/cycling used to leave weekAhead's muscle model completely
        // untouched — only strength/hybrid/brick accrued any fatigue at
        // all. A long run or a hard ride genuinely tires quads/calves/
        // hamstrings/glutes, just at a real fraction of a dedicated
        // strength day's cost, not zero.
        let easy = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun)
        let quality = TrainingPlanEngine.cardioMuscleLoad(for: .qualityRun)
        let long = TrainingPlanEngine.cardioMuscleLoad(for: .longRun)
        let bike = TrainingPlanEngine.cardioMuscleLoad(for: .bike)
        let swim = TrainingPlanEngine.cardioMuscleLoad(for: .swim)

        for kind in [easy, quality, long] {
            XCTAssertEqual(Set(kind.keys), ["Gemelos", "Cuádriceps", "Isquios"])
        }
        // Ramped by how demanding the running type actually is, not one
        // flat number for every run.
        XCTAssertLessThan(easy["Cuádriceps"]!, quality["Cuádriceps"]!)
        XCTAssertLessThan(quality["Cuádriceps"]!, long["Cuádriceps"]!)
        XCTAssertEqual(Set(bike.keys), ["Cuádriceps", "Glúteos"])
        // Swimming doesn't load these lower-body muscles the way weight-
        // bearing running/cycling do — must stay untouched.
        XCTAssertTrue(swim.isEmpty)
        // Still clearly lighter than a dedicated strength day's per-muscle
        // credit (4 sets/muscle, see StrengthPrescriptionEngine.repRange).
        XCTAssertLessThan(long["Cuádriceps"]!, 4.0)
        XCTAssertLessThan(bike["Cuádriceps"]!, 4.0)
    }

    func testCardioMuscleLoadScalesByRealDurationInsteadOfOneFixedVectorPerKind() {
        // A 70-minute long run and a 150-minute one used to receive the
        // exact same muscle credit — this is the actual duration scaling.
        let short = TrainingPlanEngine.cardioMuscleLoad(for: .longRun, durationMinutes: 70)
        let long = TrainingPlanEngine.cardioMuscleLoad(for: .longRun, durationMinutes: 150)
        XCTAssertGreaterThan(long["Cuádriceps"]!, short["Cuádriceps"]!)
        // Omitting duration entirely must keep the exact old flat-vector
        // behavior — every existing caller that hasn't been updated yet.
        let noDuration = TrainingPlanEngine.cardioMuscleLoad(for: .longRun)
        XCTAssertEqual(noDuration["Cuádriceps"], 1.0)
    }

    func testCardioMuscleLoadScalesByElevationAsAProxyForTerrain() {
        // No separate "surface" signal exists anywhere in the data model —
        // real elevation gain is the best available stand-in for "this was
        // a hilly/trail session," and drives the same eccentric quad/calf
        // loading a flat route wouldn't.
        let flat = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0)
        let hilly = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 600)
        XCTAssertGreaterThan(hilly["Cuádriceps"]!, flat["Cuádriceps"]!)
    }

    func testCardioMuscleLoadScalesByRealDescentSeparatelyFromAscent() {
        // A downhill race or a big out-and-back with a genuine net descent
        // used to have no entity of its own — only ascent moved the
        // model. Eccentric braking on the way down is real, distinct
        // muscle damage, so this must be its own factor, not folded into
        // (or ignored relative to) ascent.
        let flat = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0, elevationDescendedMeters: 0)
        let steepDescent = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0, elevationDescendedMeters: 600)
        XCTAssertGreaterThan(steepDescent["Cuádriceps"]!, flat["Cuádriceps"]!)

        // A route with a real climb AND a real descent (a genuine loop or
        // out-and-back with elevation change in both directions) must get
        // credit for both, not whichever one happened to be in the metadata.
        let climbOnly = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 400, elevationDescendedMeters: 0)
        let climbAndDescend = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 400, elevationDescendedMeters: 400)
        XCTAssertGreaterThan(climbAndDescend["Cuádriceps"]!, climbOnly["Cuádriceps"]!)

        // Omitting it entirely must keep every existing caller's exact
        // old behavior (default 0, same as elevationMeters' own default).
        let omitted = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0)
        XCTAssertEqual(omitted["Cuádriceps"], flat["Cuádriceps"])
    }

    func testProgressionPaceCeilingsPreserveTheExistingDefaultAndBoundAggressive() {
        // Óptimo (the default every pre-existing test and every real user
        // who never touches this setting already runs on) must equal the
        // app's own established 1.55 overload line EXACTLY — anything
        // tighter would silently make the default more conservative than
        // the already-tuned behavior this whole app was built against.
        // Conservador is a genuinely more cautious direction (stops at the
        // existing "absorb" threshold, 1.30). Agresivo is the one pace
        // that genuinely crosses 1.55 — capped at 1.80, deliberately
        // still bounded rather than open-ended risk.
        XCTAssertEqual(ProgressionPace.conservative.ratioCeiling, 1.30, accuracy: 0.001)
        XCTAssertEqual(ProgressionPace.optimal.ratioCeiling, 1.55, accuracy: 0.001)
        XCTAssertEqual(ProgressionPace.aggressive.ratioCeiling, 1.80, accuracy: 0.001)
    }

    func testExceedsPaceCeilingGatesOnTheChosenPaceNotAFixedNumber() {
        // A ratio of 1.40 is real, actionable pressure for Conservador —
        // the whole point of the lever — but not yet for Óptimo, which
        // must behave exactly like the pre-existing, unparametrized
        // 1.55-only gate, and not remotely close for Agresivo.
        XCTAssertTrue(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.40, pace: .conservative))
        XCTAssertFalse(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.40, pace: .optimal))
        XCTAssertFalse(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.40, pace: .aggressive))
        // At the shared literature danger line (1.55): Óptimo's gate
        // fires (reproducing the old universal check exactly), but
        // Agresivo's genuinely does NOT — it still has real margin left.
        XCTAssertTrue(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.55, pace: .optimal))
        XCTAssertFalse(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.55, pace: .aggressive))
        // Only past Agresivo's own, higher, still-bounded ceiling does
        // even Agresivo get sent to recovery.
        XCTAssertTrue(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.80, pace: .aggressive))
        // A genuinely easy ratio must never fire for anyone.
        XCTAssertFalse(TrainingPlanEngine.exceedsPaceCeiling(ratio: 1.0, pace: .conservative))
    }

    func testAggressiveRiskDisclosureFiresOnlyWhenAggressivesExtraMarginIsActuallyUsed() {
        // The whole point: never let a real day proceed through the
        // 1.55-1.80 zone silently just because Agresivo tolerates it.
        XCTAssertNotNil(TrainingPlanEngine.aggressiveRiskDisclosure(ratio: 1.65, pace: .aggressive, kind: .qualityRun))
        // Óptimo/Conservador never reach this zone without already being
        // sent to .recovery by exceedsPaceCeiling — but the disclosure
        // function itself must still refuse to fire for them, as a
        // second, independent safeguard.
        XCTAssertNil(TrainingPlanEngine.aggressiveRiskDisclosure(ratio: 1.65, pace: .optimal, kind: .qualityRun))
        XCTAssertNil(TrainingPlanEngine.aggressiveRiskDisclosure(ratio: 1.65, pace: .conservative, kind: .qualityRun))
        // A genuinely easy ratio, even under Agresivo, needs no warning.
        XCTAssertNil(TrainingPlanEngine.aggressiveRiskDisclosure(ratio: 1.2, pace: .aggressive, kind: .qualityRun))
        // A day that's already .recovery doesn't need its own rationale
        // re-flagged with this — exceedsPaceCeiling's own rationale
        // already covers "why recovery today".
        XCTAssertNil(TrainingPlanEngine.aggressiveRiskDisclosure(ratio: 1.65, pace: .aggressive, kind: .recovery))
    }

    func testRouteElevationCalculatorSumsOnlyRealDescentSteps() {
        // A simple down-up-down route: 100 → 80 (descend 20) → 90 (climb,
        // ignored) → 60 (descend 30). Total real descent: 50, not the net
        // change (40) and not the total absolute movement (60).
        let descent = RouteElevationCalculator.cumulativeDescent(altitudes: [100, 80, 90, 60])
        XCTAssertEqual(descent, 50, accuracy: 0.001)
    }

    func testRouteElevationCalculatorHandlesAllUphillAndTooFewPoints() {
        XCTAssertEqual(RouteElevationCalculator.cumulativeDescent(altitudes: [10, 20, 30]), 0,
                       "A purely uphill route has zero real descent.")
        XCTAssertEqual(RouteElevationCalculator.cumulativeDescent(altitudes: []), 0)
        XCTAssertEqual(RouteElevationCalculator.cumulativeDescent(altitudes: [50]), 0,
                       "A single point has no consecutive step to measure.")
    }

    // MARK: - "¿Qué pasa si...?" combinable simulator

    func testStandardDrinkCalculatorUsesRealNIAAAEquivalentsNotABareDrinkCount() {
        let twoBeers = [DrinkSelection(type: .beer, count: 2)]
        let twoMartinis = [DrinkSelection(type: .martini, count: 2)]
        XCTAssertEqual(StandardDrinkCalculator.totalStandardDrinks(twoBeers), 2.0, accuracy: 0.001)
        XCTAssertEqual(StandardDrinkCalculator.totalStandardDrinks(twoMartinis), 4.0, accuracy: 0.001)
        XCTAssertGreaterThan(StandardDrinkCalculator.totalStandardDrinks(twoMartinis), StandardDrinkCalculator.totalStandardDrinks(twoBeers),
                             "2 martinis must carry real more alcohol than 2 beers — the whole point of moving off a bare drink count.")
        XCTAssertEqual(StandardDrinkCalculator.totalEthanolGrams(twoBeers), 28, accuracy: 0.001)
    }

    func testCaffeinePharmacokineticsResidualFractionHalvesAtOneHalfLife() {
        XCTAssertEqual(CaffeinePharmacokinetics.residualFraction(hoursElapsed: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(CaffeinePharmacokinetics.residualFraction(hoursElapsed: 5), 0.5, accuracy: 0.001)
        XCTAssertEqual(CaffeinePharmacokinetics.residualFraction(hoursElapsed: 10), 0.25, accuracy: 0.001)
        XCTAssertEqual(CaffeinePharmacokinetics.residualFraction(hoursElapsed: -1), 1.0, accuracy: 0.001,
                       "Must never blow up or exceed the full dose for a nonsensical negative elapsed time.")
    }

    func testCaffeinePharmacokineticsHoursUntilBedtimeWrapsPastMidnightInsteadOfGoingNegative() {
        XCTAssertEqual(CaffeinePharmacokinetics.hoursUntilBedtime(intakeHour: 17, bedtimeHour: 23), 6, accuracy: 0.001)
        XCTAssertEqual(CaffeinePharmacokinetics.hoursUntilBedtime(intakeHour: 22, bedtimeHour: 0.5), 2.5, accuracy: 0.001,
                       "A bedtime after midnight must wrap forward, not read as before the intake.")
    }

    func testLateBedtimeOccurrencesFlagsNightsMeaningfullyAfterPersonalMedian() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var schedule: [NightlySleepSchedule] = []
        for dayOffset in 1...11 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let bedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
            schedule.append(NightlySleepSchedule(night: day, bedtime: bedtime, wakeTime: bedtime.addingTimeInterval(7 * 3_600)))
        }
        // One night clearly later than the 23:00 personal median (01:00 — 2h later).
        let lateDay = calendar.date(byAdding: .day, value: -12, to: today)!
        let lateBedtime = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: lateDay)!
        schedule.append(NightlySleepSchedule(night: lateDay, bedtime: lateBedtime, wakeTime: lateBedtime.addingTimeInterval(6 * 3_600)))

        let occurrences = HabitAssociationEngine.lateBedtimeOccurrences(schedule: schedule)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences.first?.kind, .lateBedtime)
    }

    func testLateBedtimeOccurrencesNeedsAtLeastTenRealNightsBeforeAMedianMeansAnything() {
        let calendar = Calendar.current
        let schedule = (0..<5).map { offset -> NightlySleepSchedule in
            let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
            return NightlySleepSchedule(night: day, bedtime: day, wakeTime: day)
        }
        XCTAssertTrue(HabitAssociationEngine.lateBedtimeOccurrences(schedule: schedule).isEmpty)
    }

    func testSleepArchitectureDailyShareSeriesSkipsNightsWithoutARealStageSplit() {
        let night1 = NightlySleepStages(night: Date(), deepHours: 1.5, remHours: 1.0, coreHours: 4.0, unspecifiedHours: 0, awakeHours: 0.2)
        let night2 = NightlySleepStages(night: Date().addingTimeInterval(-86_400), deepHours: 0, remHours: 0, coreHours: 0, unspecifiedHours: 6.5, awakeHours: 0.1)
        let deepSeries = SleepArchitectureEngine.dailyDeepShareSeries([night1, night2])
        XCTAssertEqual(deepSeries.count, 1, "Night2 has no real deep/REM split — must be excluded, not averaged in as 0%.")
        XCTAssertEqual(deepSeries.first?.value ?? -1, 1.5 / 6.5 * 100, accuracy: 0.01)
        let remSeries = SleepArchitectureEngine.dailyRemShareSeries([night1, night2])
        XCTAssertEqual(remSeries.count, 1)
        XCTAssertEqual(remSeries.first?.value ?? -1, 1.0 / 6.5 * 100, accuracy: 0.01)
    }

    func testWhatIfAlcoholImpactScalesByRealStandardDrinksWithoutALearnedAssociation() {
        let referenceDose = WhatIfSimulatorEngine.alcoholImpact(standardDrinks: 2.0, association: nil)
        XCTAssertEqual(referenceDose.readinessImpact, -6)
        XCTAssertFalse(referenceDose.isLearned)
        // 8 standard drinks: ratio 8/2=4, capped at 3x -> -6*3 = -18, not a runaway extrapolation.
        let heavyDose = WhatIfSimulatorEngine.alcoholImpact(standardDrinks: 8.0, association: nil)
        XCTAssertEqual(heavyDose.readinessImpact, -18)
    }

    func testWhatIfAlcoholImpactUsesLearnedAssociationWhenConfidentScaledByDose() {
        let association = HabitAssociation(
            kind: .alcohol, samples: 8,
            effects: [HabitMetricEffect(name: "HRV", changePercent: -10), HabitMetricEffect(name: "REM", changePercent: -8)],
            compositeChange: -9, direction: .adverse,
            confidence: ConfidenceAssessment(score: 80, level: .high, reason: "test"),
            headline: "test"
        )
        // HabitAssociationEngine.readinessImpact(-9 composite, high confidence) = -2; doubled dose (4 standard drinks vs. the 2-drink reference) -> -4.
        let impact = WhatIfSimulatorEngine.alcoholImpact(standardDrinks: 4.0, association: association)
        XCTAssertTrue(impact.isLearned)
        XCTAssertEqual(impact.readinessImpact, -4)
    }

    func testWhatIfCaffeineImpactIsSmallerTheFurtherBeforeBedtimeItsHad() {
        let earlyMorning = WhatIfSimulatorEngine.caffeineImpact(mg: 80, hour: 8, schedule: [], association: nil)
        let rightBeforeBed = WhatIfSimulatorEngine.caffeineImpact(mg: 80, hour: 21, schedule: [], association: nil)
        XCTAssertGreaterThan(earlyMorning.readinessImpact, rightBeforeBed.readinessImpact,
                             "Caffeine hours before the default bedtime must cost less than the same dose right before it.")
    }

    func testWhatIfLateBedtimeImpactScalesByExtraMinutes() {
        let oneHour = WhatIfSimulatorEngine.lateBedtimeImpact(extraMinutes: 60, association: nil)
        XCTAssertEqual(oneHour.readinessImpact, -4)
        let twoHours = WhatIfSimulatorEngine.lateBedtimeImpact(extraMinutes: 120, association: nil)
        XCTAssertEqual(twoHours.readinessImpact, -8)
    }

    func testWhatIfScenarioIsEmptyRequiresARealActiveFactor() {
        var scenario = WhatIfScenario()
        XCTAssertTrue(scenario.isEmpty)
        scenario.drinks = [DrinkSelection(type: .beer, count: 1)]
        XCTAssertFalse(scenario.isEmpty)

        scenario = WhatIfScenario()
        scenario.extraBedtimeMinutes = 30
        XCTAssertFalse(scenario.isEmpty)

        scenario = WhatIfScenario()
        scenario.lateOrHeavyDinner = true
        XCTAssertFalse(scenario.isEmpty)

        // Caffeine needs BOTH a dose and an hour — a dangling dose with no
        // hour selected must not silently count as an active factor.
        scenario = WhatIfScenario()
        scenario.caffeineMg = 80
        XCTAssertTrue(scenario.isEmpty)
        scenario.caffeineHour = 17
        XCTAssertFalse(scenario.isEmpty)
    }

    func testCardioMuscleLoadClampsExtremeDurationsInsteadOfDistorting() {
        // A 5-minute jog shouldn't erase fatigue accounting, and a
        // multi-hour outlier shouldn't blow the model up either.
        let veryShort = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 2)
        let veryLong = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 600)
        XCTAssertGreaterThan(veryShort["Cuádriceps"]!, 0)
        XCTAssertLessThan(veryLong["Cuádriceps"]!, 3.0)
    }

    func testCardioMuscleLoadScalesByRealIntensityOnTopOfDurationAndElevation() {
        // A hard descent or a threshold effort at the SAME duration/
        // elevation as an easy jog does real extra muscular damage that
        // duration/elevation alone can't see — this is the actual real-HR
        // intensity scaling asked for after the volume-landmark fix.
        let baseline = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0)
        let sameSessionHarder = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0, intensityFactor: 1.3)
        XCTAssertEqual(sameSessionHarder["Cuádriceps"]!, baseline["Cuádriceps"]! * 1.3, accuracy: 0.001)
        // A factor below 1.0 must never happen from realIntensityFactor,
        // but cardioMuscleLoad itself still guards against ever REDUCING
        // load below the duration/elevation baseline — intensity can only
        // add, never subtract.
        let clamped = TrainingPlanEngine.cardioMuscleLoad(for: .easyRun, durationMinutes: 30, elevationMeters: 0, intensityFactor: 0.5)
        XCTAssertEqual(clamped["Cuádriceps"], baseline["Cuádriceps"])
    }

    func testRealIntensityFactorReturnsBaselineWithoutRealHeartRateData() {
        // No matched session at all.
        XCTAssertEqual(TrainingPlanEngine.realIntensityFactor(
            matches: [], restingHRHistory: [55], restingHRSnapshot: 55,
            configuredMaxHR: 190, birthDate: nil, manualBoundaries: nil
        ), 1.0, "No real session to classify — must not fabricate an intensity.")

        // A real session, but Apple Health never recorded its average HR.
        let noHR = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 40, calories: nil,
                                 distanceKilometers: 8, averageHeartRate: nil, elevationMeters: nil,
                                 activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        XCTAssertEqual(TrainingPlanEngine.realIntensityFactor(
            matches: [noHR], restingHRHistory: [55], restingHRSnapshot: 55,
            configuredMaxHR: 190, birthDate: nil, manualBoundaries: nil
        ), 1.0, "No averageHeartRate on the real session — must not fabricate an intensity.")
    }

    func testRealIntensityFactorReturnsBaselineWithoutAnyWayToEstimateMax() {
        // Real HR data exists, but nothing to classify it against: no
        // manual boundaries, no configured max, no birthDate. Silence,
        // not a guessed max.
        let session = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 40, calories: nil,
                                    distanceKilometers: 8, averageHeartRate: 175, elevationMeters: nil,
                                    activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        XCTAssertEqual(TrainingPlanEngine.realIntensityFactor(
            matches: [session], restingHRHistory: [55], restingHRSnapshot: 55,
            configuredMaxHR: nil, birthDate: nil, manualBoundaries: nil
        ), 1.0)
    }

    func testRealIntensityFactorScalesUpForRealHighZoneEffort() {
        // Configured max 190, resting 50 → reserve 140. 175 bpm → 89% HRR,
        // squarely Z4 (80-90%) → +30% (1 + (4-2)×0.15).
        let hard = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 40, calories: nil,
                                 distanceKilometers: 8, averageHeartRate: 175, elevationMeters: nil,
                                 activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        let factor = TrainingPlanEngine.realIntensityFactor(
            matches: [hard], restingHRHistory: [50], restingHRSnapshot: 50,
            configuredMaxHR: 190, birthDate: nil, manualBoundaries: nil
        )
        XCTAssertEqual(factor, 1.30, accuracy: 0.001)

        // Same profile, an easy 60% HRR effort (134 bpm) — Z1-Z2, no extra load.
        let easy = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 40, calories: nil,
                                 distanceKilometers: 8, averageHeartRate: 134, elevationMeters: nil,
                                 activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        let easyFactor = TrainingPlanEngine.realIntensityFactor(
            matches: [easy], restingHRHistory: [50], restingHRSnapshot: 50,
            configuredMaxHR: 190, birthDate: nil, manualBoundaries: nil
        )
        XCTAssertEqual(easyFactor, 1.0, accuracy: 0.001)
    }

    func testRealIntensityFactorWeightsMultipleSameDaySessionsByDuration() {
        // A short hard interval session plus a much longer easy run on the
        // same day must not let the (numerically fewer) hard minutes alone
        // decide the whole day's intensity, or let the easy volume dilute
        // a real hard effort down to nothing — it's a real duration-
        // weighted average of what actually happened.
        let short = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 10, calories: nil,
                                  distanceKilometers: 2, averageHeartRate: 185, elevationMeters: nil,
                                  activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        let long = HealthWorkout(id: UUID(), date: Date(), durationMinutes: 50, calories: nil,
                                 distanceKilometers: 8, averageHeartRate: 130, elevationMeters: nil,
                                 activity: "Carrera", muscleGroups: [:], source: "Apple Watch")
        // Weighted average: (185×10 + 130×50) / 60 = 139.2 bpm — with
        // resting 50/max 190 (reserve 140), that's ~63.7% HRR → Z2, no
        // extra load. A naive unweighted average (157.5) would have
        // wrongly landed in Z3.
        let factor = TrainingPlanEngine.realIntensityFactor(
            matches: [short, long], restingHRHistory: [50], restingHRSnapshot: 50,
            configuredMaxHR: 190, birthDate: nil, manualBoundaries: nil
        )
        XCTAssertEqual(factor, 1.0, accuracy: 0.001)
    }

    func testHeartRateZoneClassifierPrefersManualBoundariesOverEstimatedOnes() {
        // A real lactate-test boundary must win outright over the %HRR
        // estimate, even when the estimate would classify the same bpm
        // into a different zone.
        let manual = HeartRateZoneBoundaries(z1z2: 130, z2z3: 150, z3z4: 165, z4z5: 178)
        XCTAssertEqual(HeartRateZoneClassifier.zone(bpm: 160, manualBoundaries: manual, effectiveMax: 200, restingHR: 50), 3)
        XCTAssertEqual(HeartRateZoneClassifier.zone(bpm: 125, manualBoundaries: manual, effectiveMax: 200, restingHR: 50), 1)
        XCTAssertEqual(HeartRateZoneClassifier.zone(bpm: 185, manualBoundaries: manual, effectiveMax: 200, restingHR: 50), 5)
    }

    func testHeartRateZoneClassifierEffectiveMaximumFallbackOrder() {
        // Configured beats age-based beats peak-based.
        XCTAssertEqual(HeartRateZoneClassifier.effectiveMaximum(configured: 195, birthDate: Date(timeIntervalSince1970: 0), observedPeak: 150), 195)
        let thirtyYearsAgo = Calendar.current.date(byAdding: .year, value: -30, to: Date())!
        XCTAssertEqual(HeartRateZoneClassifier.effectiveMaximum(configured: nil, birthDate: thirtyYearsAgo, observedPeak: 150), 208 - 0.7 * 30, accuracy: 0.5)
        XCTAssertEqual(HeartRateZoneClassifier.effectiveMaximum(configured: nil, birthDate: nil, observedPeak: 180), 185)
    }

    func testEstimatedSessionMinutesReusesWorkoutPlannersOwnPhaseBands() {
        // The same numbers that already size a real proposed session must
        // drive both the muscle-load duration scaling and weekAhead's own
        // day-by-day minute-deficit tracking — not a second, separately
        // invented estimate.
        let easyBand = WorkoutPlanner.easyRunBand(phase: .base)
        XCTAssertEqual(TrainingPlanEngine.estimatedSessionMinutes(for: .easyRun, phase: .base), (easyBand.min + easyBand.max) / 2)
        let longBand = WorkoutPlanner.longRunBand(phase: .buildSpecific)
        XCTAssertEqual(TrainingPlanEngine.estimatedSessionMinutes(for: .longRun, phase: .buildSpecific), (longBand.min + longBand.max) / 2)
        let bikeBand = WorkoutPlanner.bikeBand(phase: .taper)
        XCTAssertEqual(TrainingPlanEngine.estimatedSessionMinutes(for: .bike, phase: .taper), (bikeBand.min + bikeBand.max) / 2)
        let swimBand = WorkoutPlanner.swimBand(phase: .base)
        XCTAssertEqual(TrainingPlanEngine.estimatedSessionMinutes(for: .swim, phase: .base), (swimBand.min + swimBand.max) / 2)
        XCTAssertGreaterThan(TrainingPlanEngine.estimatedSessionMinutes(for: .brick, phase: .buildSpecific), 0)
    }

    func testWeekAheadProducesAValidSevenDayForecastWithDecrementingDisciplineDeficits() {
        // Smoke-level coverage for the new plumbing: swim/bike/brick
        // minute deficits now mutate day by day inside weekAhead instead
        // of staying fixed at today's value — this must still produce a
        // coherent 7-day forecast for a triathlon-focused athlete with a
        // large real weekly shortfall, not crash or degenerate into
        // proposing the same discipline every single day just because a
        // deficit existed on day one.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .triathlon, title: "Triatlón de prueba", date: nil,
                                      targetValue: nil, unit: "min", priority: .primary, isActive: true)]

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let week = TrainingPlanEngine.weekAhead(health: HealthStore(), imports: ImportStore(), checkIn: nil, context: context, now: Date())
        XCTAssertEqual(week.count, 7)
        XCTAssertLessThan(week.filter { $0.kind == .swim }.count, 7,
                          "Closing a real weekly swim shortfall shouldn't require filling every single day of the week with swimming.")
    }

    func testEffortWeightForBareRPEMatchesTheSetBasedVersion() {
        // weekAhead's forward simulation estimates a proposed (not yet
        // logged) set's effort from its prescribed RIR — needs the exact
        // same RPE-proximity-to-failure bands real logged sets already use,
        // just without requiring an ImportedSet to read the RPE from.
        XCTAssertEqual(StrengthProgressEngine.effortWeight(forRPE: 9), 1.0)
        XCTAssertEqual(StrengthProgressEngine.effortWeight(forRPE: 7.5), 0.85)
        XCTAssertEqual(StrengthProgressEngine.effortWeight(forRPE: 6.5), 0.7)
        XCTAssertEqual(StrengthProgressEngine.effortWeight(forRPE: 5.5), 0.55)
        XCTAssertEqual(StrengthProgressEngine.effortWeight(forRPE: 2), 0.4)
        // Must agree exactly with the ImportedSet-based version for the same RPE.
        let set = ImportedSet(weight: 100, reps: 5, type: "normal", rpe: 8.5)
        XCTAssertEqual(StrengthProgressEngine.effortWeight(set), StrengthProgressEngine.effortWeight(forRPE: 8.5))
    }

    func testRepRangeExposesNumericSetsAndRIRMatchingItsOwnDisplayLabel() {
        // The set count and RIR were previously only readable by parsing
        // the display string (e.g. "4 × 3–5 · RIR 1–2") — weekAhead's
        // forward simulation needs them as real numbers to compute an
        // effective-set count, not a string to parse.
        let liftSpecific = StrengthPrescriptionEngine.repRange(for: .liftSpecificity, light: false)
        XCTAssertEqual(liftSpecific.sets, 4)
        XCTAssertEqual(liftSpecific.estimatedRIR, 1.5)
        XCTAssertTrue(liftSpecific.label.contains("RIR 1"))

        let enduranceSupport = StrengthPrescriptionEngine.repRange(for: .enduranceSupport, light: false)
        XCTAssertEqual(enduranceSupport.sets, 3)
        XCTAssertEqual(enduranceSupport.estimatedRIR, 4)
        XCTAssertTrue(enduranceSupport.label.contains("RIR 4"))

        let hypertrophyLight = StrengthPrescriptionEngine.repRange(for: .hypertrophy, light: true)
        XCTAssertEqual(hypertrophyLight.sets, 3)
        XCTAssertEqual(hypertrophyLight.estimatedRIR, 3)
    }

    func testGymFallbackExercisesResolveRealMuscleGroupsInsteadOfFallingToCuerpoCompleto() {
        // The cold-start fallback list (no imported history at all) used
        // Spanish display names ("Press banca", "Sentadilla"...) that
        // MuscleMap's English-only substring matching couldn't recognize —
        // every one of them silently fell through to its generic "Cuerpo
        // completo" bucket (and "Curl femoral" was even misread as a
        // biceps curl via the bare "curl" check). This matters more now
        // that weekAhead's forward simulation reads real muscle
        // involvement from these exact names for a brand-new athlete with
        // no logged history yet.
        let pushDay = WorkoutPlanner.gym(for: "Empuje", imports: ImportStore(), light: false, muscles: [])
        let legDay = WorkoutPlanner.gym(for: "Pierna", imports: ImportStore(), light: false, muscles: [])
        XCTAssertTrue(pushDay.exercises.contains { MuscleMap.groups(for: $0.name).contains("Pecho") },
                      "Expected at least one fallback push exercise to resolve to Pecho, got \(pushDay.exercises.map(\.name)).")
        XCTAssertTrue(legDay.exercises.contains { MuscleMap.groups(for: $0.name).contains("Cuádriceps") },
                      "Expected at least one fallback leg exercise to resolve to Cuádriceps, got \(legDay.exercises.map(\.name)).")
        XCTAssertFalse(legDay.exercises.contains { $0.name.localizedCaseInsensitiveContains("leg curl") && MuscleMap.groups(for: $0.name).contains("Bíceps") },
                       "A leg curl must never be misread as a biceps curl.")
    }

    func testLongevityRecoveryScoresADecliningWeekWorseThanAFlatWeekWithTheSameAverage() {
        // A plain 14-day average can't tell "consistently sleeping your
        // own normal" apart from "sliding well below your own normal for
        // the last week" when both happen to average out to the same
        // number — but they're very different recovery situations. Personal
        // trend (the same favorableHigh-corrected z-score PersonalBaselineEngine
        // already computes for HRV) and real accumulated debt against this
        // person's own habitual now catch exactly that.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(-40 * 86_400)
        func health(withNightlyHours hours: [Double]) -> HealthStore {
            let store = HealthStore()
            store.sleepHistory = hours.enumerated().map { index, value in
                TrendPoint(date: start.addingTimeInterval(Double(index) * 86_400), value: value)
            }
            return store
        }
        let flat = health(withNightlyHours: Array(repeating: 7.0, count: 14))
        let declining = health(withNightlyHours: Array(repeating: 8.5, count: 7) + Array(repeating: 5.5, count: 7))

        let flatIndex = LongevityEngine.calculate(health: flat, imports: ImportStore())
        let decliningIndex = LongevityEngine.calculate(health: declining, imports: ImportStore())
        guard let flatRecovery = flatIndex.dimensions.first(where: { $0.name == "Recuperación" }),
              let decliningRecovery = decliningIndex.dimensions.first(where: { $0.name == "Recuperación" }) else {
            XCTFail("Expected a Recuperación dimension for both cases.")
            return
        }
        XCTAssertLessThan(decliningRecovery.score, flatRecovery.score,
                          "A recent decline against personal habitual (with real accumulated debt) must score worse than a flat week at the identical 14-day average.")
    }

    private func nightlySchedule(daysFrom start: Date, day: Int, bedHour: Double) -> NightlySleepSchedule {
        let bedtime = start.addingTimeInterval(Double(day) * 86_400 + bedHour * 3_600)
        let wake = bedtime.addingTimeInterval(8 * 3_600)
        return NightlySleepSchedule(night: Calendar.current.startOfDay(for: wake), bedtime: bedtime, wakeTime: wake)
    }

    func testSleepRegularityNeedsAMinimumNumberOfNights() {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-10 * 86_400)
        let fourNights = (0..<4).map { nightlySchedule(daysFrom: start, day: $0, bedHour: 23.0) }
        XCTAssertNil(SleepRegularityEngine.evaluate(fourNights),
                    "A handful of nights can't tell a genuinely irregular schedule apart from one late night — must stay nil (accumulating), not a guessed score.")
    }

    func testSleepRegularityScoresAConsistentScheduleHigherThanAnErraticOne() {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-20 * 86_400)
        let consistent = (0..<10).map { nightlySchedule(daysFrom: start, day: $0, bedHour: 23.0) }
        // Alternating an early and a late bedtime — a real irregular
        // pattern, not just noise.
        let erratic = (0..<10).map { nightlySchedule(daysFrom: start, day: $0, bedHour: $0 % 2 == 0 ? 21.0 : 25.5) }

        guard let consistentResult = SleepRegularityEngine.evaluate(consistent),
              let erraticResult = SleepRegularityEngine.evaluate(erratic) else {
            XCTFail("Expected both schedules to produce a regularity score.")
            return
        }
        XCTAssertGreaterThan(consistentResult.score, erraticResult.score)
        XCTAssertLessThan(consistentResult.bedtimeVariabilityMinutes, 15)
        XCTAssertGreaterThan(erraticResult.bedtimeVariabilityMinutes, 60)
    }

    func testSleepRegularityDoesNotMisreadABedtimeRightAroundMidnightAsErratic() {
        // 23:50 and 00:10 are only 20 real minutes apart, but a naive
        // "hour of day" comparison would read them as ~23 hours apart.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-20 * 86_400)
        let aroundMidnight = (0..<10).map { index in
            nightlySchedule(daysFrom: start, day: index, bedHour: index % 2 == 0 ? 23.833 : 24.167) // 23:50 / 00:10
        }
        guard let result = SleepRegularityEngine.evaluate(aroundMidnight) else {
            XCTFail("Expected a regularity score.")
            return
        }
        XCTAssertLessThan(result.bedtimeVariabilityMinutes, 20,
                          "Bedtimes hovering right around midnight must not read as wildly inconsistent due to the day rollover.")
    }

    func testLongevityRecoveryScoresAnErraticScheduleWorseThanAConsistentOneAtIdenticalDuration() {
        // Isolates the new regularity signal specifically: identical sleep
        // duration every night in both cases (so the existing absolute/
        // trend/debt components stay flat and equal either way) — only
        // the bedtime pattern differs.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-20 * 86_400)
        func store(bedHours: [Double]) -> HealthStore {
            let health = HealthStore()
            let schedules = bedHours.enumerated().map { day, bedHour in nightlySchedule(daysFrom: start, day: day, bedHour: bedHour) }
            health.sleepScheduleHistory = schedules
            health.sleepHistory = schedules.map { TrendPoint(date: $0.night, value: $0.wakeTime.timeIntervalSince($0.bedtime) / 3_600) }
            return health
        }
        let consistent = store(bedHours: Array(repeating: 23.0, count: 10))
        let erratic = store(bedHours: (0..<10).map { $0 % 2 == 0 ? 21.0 : 25.5 })

        let consistentIndex = LongevityEngine.calculate(health: consistent, imports: ImportStore())
        let erraticIndex = LongevityEngine.calculate(health: erratic, imports: ImportStore())
        guard let consistentRecovery = consistentIndex.dimensions.first(where: { $0.name == "Recuperación" }),
              let erraticRecovery = erraticIndex.dimensions.first(where: { $0.name == "Recuperación" }) else {
            XCTFail("Expected a Recuperación dimension for both cases.")
            return
        }
        XCTAssertLessThan(erraticRecovery.score, consistentRecovery.score,
                          "Same sleep duration every night either way — only an erratic bedtime should score worse.")
    }

    func testLongevityRecoveryConfidenceReflectsRegularitysOwnSampleCountNotTotalSleepSamples() {
        // Regularity needs its own real, clean nightly schedule samples —
        // fewer nights can qualify for it than for plain sleep duration
        // (not every night's HealthKit data has distinguishable stages).
        // The dimension's overall confidence must reflect that weaker
        // signal, not ride on a much larger duration-only sample count.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-30 * 86_400)
        let health = HealthStore()
        // 20 nights of plain duration — past the "high confidence"
        // threshold (>=10) on its own.
        health.sleepHistory = (0..<20).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: 7.5) }
        // Only exactly the regularity minimum (5) of real nightly schedules.
        health.sleepScheduleHistory = (0..<5).map { nightlySchedule(daysFrom: start, day: $0, bedHour: 23.0) }

        let index = LongevityEngine.calculate(health: health, imports: ImportStore())
        guard let recovery = index.dimensions.first(where: { $0.name == "Recuperación" }) else {
            XCTFail("Expected a Recuperación dimension.")
            return
        }
        XCTAssertEqual(recovery.confidence, .medium,
                       "20 duration-only samples alone would read as high confidence — but regularity itself only has 5 real nights, and that weaker signal must be what the dimension's confidence reflects.")
    }

    private func nightlyStages(daysFrom start: Date, day: Int, deep: Double, rem: Double, core: Double,
                               unspecified: Double = 0, awake: Double = 0.3) -> NightlySleepStages {
        NightlySleepStages(night: start.addingTimeInterval(Double(day) * 86_400), deepHours: deep,
                          remHours: rem, coreHours: core, unspecifiedHours: unspecified, awakeHours: awake)
    }

    func testSleepArchitectureScoresAHealthyDeepAndRemMixWell() {
        // 16.25% deep (within the 13–23% reference band), 20% REM (right
        // at the edge of the 20–25% band), high continuity — this is
        // what Walker would call a genuinely restorative night, not just
        // a long one.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let nights = (0..<14).map { nightlyStages(daysFrom: start, day: $0, deep: 1.3, rem: 1.6, core: 4.5, unspecified: 0.6) }
        guard let result = SleepArchitectureEngine.evaluate(nights) else {
            XCTFail("Expected an assessment with 14 qualifying nights.")
            return
        }
        XCTAssertGreaterThanOrEqual(result.score, 85)
    }

    func testSleepArchitectureScoresLowDeepAndFragmentedNightsWorseThanAHealthyMix() {
        // A fragmented, alcohol-suppressed-REM kind of night: 4.3% deep,
        // 11.4% REM, and real awakenings — duration-only scoring couldn't
        // tell this apart from the healthy case above if total hours matched.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let poor = (0..<14).map { nightlyStages(daysFrom: start, day: $0, deep: 0.3, rem: 0.8, core: 5.5, unspecified: 0.4, awake: 1.2) }
        let healthy = (0..<14).map { nightlyStages(daysFrom: start, day: $0, deep: 1.3, rem: 1.6, core: 4.5, unspecified: 0.6) }
        guard let poorResult = SleepArchitectureEngine.evaluate(poor), let healthyResult = SleepArchitectureEngine.evaluate(healthy) else {
            XCTFail("Expected both assessments to qualify.")
            return
        }
        XCTAssertLessThan(poorResult.score, healthyResult.score - 20)
    }

    func testSleepArchitectureNeedsAMinimumNumberOfRealStagedNights() {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let fourNights = (0..<4).map { nightlyStages(daysFrom: start, day: $0, deep: 1.3, rem: 1.6, core: 4.5) }
        XCTAssertNil(SleepArchitectureEngine.evaluate(fourNights), "4 real nights isn't enough to say anything about a pattern.")
    }

    func testSleepArchitectureIgnoresNightsWithoutARealStageSplit() {
        // 4 real nights plus 6 "unspecified-only" nights (older data or
        // phone-only tracking, no deep/REM split at all) must not count
        // toward the minimum — they say nothing about architecture.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let real = (0..<4).map { nightlyStages(daysFrom: start, day: $0, deep: 1.3, rem: 1.6, core: 4.5) }
        let unstaged = (4..<10).map { nightlyStages(daysFrom: start, day: $0, deep: 0, rem: 0, core: 0, unspecified: 7.5) }
        XCTAssertNil(SleepArchitectureEngine.evaluate(real + unstaged),
                     "Only 4 nights have a real stage split; the 6 unspecified-only nights must not pad that count to the 5-night minimum.")
    }

    func testSleepArchitectureAnchorsOnYourOwnRecentAverageNotJustTheAbsoluteBand() {
        // Both windows land inside the healthy band, but this recent
        // fortnight is a real step down from this person's own prior
        // month (deep 21.25%→16.25%, REM 23.75%→20%) — the personal
        // anchor must register that decline as a cost, not just check
        // the absolute band and call it a day.
        let now = Date()
        let recentStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-13 * 86_400)
        let recent = (0..<14).map { nightlyStages(daysFrom: recentStart, day: $0, deep: 1.3, rem: 1.6, core: 4.5, unspecified: 0.6) }
        guard let withoutHistory = SleepArchitectureEngine.evaluate(recent, now: now) else {
            XCTFail("Expected an assessment from the recent window alone.")
            return
        }
        XCTAssertFalse(withoutHistory.isPersonalized)

        let priorStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-40 * 86_400)
        let prior = (0..<15).map { nightlyStages(daysFrom: priorStart, day: $0, deep: 1.7, rem: 1.9, core: 4.4, unspecified: 0) }
        guard let withHistory = SleepArchitectureEngine.evaluate(recent + prior, now: now) else {
            XCTFail("Expected an assessment once prior-month history is present.")
            return
        }
        XCTAssertTrue(withHistory.isPersonalized)
        XCTAssertLessThan(withHistory.score, withoutHistory.score,
                          "A real decline against this person's own prior month must cost score even while still inside the absolute healthy band.")
    }

    func testSleepArchitectureNeverLetsAConsistentlyPoorPersonalBaselineRescueTheAbsoluteBandScore() {
        // The actual risk of anchoring on a personal average: someone
        // whose deep/REM has been chronically low every single night
        // would read as perfectly "on their own baseline" — the band
        // score must still dominate so a stable-but-poor pattern keeps
        // scoring poorly, not well for being consistent.
        let now = Date()
        let recentStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-13 * 86_400)
        let recent = (0..<14).map { nightlyStages(daysFrom: recentStart, day: $0, deep: 0.3, rem: 0.8, core: 5.5, unspecified: 0.4, awake: 1.2) }
        let priorStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-40 * 86_400)
        let prior = (0..<15).map { nightlyStages(daysFrom: priorStart, day: $0, deep: 0.3, rem: 0.8, core: 5.5, unspecified: 0.4, awake: 1.2) }
        guard let result = SleepArchitectureEngine.evaluate(recent + prior, now: now) else {
            XCTFail("Expected an assessment.")
            return
        }
        XCTAssertTrue(result.isPersonalized)
        XCTAssertLessThan(result.score, 55, "Being perfectly consistent with a chronically poor pattern must not read as a good score.")
    }

    func testSleepArchitectureDoesNotPersonalizeWithoutEnoughPriorHistory() {
        let now = Date()
        let recentStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-13 * 86_400)
        let recent = (0..<14).map { nightlyStages(daysFrom: recentStart, day: $0, deep: 1.3, rem: 1.6, core: 4.5, unspecified: 0.6) }
        let priorStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-40 * 86_400)
        // Only 5 prior nights — below the 10-night minimum.
        let thinPrior = (0..<5).map { nightlyStages(daysFrom: priorStart, day: $0, deep: 1.7, rem: 1.9, core: 4.4, unspecified: 0) }
        guard let result = SleepArchitectureEngine.evaluate(recent + thinPrior, now: now) else {
            XCTFail("Expected an assessment.")
            return
        }
        XCTAssertFalse(result.isPersonalized, "5 prior nights isn't enough to say anything about a personal baseline.")
    }

    func testLongevityIncludesASleepArchitectureDimensionOnceEnoughStagedNightsExist() {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let health = HealthStore()
        health.sleepStagesHistory = (0..<14).map { nightlyStages(daysFrom: start, day: $0, deep: 1.3, rem: 1.6, core: 4.5, unspecified: 0.6) }
        let index = LongevityEngine.calculate(health: health, imports: ImportStore())
        XCTAssertNotNil(index.dimensions.first(where: { $0.name == "Arquitectura del sueño" }))
    }

    func testLongevityOmitsSleepArchitectureDimensionWithoutEnoughStagedNights() {
        let health = HealthStore()
        XCTAssertNil(LongevityEngine.calculate(health: health, imports: ImportStore())
            .dimensions.first(where: { $0.name == "Arquitectura del sueño" }),
            "No sleep-stage history at all must not produce a dimension out of thin air.")
    }

    func testLongevityIncludesADailyStepsDimensionOnceEnoughHistoryExists() {
        // Steps were already being fetched from HealthKit and stored
        // (HealthStore.stepsHistory) but never fed into anything — not
        // shown, not scored. This is the "Actividad diaria" lever.
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-14 * 86_400)
        let health = HealthStore()
        health.stepsHistory = (0..<14).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: 10_000) }
        let index = LongevityEngine.calculate(health: health, imports: ImportStore())
        guard let steps = index.dimensions.first(where: { $0.name == "Actividad diaria" }) else {
            XCTFail("Expected an Actividad diaria dimension once 14 days of step history exist.")
            return
        }
        XCTAssertGreaterThanOrEqual(steps.score, 85, "Averaging the 10,000/day reference should score close to ideal.")
    }

    func testLongevityOmitsDailyStepsDimensionWithoutEnoughHistory() {
        let health = HealthStore()
        health.stepsHistory = (0..<3).map { TrendPoint(date: Date().addingTimeInterval(Double($0) * -86_400), value: 10_000) }
        let index = LongevityEngine.calculate(health: health, imports: ImportStore())
        XCTAssertNil(index.dimensions.first(where: { $0.name == "Actividad diaria" }),
                     "3 days of step history isn't enough to say anything real about a daily pattern.")
    }

    func testAnemiaRiskDimensionCatchesLowFerritinEvenWithANormalHemogram() {
        // Iron-deficiency without frank anemia — low ferritin, normal
        // hemogram — used to score a clean 100% on this dimension because
        // ferritin and transferrin saturation weren't part of it at all,
        // even though ImportStore already parses both.
        let date = Date()
        // persistToDisk: false — this asserts an exact marker count, so the
        // machine's own persisted lab history must not add to it (it made the
        // dimension read 7/8 instead of 4/5 here), and restore()'s save() must
        // not write these synthetic labs back over the real store.
        let imports = ImportStore(persistToDisk: false)
        imports.restore(workouts: [], labs: [
            labResult("Hemoglobina", 15, date: date, low: 13.0, high: 17.5),
            labResult("Hematocrito", 45, date: date, low: 40.0, high: 52.0),
            labResult("Hematíes", 5, date: date, low: 4, high: 6),
            labResult("Ferritina", 10, date: date, low: 30, high: 400),
            labResult("Saturación transferrina", 30, date: date, low: 20, high: 45),
        ])
        let index = LongevityEngine.calculate(health: HealthStore(), imports: imports)
        guard let anemia = index.dimensions.first(where: { $0.name == "Riesgo de anemia del deportista" }) else {
            XCTFail("Expected the anemia dimension once enough markers exist.")
            return
        }
        XCTAssertTrue(anemia.evidence.contains("4/5"), "Ferritina and saturación transferrina must be counted alongside the 3 hemogram markers: \(anemia.evidence)")
        // Only ferritina is out of range (10, below its 30 floor) — 4/5 in
        // range. Before this fix, the same hemogram alone would have
        // scored a clean 100%, hiding the one marker that actually matters.
        XCTAssertEqual(anemia.score, 80)
    }

    func testWellnessRecommendationBloodPressureMatchesLongevityEnginesOwnBands() {
        // Same bands LongevityEngine.bloodPressureScore already scores
        // against — "not optimal" must mean the same thing in both places.
        XCTAssertNil(WellnessRecommendationEngine.bloodPressure(systolic: 115, diastolic: 75), "Within the ideal band — no recommendation needed.")
        XCTAssertNotNil(WellnessRecommendationEngine.bloodPressure(systolic: 82, diastolic: 50), "Below the low-band threshold.")
        XCTAssertNotNil(WellnessRecommendationEngine.bloodPressure(systolic: 128, diastolic: 82), "Above the ideal band.")
        XCTAssertNotNil(WellnessRecommendationEngine.bloodPressure(systolic: 150, diastolic: 95), "Clearly elevated.")
    }

    func testWellnessRecommendationLabUsesTheLabsOwnReferenceRangeNotAHardcodedNumber() {
        XCTAssertNil(WellnessRecommendationEngine.lab(name: "LDL", status: "En rango"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "LDL", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "HDL", status: "Bajo"))
        XCTAssertNil(WellnessRecommendationEngine.lab(name: "HDL", status: "Alto"), "A high HDL isn't the problem HDL recommendations exist for.")
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Triglicéridos", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Hemoglobina glicada A1c", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Glucosa", status: "Alto"))
        // A lab this engine has no established direction for must never
        // get a fabricated recommendation.
        XCTAssertNil(WellnessRecommendationEngine.lab(name: "Urea", status: "Alto"))
    }

    func testWellnessRecommendationCoversTheNewBiomarkersAddedAfterComparingAgainstBevel() {
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Apolipoproteína B", status: "Alto"))
        XCTAssertNil(WellnessRecommendationEngine.lab(name: "Apolipoproteína B", status: "En rango"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Lipoproteína (a)", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Colesterol no-HDL", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Magnesio", status: "Bajo"))
        XCTAssertNil(WellnessRecommendationEngine.lab(name: "Magnesio", status: "Alto"), "No established lifestyle direction exists for high magnesium here.")
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Proteína C reactiva", status: "Alto"))
        XCTAssertNotNil(WellnessRecommendationEngine.lab(name: "Homocisteína", status: "Alto"))
    }

    func testWellnessRecommendationDoesNotConfuseNoHDLOrApoBWithTheirSubstringNeighbors() {
        // "no-HDL" contains "hdl" as a substring, and "Apolipoproteína B"
        // contains "lipoproteina" as a substring — both must resolve to
        // their OWN tip, not silently fall through to the wrong one.
        let noHDL = WellnessRecommendationEngine.lab(name: "Colesterol no-HDL", status: "Alto")
        XCTAssertNotNil(noHDL)
        XCTAssertTrue(noHDL!.contains("no-HDL"), "Got the plain HDL tip instead of the no-HDL one: \(noHDL!)")
        let apoB = WellnessRecommendationEngine.lab(name: "Apolipoproteína B", status: "Alto")
        XCTAssertNotNil(apoB)
        XCTAssertTrue(apoB!.contains("ApoB"), "Got the Lp(a) tip instead of the ApoB one: \(apoB!)")
    }

    func testTemperatureDeviationIsSignificantOnlyForARiseAtOrAboveTwoPercentOfHabitual() {
        // Same 2%-of-mean dead zone extendedSignalRow/trendCard already use
        // for this exact signal — a fall must never count as "significant
        // rise" regardless of magnitude, and a tiny rise below the zone
        // must not trigger a prompt.
        XCTAssertTrue(TemperatureDeviationInsightEngine.isSignificantRise(delta: 0.7, mean: 33.0))
        XCTAssertFalse(TemperatureDeviationInsightEngine.isSignificantRise(delta: 0.3, mean: 33.0))
        XCTAssertFalse(TemperatureDeviationInsightEngine.isSignificantRise(delta: -0.9, mean: 33.0))
    }

    func testTemperatureDeviationBreakdownCountsOnlyAnsweredLogsAndSortsByFrequency() {
        let logs = [
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.alcohol], note: ""),
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.5, reasons: [.alcohol, .hardSession], note: ""),
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.4, reasons: [], note: "sin etiquetar"),
        ]
        let breakdown = TemperatureDeviationInsightEngine.breakdown(logs)
        XCTAssertEqual(breakdown.first?.reason, .alcohol)
        XCTAssertEqual(breakdown.first?.count, 2)
        XCTAssertEqual(breakdown.first?.percentage, 100, "2 of 2 answered logs mention alcohol.")
        XCTAssertEqual(breakdown.first(where: { $0.reason == .hardSession })?.count, 1)
    }

    func testTemperatureDeviationHeadlineHedgesBelowThreeAnsweredEpisodes() {
        let single = [TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.hardSession], note: "")]
        let headline = TemperatureDeviationInsightEngine.headline(single)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline!.contains("pocos registros"), "Must hedge with so few episodes: \(headline!)")
    }

    func testTemperatureDeviationHeadlineNamesADominantReasonAtFiftyPercentOrAbove() {
        let logs = (0..<4).map { i in
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6,
                                     reasons: i < 3 ? [.alcohol] : [.heat], note: "")
        }
        let headline = TemperatureDeviationInsightEngine.headline(logs)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline!.contains("alcohol"), "75% alcohol should be named as the dominant reason: \(headline!)")
    }

    func testTemperatureDeviationHeadlineNamesTheSpreadWhenNoReasonDominates() {
        let logs: [TemperatureDeviationLog] = [
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.alcohol], note: ""),
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.heat], note: ""),
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.hardSession], note: ""),
            TemperatureDeviationLog(id: UUID(), date: Date(), deviationC: 0.6, reasons: [.stress], note: ""),
        ]
        let headline = TemperatureDeviationInsightEngine.headline(logs)
        XCTAssertNotNil(headline)
        XCTAssertTrue(headline!.contains("no hay una causa dominante"), "No reason reaches 50%, must say so: \(headline!)")
    }

    func testTemperatureDeviationStoreKeysLogsByCalendarDayAndDropsEmptyAnswers() {
        let store = TemperatureDeviationStore.shared
        let originalLogs = store.logs
        defer { store.restore(originalLogs) } // best-effort cleanup; restore replaces matching ids only
        let today = Date()
        store.save(TemperatureDeviationLog(id: UUID(), date: today, deviationC: 0.6, reasons: [.alcohol], note: ""))
        XCTAssertEqual(store.existingLog(for: today)?.reasons, [.alcohol])
        // Re-saving the same day with an empty answer must clear it, not
        // leave a stale row with an empty reasons set sitting in `logs`.
        let sameDayLater = Calendar.current.date(byAdding: .hour, value: 3, to: today) ?? today
        store.save(TemperatureDeviationLog(id: UUID(), date: sameDayLater, deviationC: 0, reasons: [], note: ""))
        XCTAssertNil(store.existingLog(for: today))
    }

    func testLabCategoryGroupsKnownMarkersIntoTheirClinicalSection() {
        XCTAssertEqual(LabCategory.of("Hemoglobina"), .hemograma)
        XCTAssertEqual(LabCategory.of("Colesterol LDL"), .lipidico)
        XCTAssertEqual(LabCategory.of("Apolipoproteína B"), .lipidico)
        XCTAssertEqual(LabCategory.of("GOT"), .hepatico)
        XCTAssertEqual(LabCategory.of("Creatinina"), .renal)
        XCTAssertEqual(LabCategory.of("Ferritina"), .hierro)
        XCTAssertEqual(LabCategory.of("Vitamina D"), .vitaminas)
        XCTAssertEqual(LabCategory.of("TSH"), .hormonal)
        XCTAssertEqual(LabCategory.of("Proteína C reactiva"), .inflamacion)
        XCTAssertEqual(LabCategory.of("PSA total"), .tumorales)
        XCTAssertEqual(LabCategory.of("IMC"), .vitales)
    }

    func testLabCategoryFallsBackToOtrosForAnUnrecognizedMarkerNameInsteadOfMisfilingIt() {
        // A future ImportStore regex pattern added without a matching
        // LabCategory entry must land somewhere honest ("Otros"), not get
        // silently absorbed into an unrelated section.
        XCTAssertEqual(LabCategory.of("Un marcador nuevo que no existe todavía"), .otros)
    }

    func testLabCategoryGroupedFollowsTheClinicalDisplayOrderAndDropsEmptyCategories() {
        // Deliberately scrambled input order and duplicate categories
        // (two hemograma markers) to prove `grouped` imposes its own
        // fixed clinical order rather than preserving input order, and
        // never emits a category with zero members.
        let names = ["PSA total", "Hemoglobina", "TSH", "Hematocrito", "Colesterol LDL"]
        let groups = LabCategory.grouped(names, name: { $0 })
        let categoriesPresent = groups.map(\.0)
        XCTAssertEqual(categoriesPresent, [.hemograma, .lipidico, .hormonal, .tumorales],
                       "Must follow LabCategory.displayOrder, not input order.")
        XCTAssertTrue(groups.allSatisfy { !$0.1.isEmpty }, "No category should appear with an empty group.")
        let hemogramaGroup = groups.first { $0.0 == .hemograma }?.1
        XCTAssertEqual(hemogramaGroup?.sorted(), ["Hematocrito", "Hemoglobina"])
    }

    func testLabRegexExtractsTheSixMarkersAddedAfterComparingAgainstBevel() {
        let text = """
        APOLIPOPROTEINA B          105          mg/dL     [45-105]
        LIPOPROTEINA (A)           18           mg/dL
        COLESTEROL NO-HDL          142          mg/dL
        MAGNESIO                   1.9          mg/dL
        PROTEINA C REACTIVA        6.2          mg/L
        HOMOCISTEINA               12.1         umol/L
        """
        let results = Dictionary(uniqueKeysWithValues: ImportStore.extractLabResultsForTesting(from: text, date: Date()).map { ($0.name, $0) })
        XCTAssertEqual(results["Apolipoproteína B"]?.value, 105)
        // The lab's own inline range [45-105] must win over the 90 fallback.
        XCTAssertEqual(results["Apolipoproteína B"]?.high, 105)
        XCTAssertEqual(results["Lipoproteína (a)"]?.value, 18)
        XCTAssertEqual(results["Colesterol no-HDL"]?.value, 142)
        XCTAssertEqual(results["Magnesio"]?.value, 1.9)
        XCTAssertEqual(results["Proteína C reactiva"]?.value, 6.2)
        XCTAssertEqual(results["Homocisteína"]?.value, 12.1)
    }

    func testLabRegexStillMatchesCommonAbbreviatedLabelVariants() {
        let text = """
        APO B                      88           mg/dL
        LP(a)                      45           mg/dL
        """
        let results = Dictionary(uniqueKeysWithValues: ImportStore.extractLabResultsForTesting(from: text, date: Date()).map { ($0.name, $0) })
        XCTAssertEqual(results["Apolipoproteína B"]?.value, 88)
        XCTAssertEqual(results["Lipoproteína (a)"]?.value, 45)
    }

    func testWellnessRecommendationVO2MaxAndBodyFatOnlyFireOutsideTheirBand() {
        XCTAssertNil(WellnessRecommendationEngine.vo2Max(45))
        XCTAssertNotNil(WellnessRecommendationEngine.vo2Max(28))
        XCTAssertNil(WellnessRecommendationEngine.bodyFatPercentage(18))
        XCTAssertNotNil(WellnessRecommendationEngine.bodyFatPercentage(35))
        XCTAssertNotNil(WellnessRecommendationEngine.bodyFatPercentage(5))
    }

    func testLightSwimTodayDoesNotBlockTheRestOfTheDaysPlan() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        // 10×100 m technique swim, ~15 min including rest — real, but not
        // remotely the same as "already trained today" in any load sense.
        let lightSwim = healthWorkout(activity: "Natación", kilometers: 1.0, minutes: 15, date: now.addingTimeInterval(-30 * 60))
        health.recentWorkouts = [lightSwim]
        let status = TrainingPlanEngine.status(health: health, imports: imports, readiness: 80, muscles: [],
                                               checkIn: nil, context: neutralContext, physiologicalAlert: nil, now: now)
        XCTAssertNotEqual(status.rationale, "Ya has entrenado hoy. La recomendación se centra ahora en asimilar esa carga.")
    }

    func testAlreadyTrainedTodayFlagCoversHIITNotJustUpperBodyStrength() {
        // The week strip's day chip used to only recognize "already
        // trained today" by string-matching the "tren superior" rationale
        // phrase — a completed HIIT session (or anything else routing into
        // the generic "ya has entrenado hoy" fallback below) read as an
        // ordinary, unaccounted-for rest day instead of showing as done.
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let hiit = healthWorkout(activity: "Intervalos de alta intensidad", kilometers: 0, minutes: 20, date: now.addingTimeInterval(-90 * 60))
        health.recentWorkouts = [hiit]
        let status = TrainingPlanEngine.status(health: health, imports: imports, readiness: 80, muscles: [],
                                               checkIn: nil, context: neutralContext, physiologicalAlert: nil, now: now)
        XCTAssertEqual(status.nextSession, .recovery)
        XCTAssertFalse(status.rationale.localizedCaseInsensitiveContains("tren superior"),
                       "This must be the generic 'ya has entrenado hoy' fallback, not the upper-body-specific branch.")
        XCTAssertTrue(status.alreadyTrainedToday,
                      "A completed HIIT session must still be flagged as already-trained-today, even though it isn't the upper-body-strength-specific case.")

        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        XCTAssertEqual(week[0].alreadyTrainedToday, status.alreadyTrainedToday,
                       "weekAhead's own real (non-simulated) first day must carry the same flag status() itself computed.")
    }

    func testSubstantialSwimTodayStillTriggersTheAlreadyTrainedGate() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let realSwim = healthWorkout(activity: "Natación", kilometers: 2.5, minutes: 45, date: now.addingTimeInterval(-60 * 60))
        health.recentWorkouts = [realSwim]
        let status = TrainingPlanEngine.status(health: health, imports: imports, readiness: 80, muscles: [],
                                               checkIn: nil, context: neutralContext, physiologicalAlert: nil, now: now)
        XCTAssertEqual(status.nextSession, .recovery)
        XCTAssertEqual(status.rationale, "Ya has entrenado hoy. La recomendación se centra ahora en asimilar esa carga.")
    }

    func testQualityRunIsNotLockedOutOnceTheRawRunCountQuotaIsMet() {
        // Weekly run *count* already met (runDeficit = 0) with nothing but
        // easy runs so far — quality was previously nested inside
        // `runDeficit > 0`, so hitting the count target this way used to
        // permanently rule quality out for the rest of the week even
        // though qualityDeficit is clearly still > 0 here.
        let focus = GoalTrainingFocus(running: 0.6, strength: 0.2, hybrid: 0, triathlon: 0, leadingGoal: "Media maratón")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 0, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 200, hoursSinceQuality: 200,
            lateWeek: false, readiness: 75, muscles: muscles(legs: 75), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .qualityRun)
    }

    func testLongRunIsNotLockedOutOnceTheRawRunCountQuotaIsMet() {
        let focus = GoalTrainingFocus(running: 0.6, strength: 0.2, hybrid: 0, triathlon: 0, leadingGoal: "Media maratón")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 200, hoursSinceQuality: 200,
            lateWeek: true, readiness: 75, muscles: muscles(legs: 75), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .longRun)
    }

    func testBalancedDecisionOffersLightMaintenanceInsteadOfForcedRestWhenQuotasAreMet() {
        // Every weekly target already met, nothing overdue — the exact
        // "ya cumples los mínimos" case that used to default straight to
        // .recovery every time, which read as "descanso obligatorio toda
        // la semana" once it repeated across several days of the week-
        // ahead forecast, even with high readiness and fresh legs.
        let focus = GoalTrainingFocus(running: 0.5, strength: 0.3, hybrid: 0, triathlon: 0, leadingGoal: "Media maratón")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
            lateWeek: false, readiness: 88, muscles: muscles(legs: 88), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .easyRun)
        XCTAssertTrue(decision.rationale.localizedCaseInsensitiveContains("no hay nada obligatorio"))
    }

    func testBalancedDecisionStillFallsBackToRecoveryWithGenuinelyFatiguedLegs() {
        let focus = GoalTrainingFocus(running: 0.5, strength: 0.3, hybrid: 0, triathlon: 0, leadingGoal: "Media maratón")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
            lateWeek: false, readiness: 88, muscles: muscles(legs: 30), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .recovery)
    }

    func testDaysSinceLastSessionMatchesTheTrackedLiftsOwnNameNotAnyStrengthSession() {
        let now = Date()
        // Bench press was trained 12 days ago; a totally unrelated "Remo con
        // barra" (row) session happened yesterday. daysSinceStrength alone
        // would read this as "trained yesterday" — this function must look
        // past that and match on the tracked lift's own exercise name.
        let workouts = [
            ImportedWorkout(title: "Empuje", start: now.addingTimeInterval(-12 * 86_400),
                            end: now.addingTimeInterval(-12 * 86_400 + 3_600),
                            exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000,
                                                         totalReps: 32, averageWeight: 100, setDetails: nil)],
                            muscleSets: ["Pecho": 4]),
            ImportedWorkout(title: "Tirón", start: now.addingTimeInterval(-1 * 86_400), end: now,
                            exercises: [ImportedExercise(name: "Remo con barra", sets: 4, volume: 2_000,
                                                         totalReps: 32, averageWeight: 60, setDetails: nil)],
                            muscleSets: ["Espalda": 4])
        ]
        let days = StrengthProgressEngine.daysSinceLastSession(matchingTerms: ["bench press", "press banca"], in: workouts, now: now)
        XCTAssertEqual(days ?? -1, 12, accuracy: 0.01)
    }

    func testDaysSinceLastSessionReturnsNilWhenTheTrackedLiftHasNeverBeenLogged() {
        let now = Date()
        let workouts = [
            ImportedWorkout(title: "Tirón", start: now.addingTimeInterval(-1 * 86_400), end: now,
                            exercises: [ImportedExercise(name: "Remo con barra", sets: 4, volume: 2_000,
                                                         totalReps: 32, averageWeight: 60, setDetails: nil)],
                            muscleSets: ["Espalda": 4])
        ]
        XCTAssertNil(StrengthProgressEngine.daysSinceLastSession(matchingTerms: ["bench press", "press banca"], in: workouts, now: now))
    }

    func testStaleTrackedLiftAloneNoLongerReopensTheGateOrFallbackOnItsOwn() {
        // Superseded design, kept as a regression guard: an earlier version
        // of this fix let trackedLiftDaysSince alone reopen the strength
        // gate/fallback even with the count-based quota already met and
        // daysSinceStrength fresh. That looked right for a single real
        // "what today" call, but trackedLiftDaysSince never resets inside
        // weekAhead's forward simulation — so it kept re-winning literally
        // every remaining day of the week, the actual mechanism behind a
        // real week collapsing to all-strength/zero-running. The correct
        // place for tracked-lift urgency to act is upstream, in the MED
        // floor that sizes targetStrength itself (status()'s
        // trackedLiftMinimumSessions) — not this gate.
        let focus = GoalTrainingFocus(running: 0.3, strength: 0.5, hybrid: 0, triathlon: 0, leadingGoal: "Press banca")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 1, targetStrength: 1, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
            trackedLiftDaysSince: 12,
            lateWeek: false, readiness: 80, muscles: muscles(legs: 80), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .easyRun)
    }

    func testGenericStrengthAloneDoesNotProposeStrengthWithoutAStaleTrackedLift() {
        // Same shape as above but with no tracked-lift signal at all — the
        // contrast case, confirming the new gate is additive, not always-on.
        let focus = GoalTrainingFocus(running: 0.3, strength: 0.5, hybrid: 0, triathlon: 0, leadingGoal: "Press banca")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 1, targetStrength: 1, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
            trackedLiftDaysSince: nil,
            lateWeek: false, readiness: 80, muscles: muscles(legs: 80), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .easyRun)
    }

    func testStaleTrackedLiftDoesNotMonopolizeTheWeekOnceStrengthQuotaIsAlreadyMet() {
        // trackedLiftDaysSince deliberately never resets within weekAhead's
        // forward simulation (a generic .strength day can't tell the model
        // which specific lift it addressed) — before this fix that alone
        // sat in the entry gate's OR, so once a tracked lift was genuinely
        // stale it kept reopening the strength candidate on literally
        // every simulated day, even with the week's own strength quota
        // (already sized for both tracked lifts by the MED floor) fully
        // met and daysSinceStrength freshly reset — the concrete mechanism
        // behind a week-ahead forecast collapsing to all-strength/zero-
        // running. The count-based deficit must now be the sufficient gate.
        let focus = GoalTrainingFocus(running: 0.35, strength: 0.45, hybrid: 0.2, triathlon: 0, leadingGoal: "Press banca")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 3, targetRuns: 4, strength: 4, targetStrength: 4, quality: 1, targetQuality: 1,
            daysSinceStrength: 0, hoursSinceLong: 168, hoursSinceQuality: 96,
            trackedLiftDaysSince: 45,
            lateWeek: false, readiness: 80, muscles: muscles(legs: 80), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .easyRun,
                       "Strength's own quota is met and it was trained yesterday (daysSinceStrength: 0) — an oversized, non-resetting staleness number must not still win the day over the only outstanding running deficit.")
    }

    func testWeekAheadStillIncludesRunningWhenTwoProgressingLiftsCompeteWithThreeRunningGoals() {
        // The exact reported shape: bench press and squat both moved to a
        // "progressing" tier (2x/week each = 4 dedicated strength slots)
        // alongside three concurrent running-type goals in a small
        // training week — a real capacity conflict that used to be
        // resolved by unconditionally shrinking running down to a bare
        // floor of 1 to make room for the strength floor, collapsing the
        // whole week to strength with zero running.
        //
        // PR1.5: profile is constructed locally and passed directly below,
        // so there's nothing left for GoalStore.shared.save to exercise.
        // ImportStore(persistToDisk: false) instead of a plain ImportStore()
        // — the previous version still read this machine's real,
        // disk-persisted Hevy history despite passing profile explicitly,
        // confirmed to fail identically on main before PR1 for that reason.
        // With that real history gone, a genuinely empty history tripped a
        // DIFFERENT real gate instead — today's real proposed session read
        // as a huge acute:chronic spike against zero prior training and
        // vetoed the rest of the week — so healthBaseline/importBaseline
        // below seed 8 weeks of an ordinary running + lifting routine
        // first, the same way an athlete who actually trains regularly
        // would never present a bare, empty history.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil, targetValue: 100, unit: "kg", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .squat, title: "Sentadilla", date: nil, targetValue: 120, unit: "kg", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .fiveK, title: "5K", date: nil, targetValue: 20, unit: "min", priority: .primary, isActive: true)
        ]
        profile.trainingDaysPerWeek = 5

        let now = Date()
        let health = HealthStore()
        let imports = ImportStore(persistToDisk: false)
        var healthBaseline: [HealthWorkout] = []
        var importBaseline: [ImportedWorkout] = []
        for weekOffset in 1...8 {
            let runDay = now.addingTimeInterval(-Double(weekOffset) * 7 * 86_400 - 2 * 3_600)
            healthBaseline.append(healthWorkout(activity: "Carrera", kilometers: 6, minutes: 35, date: runDay))
            let liftDay = now.addingTimeInterval(-Double(weekOffset) * 7 * 86_400 - 5 * 3_600)
            importBaseline.append(ImportedWorkout(
                title: "Empuje/Pierna", start: liftDay, end: liftDay.addingTimeInterval(3_600),
                exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 1_600, totalReps: 32, averageWeight: 50, setDetails: nil),
                           ImportedExercise(name: "Squat (Barbell)", sets: 4, volume: 1_600, totalReps: 32, averageWeight: 50, setDetails: nil)],
                muscleSets: ["Pecho": 4, "Cuádriceps": 4]
            ))
        }
        health.recentWorkouts = healthBaseline
        imports.restore(workouts: importBaseline, labs: [])

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: context, now: now)
        let runningKinds: Set<PlannedSessionKind> = [.easyRun, .qualityRun, .longRun]
        XCTAssertTrue(week.contains { runningKinds.contains($0.kind) },
                     "Three active running-type goals must still get real representation across the week, even while two tracked lifts genuinely need their own dedicated slots.")
    }

    func testTargetQualityStaysEnabledEvenWhenFairnessTrimmingLowersTargetRunsBelowThree() {
        // Two tracked lifts each needing their own floor can fairly trim
        // targetRuns down to 1-2 for THIS week's count/scoring purposes —
        // that trim is about weekly capacity, not about running suddenly
        // being a minor part of the plan. Gating targetQuality on the
        // post-trim targetRuns silently zeroed it (and permanently blocked
        // quality-run from ever being proposed, no matter how overdue)
        // purely because of an unrelated strength-side squeeze.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil, targetValue: 100, unit: "kg", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .squat, title: "Sentadilla", date: nil, targetValue: 120, unit: "kg", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .fiveK, title: "5K", date: nil, targetValue: 20, unit: "min", priority: .primary, isActive: true)
        ]
        profile.trainingDaysPerWeek = 5

        let status = TrainingPlanEngine.status(health: HealthStore(), imports: ImportStore(), readiness: 80, muscles: [],
                                               checkIn: nil, context: TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                                                                  calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                               physiologicalAlert: nil, now: Date())
        XCTAssertLessThan(status.targetRuns, 3, "Sanity check: this scenario must actually trigger the fairness trim below 3, or the test proves nothing.")
        XCTAssertGreaterThan(status.targetQuality, 0,
                             "Quality-run must stay enabled based on the plan's real running demand, not get silently zeroed by an unrelated strength-side capacity trim.")
    }

    func testHypertrophyGoalContributesStrengthFocusAndGetsAMinimumWeeklyFloor() {
        // Hypertrophy isn't a tracked lift (no single 1RM to protect), but
        // Schoenfeld et al.'s frequency meta-analysis still calls for
        // ≥2x/week per muscle group — its own real floor, distinct from
        // the tracked-lift one.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [
            TrainingGoal(id: UUID(), kind: .hypertrophy, title: "Hipertrofia", date: nil, targetValue: nil, unit: "", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil, targetValue: nil, unit: "min", priority: .secondary, isActive: true)
        ]
        profile.trainingDaysPerWeek = 5

        let focus = TrainingPlanEngine.goalFocus(for: profile, on: Date())
        XCTAssertGreaterThan(focus.strength, 0, "An active hypertrophy goal must contribute to strength focus the same way a tracked lift or HYROX's strength share does.")

        let status = TrainingPlanEngine.status(health: HealthStore(), imports: ImportStore(), readiness: 80, muscles: [],
                                               checkIn: nil, context: TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                                                                  calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                               physiologicalAlert: nil, now: Date())
        XCTAssertGreaterThanOrEqual(status.targetStrength, 2)
    }

    func testAlreadyCompletedUpperBodyDayTodayIsDetectedFromHevyAlone() {
        // healthWorkouts (used for "already trained today") deliberately
        // excludes anything Hevy-sourced or Hevy-mirrored — a real,
        // decent-volume push day logged ONLY in Hevy used to be completely
        // invisible to that check, letting the plan propose a fresh hard
        // session (e.g. a long run) as if today were still untouched.
        let imports = ImportStore()
        let now = Date()
        let pushToday = ImportedWorkout(title: "Push", start: now.addingTimeInterval(-3 * 3_600), end: now.addingTimeInterval(-3 * 3_600 + 45 * 60),
                                        exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000,
                                                                     totalReps: 32, averageWeight: 100, setDetails: nil)],
                                        muscleSets: ["Pecho": 4, "Hombros": 3, "Tríceps": 3])
        imports.restore(workouts: [pushToday], labs: [])
        // ImportStore persists to disk — a "today"-dated entry (unlike the
        // fixed historical dates other tests use) would otherwise leak into
        // every later test's own fresh ImportStore() this same run and get
        // misread as real "already trained today" history.
        defer { imports.deleteWorkout(id: pushToday.id) }

        let status = TrainingPlanEngine.status(health: HealthStore(), imports: imports, readiness: 80,
                                               muscles: [], checkIn: nil, context: neutralContext, physiologicalAlert: nil, now: now)
        XCTAssertEqual(status.nextSession, .recovery)
        XCTAssertTrue(status.rationale.localizedCaseInsensitiveContains("tren superior"),
                      "A push day (no leg involvement) must be recognized as such, not folded into the generic 'already trained today' message.")
    }

    func testAlreadyCompletedLegDayTodayKeepsTheGenericRecoveryMessage() {
        let imports = ImportStore()
        let now = Date()
        let legsToday = ImportedWorkout(title: "Pierna", start: now.addingTimeInterval(-3 * 3_600), end: now.addingTimeInterval(-3 * 3_600 + 45 * 60),
                                        exercises: [ImportedExercise(name: "Squat (Barbell)", sets: 4, volume: 4_000,
                                                                     totalReps: 32, averageWeight: 100, setDetails: nil)],
                                        muscleSets: ["Cuádriceps": 4, "Glúteos": 3])
        imports.restore(workouts: [legsToday], labs: [])
        defer { imports.deleteWorkout(id: legsToday.id) }

        let status = TrainingPlanEngine.status(health: HealthStore(), imports: imports, readiness: 80,
                                               muscles: [], checkIn: nil, context: neutralContext, physiologicalAlert: nil, now: now)
        XCTAssertEqual(status.nextSession, .recovery)
        XCTAssertFalse(status.rationale.localizedCaseInsensitiveContains("tren superior"),
                       "A leg day must not be offered the upper-body-day alternative — legs aren't fresh.")
    }

    func testWorkoutPlannerOffersARunAlternativeAfterAnUpperBodyDayAlreadyDoneToday() {
        // PR2: propose() no longer reads GoalStore.shared — profile is
        // constructed locally and passed via context below.
        var profile = AthletePlanProfile.angelDefault
        // The run alternative is now also gated on the athlete actually
        // having a running-type goal — a coach wouldn't prescribe a run to
        // someone whose plan has nothing to do with running.
        profile.goals = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil,
                                      targetValue: nil, unit: "min", priority: .primary, isActive: true)]

        let imports = ImportStore()
        let now = Date()
        // 6h ago, well past the real >=3h spacing gate the run
        // alternative is now conditioned on (see hoursSincePush in
        // WorkoutPlanner) — not a guessed "3-4h" range applied blindly.
        let pushToday = ImportedWorkout(title: "Push", start: now.addingTimeInterval(-6 * 3_600), end: now.addingTimeInterval(-6 * 3_600 + 45 * 60),
                                        exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000,
                                                                     totalReps: 32, averageWeight: 100, setDetails: nil)],
                                        muscleSets: ["Pecho": 4, "Hombros": 3, "Tríceps": 3])
        imports.restore(workouts: [pushToday], labs: [])
        defer { imports.deleteWorkout(id: pushToday.id) }

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let workout = WorkoutPlanner.propose(health: HealthStore(), imports: imports, checkIn: nil, context: context, now: now)
        // Only assert the enriched shape once readiness/recovery actually
        // routed here for this reason — a real assessed score could in
        // principle still fall elsewhere depending on other live signals.
        guard workout.title.localizedCaseInsensitiveContains("tren superior") else { return }
        XCTAssertTrue(workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("carrera") },
                      "A real Z2 run alternative must be offered, not just descanso, once a push day is confirmed leg-free and running is part of the plan.")
    }

    func testWorkoutPlannerNeverSuggestsARunWithoutARunningGoal() {
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil,
                                      targetValue: 100, unit: "kg", priority: .primary, isActive: true)]

        let imports = ImportStore()
        let now = Date()
        let pushToday = ImportedWorkout(title: "Push", start: now.addingTimeInterval(-6 * 3_600), end: now.addingTimeInterval(-6 * 3_600 + 45 * 60),
                                        exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000,
                                                                     totalReps: 32, averageWeight: 100, setDetails: nil)],
                                        muscleSets: ["Pecho": 4, "Hombros": 3, "Tríceps": 3])
        imports.restore(workouts: [pushToday], labs: [])
        defer { imports.deleteWorkout(id: pushToday.id) }

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let workout = WorkoutPlanner.propose(health: HealthStore(), imports: imports, checkIn: nil, context: context, now: now)
        guard workout.title.localizedCaseInsensitiveContains("tren superior") else { return }
        XCTAssertFalse(workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("carrera") },
                       "With no running-type goal in the plan at all, a run has nothing to justify recommending it.")
    }

    func testWorkoutPlannerWithholdsTheRunAlternativeWhenNotEnoughRealHoursHavePassed() {
        // The alternative must be gated on real elapsed time since the
        // actual session, not offered unconditionally as fixed text —
        // 1h post-session is nowhere near the real spacing this needs.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil,
                                      targetValue: nil, unit: "min", priority: .primary, isActive: true)]

        let imports = ImportStore()
        let now = Date()
        let pushToday = ImportedWorkout(title: "Push", start: now.addingTimeInterval(-1 * 3_600), end: now.addingTimeInterval(-1 * 3_600 + 45 * 60),
                                        exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000,
                                                                     totalReps: 32, averageWeight: 100, setDetails: nil)],
                                        muscleSets: ["Pecho": 4, "Hombros": 3, "Tríceps": 3])
        imports.restore(workouts: [pushToday], labs: [])
        defer { imports.deleteWorkout(id: pushToday.id) }

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let workout = WorkoutPlanner.propose(health: HealthStore(), imports: imports, checkIn: nil, context: context, now: now)
        guard workout.title.localizedCaseInsensitiveContains("tren superior") else { return }
        XCTAssertFalse(workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("carrera") },
                       "Only ~1h has passed since the push session — the run alternative must not be offered yet.")
    }

    func testFallbackNoLongerLetsAPersistentTrackedLiftSignalWinEveryRemainingDay() {
        // Superseded design, kept as a regression guard (mirrors
        // testStaleTrackedLiftAloneNoLongerReopensTheGateOrFallbackOnItsOwn
        // for this second call site): with strength's own quota already met
        // and daysSinceStrength fresh (2), the "nothing mandatory" fallback
        // must rotate toward whichever goal actually has running room —
        // trackedLiftDaysSince doesn't reset within weekAhead's forward
        // simulation, so letting it win this branch too meant every
        // remaining "nothing mandatory" day of the week also went to
        // strength, not just the days the main gate legitimately claimed.
        let focus = GoalTrainingFocus(running: 0.5, strength: 0.3, hybrid: 0, triathlon: 0, leadingGoal: "Press banca")
        let decision = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, hoursSinceLong: 168, hoursSinceQuality: 96,
            trackedLiftDaysSince: 8,
            lateWeek: false, readiness: 88, muscles: muscles(legs: 88), goalFocus: focus
        )
        XCTAssertEqual(decision.kind, .easyRun)
    }

    func testRecommendationPrefersUrgentLiftPatternWhenItsOwnMuscleGroupIsFresh() {
        let muscles = ["Cuádriceps", "Glúteos", "Isquios", "Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Core", "Gemelos"]
            .map { MuscleReadiness(name: $0, readiness: 90, lastTrained: nil, recentSets: 0) }
        XCTAssertEqual(TwinEngine.recommendation(score: 75, muscles: muscles, urgentPattern: "Empuje"), "Empuje")
    }

    func testRecommendationSafetyCheckDoesNotOverrideWhenUrgentPatternMuscleIsFatigued() {
        // The urgent tracked-lift pattern must never win over a genuinely
        // fatigued muscle group — urgency is about not letting an unrelated
        // pattern quietly satisfy the quota, not about ignoring readiness.
        let muscles = ["Cuádriceps", "Glúteos", "Isquios", "Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Core", "Gemelos"]
            .map { name -> MuscleReadiness in
                let readiness = ["Pecho", "Hombros", "Tríceps"].contains(name) ? 40 : 90
                return MuscleReadiness(name: name, readiness: readiness, lastTrained: nil, recentSets: 0)
            }
        let result = TwinEngine.recommendation(score: 75, muscles: muscles, urgentPattern: "Empuje")
        XCTAssertNotEqual(result, "Empuje")
        XCTAssertNotEqual(result, "Empuje ligero")
    }

    func testTrackedLiftMinimumDoseGuaranteesBothMaintenanceLiftsTheirOwnWeeklySlot() {
        // Three running-leaning goals (all Principal) diluting the blended
        // strength demand down to a single weekly slot for BOTH tracked
        // lifts combined — the exact "100 kg de press banca en objetivo de
        // mantenimiento... dudo que eso se pueda mantener" shape. Each
        // maintenance-tier tracked lift needs its own slot regardless of
        // how the portfolio blend blurs them together.
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil, targetValue: 100, unit: "kg", priority: .maintenance, isActive: true),
            TrainingGoal(id: UUID(), kind: .squat, title: "Sentadilla", date: nil, targetValue: 120, unit: "kg", priority: .maintenance, isActive: true),
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX", date: nil, targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .fiveK, title: "5K", date: nil, targetValue: 20, unit: "min", priority: .primary, isActive: true)
        ]
        profile.trainingDaysPerWeek = 4

        let status = TrainingPlanEngine.status(health: HealthStore(), imports: ImportStore(), readiness: 80, muscles: [],
                                               checkIn: nil, context: TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                                                                  calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                               physiologicalAlert: nil, now: Date())
        XCTAssertGreaterThanOrEqual(status.targetStrength, 2,
                                    "Two maintenance-tier tracked lifts each need their own minimum weekly dose, not a shared single slot the blended demand alone would produce.")
    }

    func testGymPinsTheTrackedLiftEvenWhenAFresherVariationWouldOtherwiseRankFirst() {
        let originalProfile = GoalStore.shared.profile
        defer { GoalStore.shared.save(originalProfile) }
        var profile = originalProfile
        profile.goals = [TrainingGoal(id: UUID(), kind: .benchPress, title: "Banca", date: nil,
                                      targetValue: 100, unit: "kg", priority: .maintenance, isActive: true)]
        GoalStore.shared.save(profile)

        let imports = ImportStore()
        let now = Date()
        // "Press militar" trained more recently than "Bench Press
        // (Barbell)" — with identical (unmeasured) muscle-group readiness,
        // freshness-tie sorting alone would rank the more recent variation
        // first and could silently keep bench press off today's list.
        let recent = ImportedWorkout(title: "Empuje", start: now.addingTimeInterval(-2 * 86_400), end: now.addingTimeInterval(-2 * 86_400 + 3_600),
                                    exercises: [ImportedExercise(name: "Press militar", sets: 3, volume: 1_200, totalReps: 24, averageWeight: 50, setDetails: nil)],
                                    muscleSets: ["Hombros": 3])
        let older = ImportedWorkout(title: "Empuje", start: now.addingTimeInterval(-9 * 86_400), end: now.addingTimeInterval(-9 * 86_400 + 3_600),
                                    exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 4_000, totalReps: 32, averageWeight: 100, setDetails: nil)],
                                    muscleSets: ["Pecho": 4])
        imports.restore(workouts: [recent, older], labs: [])

        let workout = WorkoutPlanner.gym(for: "Empuje", imports: imports, light: false, muscles: [])
        XCTAssertEqual(workout.exercises.first?.name, "Bench Press (Barbell)",
                       "The tracked lift must be pinned first, not displaced by a more recently trained equivalent variation.")
    }

    // PR2 integration: assess() actually wires physiology/readout/
    // predictedTomorrow through step()/TwinPhysiology.derive, not just the
    // pure functions tested in isolation above.
    func testAssessComputesPhysiologyReadoutAndPredictedTomorrow() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)

        XCTAssertEqual(assessment.readout.score, assessment.score, "readout is the same real score assess() already computes, just formally typed.")
        XCTAssertEqual(assessment.readout.state, assessment.state)
        XCTAssertGreaterThanOrEqual(assessment.predictedTomorrow.score, 0)
        XCTAssertLessThanOrEqual(assessment.predictedTomorrow.score, 100)
        // Same conversion physiology.derive uses: fatigue = 100 - readiness.
        XCTAssertEqual(assessment.physiology.muscleFatigue["Espalda"], Double(100 - (assessment.muscles.first { $0.name == "Espalda" }?.readiness ?? 100)))
    }

    func testTwinEngineMuscleFatigueRespondsToWatchOnlyStrengthSession() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let baseline = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        XCTAssertEqual(baseline.muscles.first { $0.name == "Espalda" }?.readiness, 100,
                       "With no history at all, every muscle should read fully fresh.")

        // A back session logged only on the Watch (no Hevy import) — the
        // exact scenario that used to contribute zero fatigue anywhere,
        // because HealthStore.muscles() returned [:] for strength-training
        // activity types.
        let backSession = healthWorkout(activity: "Fuerza", kilometers: 0, minutes: 20, date: now.addingTimeInterval(-18 * 3_600),
                                        muscleGroups: ["Pecho": 0.4, "Espalda": 0.4, "Hombros": 0.35, "Bíceps": 0.3, "Tríceps": 0.3,
                                                      "Cuádriceps": 0.35, "Glúteos": 0.35, "Isquios": 0.25, "Core": 0.35])
        health.recentWorkouts = [backSession]
        let after = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        XCTAssertLessThan(after.muscles.first { $0.name == "Espalda" }?.readiness ?? 100, 100,
                          "A real, logged back session must register some fatigue instead of reading as if it never happened.")
    }

    func testTwinEngineMuscleFatigueIgnoresStaleStoredMuscleSetsValue() {
        // Two workouts with identical real exercises/setDetails but wildly
        // different, deliberately wrong stored muscleSets — as if one was
        // saved before a refinement to MuscleMap's weighting and the other
        // after. If fatigue is genuinely computed from effectiveMuscleSets
        // (recomputed from exercises) rather than the frozen stored field,
        // both must produce identical readiness; reading the stored field
        // directly (the bug) would make them diverge.
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let start = now.addingTimeInterval(-18 * 3_600)
        let exercises = [ImportedExercise(name: "Seated Cable Row - Bar Grip", sets: 6, volume: 600, totalReps: 60, averageWeight: 10,
                                          setDetails: (0..<6).map { _ in ImportedSet(weight: 10, reps: 10, type: "normal", rpe: nil) })]

        let workoutA = ImportedWorkout(title: "StaleTestA-\(UUID().uuidString)", start: start, end: start.addingTimeInterval(3_600),
                                       exercises: exercises, muscleSets: ["Espalda": 6, "Bíceps": 6])
        imports.restore(workouts: [workoutA], labs: [])
        let assessmentA = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        imports.deleteWorkout(id: workoutA.id)

        let workoutB = ImportedWorkout(title: "StaleTestB-\(UUID().uuidString)", start: start, end: start.addingTimeInterval(3_600),
                                       exercises: exercises, muscleSets: ["Espalda": 40, "Bíceps": 40])
        imports.restore(workouts: [workoutB], labs: [])
        defer { imports.deleteWorkout(id: workoutB.id) }
        let assessmentB = TwinEngine.assess(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)

        XCTAssertEqual(assessmentA.muscles.first { $0.name == "Bíceps" }?.readiness,
                       assessmentB.muscles.first { $0.name == "Bíceps" }?.readiness,
                       "Fatigue must come from effectiveMuscleSets (recomputed from real exercises), not the stored muscleSets field — identical real exercises with different stale stored numbers must produce identical readiness.")
    }

    func testStrengthCoverageIncludesWatchOnlyStrengthSessionsAsAnEstimate() {
        let backSession = healthWorkout(activity: "Fuerza", kilometers: 0, minutes: 20, date: Date().addingTimeInterval(-18 * 3_600),
                                        muscleGroups: ["Espalda": 0.4, "Bíceps": 0.3])
        let coverage = StrengthProgressEngine.coverage([], profile: .angelDefault, healthWorkouts: [backSession])
        let tiron = coverage.items.first { $0.name == "Tirón" }
        XCTAssertGreaterThan(tiron?.completed ?? 0, 0, "A real Watch-only back session must move Tirón off zero, not read as if nothing happened.")
    }

    func testStrengthCoverageNeverDoubleCountsAHevyWorkoutMirroredIntoHealthKit() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let imported = ImportedWorkout(title: "Espalda", start: start, end: start.addingTimeInterval(45 * 60),
                                       exercises: [ImportedExercise(name: "Lat Pulldown (Cable)", sets: 4, volume: 800, totalReps: 40, averageWeight: 20,
                                                                     setDetails: (0..<4).map { _ in ImportedSet(weight: 20, reps: 10, type: "normal", rpe: nil) })],
                                       muscleSets: ["Espalda": 4])
        let mirrored = healthWorkout(activity: "Fuerza", kilometers: 0, minutes: 45, date: start,
                                     muscleGroups: ["Espalda": 0.4, "Bíceps": 0.3])
        let withoutHealthKit = StrengthProgressEngine.coverage([imported], profile: .angelDefault)
        let withMirroredHealthKit = StrengthProgressEngine.coverage([imported], profile: .angelDefault, healthWorkouts: [mirrored])
        XCTAssertEqual(withMirroredHealthKit.items.first { $0.name == "Tirón" }?.completed,
                       withoutHealthKit.items.first { $0.name == "Tirón" }?.completed,
                       "The HealthKit summary Hevy also writes must not be counted a second time on top of the real import.")
    }

    func testProgressedCeilingFallsBackHonestlyWithoutHistory() {
        let result = TrainingPlanEngine.progressedCeiling(recent: nil, phaseCeiling: 90)
        XCTAssertEqual(result.minutes, 90)
        XCTAssertFalse(result.isPersonalized)
    }

    func testProgressedCeilingNeverExceedsThePhaseTableRegardlessOfHistory() {
        // An athlete who could clearly handle far more than the phase table
        // asks for still gets capped at the table's own ceiling — the
        // periodization decides the ambition, personal history only ever
        // pulls it down, never licenses jumping past it.
        let result = TrainingPlanEngine.progressedCeiling(recent: 400, phaseCeiling: 90)
        XCTAssertEqual(result.minutes, 90)
        XCTAssertTrue(result.isPersonalized)
    }

    func testProgressedCeilingCapsWeekOverWeekGrowthFromOwnHistory() {
        // Longest recent session was 40 min; the phase table wants 90 —
        // jumping straight there would be exactly the "tabla fija" failure
        // mode. The safe ~15% increase (46 min) must win instead.
        let result = TrainingPlanEngine.progressedCeiling(recent: 40, phaseCeiling: 90)
        XCTAssertEqual(result.minutes, 46, accuracy: 0.01)
        XCTAssertTrue(result.isPersonalized)
    }

    // The concrete fix behind "conectar Tres futuros al plan real": before
    // this, every ProgressionPace shared the exact same flat 15%/week
    // ceiling here regardless of what the athlete actually chose — a
    // Conservador athlete's real long-run/long-session progression grew
    // exactly as fast as an Agresivo one's. weeklyGrowthCap must now
    // actually vary the real ceiling, using ProgressionPace's own numbers.
    func testProgressedCeilingWeeklyGrowthCapVariesByProgressionPace() {
        let conservative = TrainingPlanEngine.progressedCeiling(recent: 40, phaseCeiling: 90, weeklyGrowthCap: ProgressionPace.conservative.weeklyGrowthRate)
        let optimal = TrainingPlanEngine.progressedCeiling(recent: 40, phaseCeiling: 90, weeklyGrowthCap: ProgressionPace.optimal.weeklyGrowthRate)
        let aggressive = TrainingPlanEngine.progressedCeiling(recent: 40, phaseCeiling: 90, weeklyGrowthCap: ProgressionPace.aggressive.weeklyGrowthRate)
        XCTAssertEqual(conservative.minutes, 40 * 1.04, accuracy: 0.01)
        XCTAssertEqual(optimal.minutes, 40 * 1.09, accuracy: 0.01)
        XCTAssertEqual(aggressive.minutes, 40 * 1.15, accuracy: 0.01)
        XCTAssertLessThan(conservative.minutes, optimal.minutes)
        XCTAssertLessThan(optimal.minutes, aggressive.minutes)
    }

    func testPersonalizedStepTargetRatchetsUpFromASedentaryBaselineInsteadOfJumpingTo10000() {
        // Averaging 3,000/day: asking straight for 10,000 would feel
        // unreachable. The real "next step" target should be ~15% above
        // their own habitual average, same progressedCeiling logic as
        // run/bike/swim weekly minutes.
        let now = Date()
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-14 * 86_400)
        let history = (0..<14).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: 3_000) }
        let result = TrainingPlanEngine.personalizedStepTarget(stepsHistory: history, now: now)
        XCTAssertTrue(result.isPersonalized)
        XCTAssertEqual(result.target, 3_450)
    }

    func testPersonalizedStepTargetNeverExceedsTheReferenceCeilingEvenForAnActivePerson() {
        // Someone already averaging 12,000/day doesn't get pushed to an
        // even higher number — 10,000 is the general reference ceiling,
        // not a floor to keep climbing past.
        let now = Date()
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-14 * 86_400)
        let history = (0..<14).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: 12_000) }
        let result = TrainingPlanEngine.personalizedStepTarget(stepsHistory: history, now: now)
        XCTAssertTrue(result.isPersonalized)
        XCTAssertEqual(result.target, 10_000)
    }

    func testPersonalizedStepTargetExcludesTodayItselfFromTheBaseline() {
        // Today's count is still in progress — including it would bias
        // the "recent habitual" baseline down every single day.
        let now = Date()
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-13 * 86_400)
        var history = (0..<13).map { TrendPoint(date: start.addingTimeInterval(Double($0) * 86_400), value: 8_000) }
        history.append(TrendPoint(date: now, value: 200)) // today, barely started
        let result = TrainingPlanEngine.personalizedStepTarget(stepsHistory: history, now: now)
        XCTAssertEqual(result.target, 9_200, "Today's partial 200 steps must not drag the baseline average down.")
    }

    func testPersonalizedStepTargetFallsBackHonestlyWithoutEnoughRealHistory() {
        let now = Date()
        let history = (0..<3).map { TrendPoint(date: now.addingTimeInterval(Double($0) * -86_400), value: 9_000) }
        let result = TrainingPlanEngine.personalizedStepTarget(stepsHistory: history, now: now)
        XCTAssertFalse(result.isPersonalized)
        XCTAssertEqual(result.target, 10_000)
    }

    func testFavorabilityJudgesTheSameDeltaOppositelyDependingOnWhichDirectionIsGood() {
        // The same +5 delta must read as favorable for a metric where high
        // is good (HRV) and adverse for one where low is good (resting HR)
        // — this is the one shared rule every baseline-comparison rendering
        // in the app now goes through, instead of each card inventing its
        // own color logic.
        XCTAssertEqual(Favorability.of(delta: 5, favorableHigh: true), .favorable)
        XCTAssertEqual(Favorability.of(delta: 5, favorableHigh: false), .adverse)
        XCTAssertEqual(Favorability.of(delta: -5, favorableHigh: true), .adverse)
    }

    func testFavorabilityTreatsSmallDeltasInsideTheDeadZoneAsNeutral() {
        XCTAssertEqual(Favorability.of(delta: 0.3, favorableHigh: true, deadZone: 1.0), .neutral)
        XCTAssertEqual(Favorability.of(delta: 2.0, favorableHigh: true, deadZone: 1.0), .favorable)
    }

    func testCoverageStateColorKeepsExcesivoAsAHarderFlagThanAlto() {
        // Both used to just be "not Adecuado" in two independently
        // hand-written switches (running + strength coverage) — this
        // keeps them as genuinely distinct severities, not collapsed
        // into one generic "bad" bucket.
        XCTAssertEqual(coverageStateColor("Adecuado"), EterTheme.positive)
        XCTAssertEqual(coverageStateColor("Alto"), EterTheme.negative)
        XCTAssertEqual(coverageStateColor("Excesivo"), EterTheme.danger)
        XCTAssertNotEqual(coverageStateColor("Alto"), coverageStateColor("Excesivo"))
    }

    func testWatchActivityRoutesEveryNonRunningNonStrengthKindToCardioInsteadOfStrength() {
        // The real bug: swim/bike/brick/HYROX/race-day used to fall through
        // a string-matching default straight into "strength" — meaning
        // tapping the Watch button would start and log a mislabeled
        // traditionalStrengthTraining HealthKit session for a bike ride.
        for kind: PlannedSessionKind in [.swim, .bike, .brick, .hybrid, .raceDay] {
            XCTAssertEqual(TrainingPlanEngine.watchActivity(for: kind), "cardio",
                           "\(kind) must not be classified as strength.")
        }
    }

    func testWatchActivityStillRecognizesRunningStrengthAndRecovery() {
        XCTAssertEqual(TrainingPlanEngine.watchActivity(for: .easyRun), "running")
        XCTAssertEqual(TrainingPlanEngine.watchActivity(for: .qualityRun), "running")
        XCTAssertEqual(TrainingPlanEngine.watchActivity(for: .longRun), "running")
        XCTAssertEqual(TrainingPlanEngine.watchActivity(for: .strength), "strength")
        XCTAssertEqual(TrainingPlanEngine.watchActivity(for: .recovery), "recovery")
    }

    func testRecentLongestSessionMinutesIgnoresSessionsOutsideTheLookbackWindow() {
        let now = Date()
        let recent = healthWorkout(activity: "Ciclismo", kilometers: 30, minutes: 50, date: now.addingTimeInterval(-5 * 86_400))
        let stale = healthWorkout(activity: "Ciclismo", kilometers: 100, minutes: 240, date: now.addingTimeInterval(-40 * 86_400))
        let longest = TrainingPlanEngine.recentLongestSessionMinutes([recent, stale], activity: "Ciclismo", now: now, lookbackDays: 21)
        XCTAssertEqual(longest, 50, "The 240-minute ride is 40 days old — outside the 21-day tolerance window, must not count.")
    }

    func testRecentWeeklyMinutesBaselineAveragesThePriorThreeWeeks() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        health.recentWorkouts = (1...3).map { week in
            healthWorkout(activity: "Natación", kilometers: 1, minutes: 30, date: now.addingTimeInterval(Double(-week) * 7 * 86_400 - 3600))
        }
        let baseline = TrainingPlanEngine.recentWeeklyMinutesBaseline("Natación", health: health, imports: imports, now: now)
        XCTAssertEqual(baseline ?? 0, 30, accuracy: 0.01)
    }

    func testDisciplineDoseDeficitNeverGoesNegative() {
        let dose = DisciplineDose(targetMinutes: 60, completedMinutes: 90, targetLongSessionMinutes: 40, isPersonalizedProgression: false)
        XCTAssertEqual(dose.deficitMinutes, 0)
    }

    func testBrickMinutesSumsBikeAndRunAcrossEveryDetectedPair() {
        let bikeA = healthWorkout(activity: "Ciclismo", kilometers: 30, minutes: 60, date: Date(timeIntervalSince1970: 1_000_000))
        let runA = healthWorkout(activity: "Carrera", kilometers: 3, minutes: 20, date: bikeA.date.addingTimeInterval(bikeA.durationMinutes * 60 + 10 * 60))
        let now = runA.date.addingTimeInterval(3_600)
        XCTAssertEqual(TriathlonForecastEngine.brickMinutes([bikeA, runA], now: now), 80, accuracy: 0.01)
    }

    func testBalancedDecisionMinutesDeficitFixesTheTwoShortRidesProblem() {
        // The exact scenario flagged: two 35-minute rides this week already
        // satisfy the session-count target (targetBike: 2, bike: 2 -> zero
        // count deficit), yet real weekly volume is far short of what the
        // phase actually needs — only the minutes-deficit term can catch that.
        let focus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0, triathlon: 0.55, leadingGoal: "Ironman")
        let noMinutesDeficit = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, daysSinceSwim: 5, daysSinceBike: 2,
            swimDeficit: 0, bikeDeficit: 0, swimMinutesDeficit: 0, bikeMinutesDeficit: 0,
            hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
            goalFocus: focus
        )
        let withMinutesDeficit = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, daysSinceSwim: 5, daysSinceBike: 2,
            swimDeficit: 0, bikeDeficit: 0, swimMinutesDeficit: 0, bikeMinutesDeficit: 110,
            hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
            goalFocus: focus
        )
        // With no minutes deficit, swim (5 days overdue) beats bike (only 2).
        XCTAssertEqual(noMinutesDeficit.kind, .swim)
        // A real 110-minute weekly bike shortfall must be enough to flip
        // that, even though bike is less "overdue" by days and has no
        // session-count deficit at all.
        XCTAssertEqual(withMinutesDeficit.kind, .bike)
    }

    func testEventTodayProducesRaceDayNotAnOrdinaryTrainingKind() {
        let now = Date()
        var profile = AthletePlanProfile.angelDefault
        // Any of these three used to map onto a different ordinary training
        // kind (.hybrid for HYROX, .brick for triathlon/Ironman, .qualityRun
        // for a plain running race) instead of a race-day protocol — all
        // three must now agree on the same .raceDay kind regardless of sport.
        let raceGoal = TrainingGoal(id: UUID(), kind: .triathlon, title: "Triatlón de prueba", date: now,
                                   targetValue: nil, unit: "min", priority: .primary, isActive: true)
        profile.goals = [raceGoal]

        let health = HealthStore()
        let imports = ImportStore()
        let status = TrainingPlanEngine.status(health: health, imports: imports, readiness: 80, muscles: [],
                                               checkIn: nil, context: TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                                                                  calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                               physiologicalAlert: nil, now: now)
        XCTAssertEqual(status.nextSession, .raceDay)
        XCTAssertNotEqual(status.nextSession, .brick)

        var hyroxProfile = AthletePlanProfile.angelDefault
        hyroxProfile.goals = [TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX de prueba", date: now,
                                           targetValue: nil, unit: "min", priority: .primary, isActive: true)]
        let hyroxStatus = TrainingPlanEngine.status(health: health, imports: imports, readiness: 80, muscles: [],
                                                    checkIn: nil, context: TwinContext(profile: hyroxProfile, events: [], reviews: [], activeInjuries: [],
                                                                                       calibration: neutralCalibration, personalAnchor: neutralAnchor),
                                                    physiologicalAlert: nil, now: now)
        XCTAssertEqual(hyroxStatus.nextSession, .raceDay)
        XCTAssertNotEqual(hyroxStatus.nextSession, .hybrid)
    }

    func testWorkoutPlannerBuildsARaceDayProtocolNotAWorkout() {
        let now = Date()
        var profile = AthletePlanProfile.angelDefault
        profile.goals = [TrainingGoal(id: UUID(), kind: .triathlon, title: "Triatlón de prueba", date: now,
                                      targetValue: nil, unit: "min", priority: .primary, isActive: true)]

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let workout = WorkoutPlanner.propose(health: HealthStore(), imports: ImportStore(), checkIn: nil, context: context, now: now)
        // If readiness computed from an empty HealthStore ever drops below
        // the recovery threshold, this would legitimately show recovery
        // instead — only assert the race-day shape once it actually got there.
        guard workout.title.localizedCaseInsensitiveContains("competición") else { return }
        XCTAssertFalse(workout.title.localizedCaseInsensitiveContains("brick"))
        XCTAssertFalse(workout.title.localizedCaseInsensitiveContains("híbrido"))
        XCTAssertTrue(workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("señales para parar") })
        XCTAssertTrue(workout.note.localizedCaseInsensitiveContains("no es un entrenamiento"))
    }

    func testLongBikeAndSwimClassificationMatchesRealBands() {
        let longBike = healthWorkout(activity: "Ciclismo", kilometers: 70, minutes: 130)
        let shortBike = healthWorkout(activity: "Ciclismo", kilometers: 20, minutes: 45)
        let longSwim = healthWorkout(activity: "Natación", kilometers: 3.5, minutes: 80)
        let shortSwim = healthWorkout(activity: "Natación", kilometers: 1, minutes: 30)
        XCTAssertTrue(TrainingPlanEngine.isLongBike(longBike))
        XCTAssertFalse(TrainingPlanEngine.isLongBike(shortBike))
        XCTAssertTrue(TrainingPlanEngine.isLongSwim(longSwim))
        XCTAssertFalse(TrainingPlanEngine.isLongSwim(shortSwim))
    }

    func testBalancedDecisionWithholdsSwimAndBikeWithinTheirOwnLongSessionWindow() {
        let focus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0, triathlon: 0.55, leadingGoal: "Ironman")
        let fresh = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, daysSinceSwim: 5, daysSinceBike: 5,
            hoursSinceLongSwim: 48, hoursSinceLongBike: 48,
            hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
            goalFocus: focus
        )
        XCTAssertTrue([.swim, .bike].contains(fresh.kind))

        // A long bike/swim just a few hours ago must withhold *that same*
        // discipline from today's candidates, same spacing principle
        // running's long-run window already gets.
        let stillRecovering = TrainingPlanEngine.balancedDecision(
            runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
            daysSinceStrength: 2, daysSinceSwim: 5, daysSinceBike: 5,
            hoursSinceLongSwim: 6, hoursSinceLongBike: 6,
            hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
            goalFocus: focus
        )
        XCTAssertFalse([.swim, .bike].contains(stillRecovering.kind))
    }

    func testEnduranceNutritionGuidanceOnlyAppliesPastAnHourAndScalesWithHeat() {
        XCTAssertNil(EnduranceNutritionEngine.guidance(durationMinutes: 45))
        let temperate = EnduranceNutritionEngine.guidance(durationMinutes: 150)
        XCTAssertNotNil(temperate)
        XCTAssertEqual(temperate?.carbsGramsPerHour.lowerBound, 60)
        let hot = EnduranceNutritionEngine.guidance(durationMinutes: 150, expectedAirTemperatureCelsius: 30)
        XCTAssertGreaterThan(hot?.fluidMillilitersPerHour.upperBound ?? 0, temperate?.fluidMillilitersPerHour.upperBound ?? 0)
    }

    func testWetsuitLegalityFollowsWaterTemperatureThreshold() {
        var course = EventCourseDetails()
        XCTAssertNil(course.wetsuitLikelyLegal, "Unknown temperature must never guess legality.")
        course.expectedWaterTemperatureCelsius = 18
        XCTAssertEqual(course.wetsuitLikelyLegal, true)
        course.expectedWaterTemperatureCelsius = 27
        XCTAssertEqual(course.wetsuitLikelyLegal, false)
    }

    func testTriathlonForecastPrefersOpenWaterPaceOverPoolWhenBothExist() {
        let race = RaceForecast(distanceName: "10 km", seconds: 2_400, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        // Pool pace (1:40/100m) is meaningfully faster than open water
        // (2:00/100m) — the race is open water, so the forecast must use
        // the open-water evidence directly, not the faster pool number.
        var pool = healthWorkout(activity: "Natación", kilometers: 1.5, minutes: 25)
        pool.swimLocation = .pool
        var openWater = healthWorkout(activity: "Natación", kilometers: 1.5, minutes: 30)
        openWater.swimLocation = .openWater
        let forecast = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: [pool, openWater])
        // 1.5 km target at 2:00/100m open-water pace = 1800s.
        XCTAssertEqual(forecast?.swimSeconds ?? 0, 1_800, accuracy: 5)
    }

    func testTriathlonForecastExcludesIndoorRidesWhenOutdoorEvidenceExists() {
        let race = RaceForecast(distanceName: "10 km", seconds: 2_400, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        var indoor = healthWorkout(activity: "Ciclismo", kilometers: 40, minutes: 60) // 40 km/h, unrealistic outdoor claim
        indoor.isIndoor = true
        var outdoor = healthWorkout(activity: "Ciclismo", kilometers: 40, minutes: 80) // 30 km/h
        outdoor.isIndoor = false
        let forecast = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: [indoor, outdoor])
        // 40 km at 30 km/h (the outdoor ride) = 4800s, not 3600s (indoor).
        XCTAssertEqual(forecast?.bikeSeconds ?? 0, 4_800, accuracy: 5)
    }

    func testTriathlonForecastSurfacesCourseCaveatsWithoutAlteringTheNumber() {
        let race = RaceForecast(distanceName: "10 km", seconds: 2_400, confidence: .high, basis: "Test")
        let running = RunningPerformanceSummary(
            sessions: [], weeks: [], kilometers7Days: 20, priorKilometers7Days: 18,
            fiveK: nil, tenK: race, halfMarathon: nil, marathon: nil,
            easyPercentage: 75, hardPercentage: 25, hasZoneData: true
        )
        var course = EventCourseDetails()
        course.courseElevationMeters = 900
        course.expectedWaterTemperatureCelsius = 20
        let withCourse = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: [], courseDetails: course)
        let withoutCourse = TriathlonForecastEngine.forecast(distance: .olympic, running: running, workouts: [])
        XCTAssertNotNil(withCourse?.courseCaveat)
        XCTAssertNil(withoutCourse?.courseCaveat)
        // The caveat is disclosure only — it must not change the actual
        // projected time (this app never fakes a per-kilometer grade model).
        XCTAssertEqual(withCourse?.seconds, withoutCourse?.seconds)
    }

    func testBalancedDecisionSwimDeficitCanOutweighDaysSinceLast() {
        let focus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0, triathlon: 0.55, leadingGoal: "Ironman")
        func decide(swimDeficit: Int) -> PlannedSessionKind {
            TrainingPlanEngine.balancedDecision(
                runs: 4, targetRuns: 4, strength: 2, targetStrength: 2, quality: 1, targetQuality: 1,
                daysSinceStrength: 2, daysSinceSwim: 2, daysSinceBike: 5,
                swimDeficit: swimDeficit, bikeDeficit: 0,
                hoursSinceLong: 168, hoursSinceQuality: 96, lateWeek: false, readiness: 75, muscles: muscles(legs: 75),
                goalFocus: focus
            ).kind
        }
        // Bike has gone far longer without a session (5 days vs 2) and, with
        // no weekly-budget signal at all, correctly wins on days-overdue alone.
        XCTAssertEqual(decide(swimDeficit: 0), .bike)
        // But once swim is clearly behind its own weekly target, that deficit
        // — not just "how many days since the last one" — must be enough to
        // flip the decision: "muchos días sin nadar" is a trigger, the
        // deficit is the actual weekly dose.
        XCTAssertEqual(decide(swimDeficit: 4), .swim)
    }

    func testSimulatedDecisionOverrideMapsToTheRightSessionKind() {
        XCTAssertEqual(SimulatedDecision.rest.overrideSessionKind, .recovery)
        XCTAssertEqual(SimulatedDecision.quality.overrideSessionKind, .qualityRun)
        XCTAssertEqual(SimulatedDecision.longRun.overrideSessionKind, .longRun)
        XCTAssertEqual(SimulatedDecision.strength.overrideSessionKind, .strength)
        // A lifestyle choice never substitutes today's actual session — it
        // only shifts the readiness that feeds into the days after it.
        for lifestyle: SimulatedDecision in [.alcohol, .fastingTonight, .poorHydration, .sauna] {
            XCTAssertNil(lifestyle.overrideSessionKind)
        }
    }

    func testWeekAheadOverrideReplacesTodaysSessionAndDrivesTomorrow() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let override = TrainingPlanEngine.DecisionOverride(
            kind: .strength, load: 30, tomorrowReadiness: 40, todayRationale: "Simulación de prueba"
        )
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now, override: override)

        XCTAssertEqual(week[0].kind, .strength, "The override must replace today's session, not just annotate it.")
        XCTAssertEqual(week[0].rationale, "Simulación de prueba")
        // A low overridden tomorrow-readiness (40, below the 58 recovery
        // threshold) must actually change what day 2 recommends — this is
        // the whole point of linking the simulator to the week ahead.
        XCTAssertEqual(week[1].kind, .recovery)
    }

    func testWeekAheadLifestyleOverrideKeepsTodaysSessionButShiftsReadiness() {
        let health = HealthStore()
        let imports = ImportStore()
        let now = Date()
        let real = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now)
        // A lifestyle-only override (nil kind) must leave today's own
        // recommendation untouched, but still push a low tomorrow-readiness
        // through to the next day's decision.
        let override = TrainingPlanEngine.DecisionOverride(
            kind: nil, load: 0, tomorrowReadiness: 35, todayRationale: "Simulación: alcohol"
        )
        let week = TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: nil, context: neutralContext, now: now, override: override)

        XCTAssertEqual(week[0].kind, real[0].kind, "A lifestyle choice must not replace today's real session.")
        XCTAssertEqual(week[1].kind, .recovery)
    }

    func testLifestyleDecisionsDegradeSafelyWithoutHistory() {
        for decision: SimulatedDecision in [.alcohol, .fastingTonight, .poorHydration, .sauna] {
            let simulation = DecisionSimulatorEngine.simulate(decision, health: HealthStore(), imports: ImportStore(), checkIn: nil,
                                                              profile: neutralProfile, events: [], reviews: [], activeInjuries: [],
                                                              calibration: neutralCalibration, personalAnchor: neutralAnchor)
            XCTAssertEqual(simulation.addedLoad, 0, "Lifestyle decisions never add training load.")
            XCTAssertEqual(simulation.confidence, .low, "No episodes logged yet -> no confident personal effect to apply.")
            XCTAssertTrue((0...100).contains(simulation.tomorrowReadiness))
        }
    }

    func testReadinessLoadFactorMatchesPrescriptionBands() {
        XCTAssertEqual(StrengthPrescriptionEngine.readinessLoadFactor(30), 0.88, accuracy: 0.001)
        XCTAssertEqual(StrengthPrescriptionEngine.readinessLoadFactor(50), 0.93, accuracy: 0.001)
        XCTAssertEqual(StrengthPrescriptionEngine.readinessLoadFactor(70), 1.0, accuracy: 0.001)
        XCTAssertEqual(StrengthPrescriptionEngine.readinessLoadFactor(90), 1.015, accuracy: 0.001)
    }

    func testLongRunAndQualityRunClassificationAreDisjoint() {
        let quality = healthRun(kilometers: 6, minutes: 30, calories: 400)
        let long = healthRun(kilometers: 15, minutes: 70, calories: 500)

        XCTAssertTrue(TrainingPlanEngine.isQualityRun(quality))
        XCTAssertFalse(TrainingPlanEngine.isLongRun(quality))
        XCTAssertTrue(TrainingPlanEngine.isLongRun(long))
        XCTAssertFalse(TrainingPlanEngine.isQualityRun(long))
    }

    func testHistoricalLoadFallsBackHonestlyWithoutPersonalHistory() {
        let fallback = DecisionSimulatorEngine.historicalLoad([], cardioFactor: 1.45, fallback: 78)
        XCTAssertEqual(fallback, DecisionSimulatorEngine.HistoricalLoad(load: 78, sessions: 0, isPersonal: false))
    }

    func testHistoricalLoadUsesMedianOfRealSessionsOnceEnoughExist() {
        let runs = [30.0, 40.0, 50.0].map { healthRun(kilometers: 8, minutes: $0) }
        let result = DecisionSimulatorEngine.historicalLoad(runs, cardioFactor: 1.45, fallback: 78)

        XCTAssertTrue(result.isPersonal)
        XCTAssertEqual(result.sessions, 3)
        XCTAssertEqual(result.load, 58, accuracy: 0.001, "Mediana de 43.5/58/72.5, no la constante de reserva")
    }

    func testPaceExpectationIsMoreConservativeWhenReadinessIsLow() {
        let runs = [healthRun(kilometers: 8, minutes: 40), healthRun(kilometers: 8, minutes: 40)]
        let basis = DecisionSimulatorEngine.historicalLoad(runs, cardioFactor: 1.45, fallback: 78)

        let low = DecisionSimulatorEngine.paceExpectation(runs, readiness: 40, label: "intervalos", basis: basis)
        let high = DecisionSimulatorEngine.paceExpectation(runs, readiness: 90, label: "intervalos", basis: basis)

        XCTAssertTrue(low.contains(DecisionSimulatorEngine.formatPace(5.4)), "readiness 40 -> factor 1.08 sobre una mediana de 5:00/km")
        XCTAssertTrue(high.contains(DecisionSimulatorEngine.formatPace(5.0 * 0.985)), "readiness 90 -> factor 0.985")
        XCTAssertTrue(low.contains("3 sesiones") == false && low.contains("2 sesiones"), "usa el nº real de sesiones, no un valor fijo")
    }

    private func testDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func labResult(_ name: String, _ value: Double, date: Date, unit: String = "", low: Double? = nil, high: Double? = nil) -> LabResult {
        LabResult(date: date, name: name, value: value, unit: unit, low: low, high: high, previous: nil)
    }

    private func healthRun(kilometers: Double, minutes: Double, date: Date = Date(), calories: Double? = nil) -> HealthWorkout {
        HealthWorkout(id: UUID(), date: date, durationMinutes: minutes, calories: calories,
                      distanceKilometers: kilometers, averageHeartRate: 150, elevationMeters: nil,
                      activity: "Carrera", muscleGroups: ["Piernas": 1], source: "Apple Watch")
    }

    private func alertSignal(_ name: String, deviation: Double, date: Date) -> PhysiologicalAlertSignal {
        PhysiologicalAlertSignal(
            name: name, value: "50", favorableDeviation: deviation,
            confidence: 80, measuredAt: date
        )
    }

    private func review(for workout: HealthWorkout, effort: Int, purpose: WorkoutPurpose) -> WorkoutReview {
        WorkoutReview(workoutID: "health-\(workout.id.uuidString)", workoutDate: workout.date, effort: effort,
                      outcome: .asPlanned, muscleFeeling: 3, repsInReserve: 2, pain: false,
                      note: "", purpose: purpose, recordedAt: workout.date)
    }

    private func muscles(legs readiness: Int) -> [MuscleReadiness] {
        ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"].map {
            MuscleReadiness(name: $0, readiness: readiness, lastTrained: nil, recentSets: 0)
        } + [
            MuscleReadiness(name: "Pecho", readiness: 90, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Espalda", readiness: 90, lastTrained: nil, recentSets: 0)
        ]
    }

    func testLegSensitiveRunLikelyTomorrowDetectsAllThreeCases() {
        let focus = GoalTrainingFocus(running: 0.75, strength: 0.15, hybrid: 0, leadingGoal: "10k")
        // Quality run plausible: deficit exists and tomorrow crosses 72h.
        XCTAssertTrue(TrainingPlanEngine.legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: 50, hoursSinceLong: nil, tomorrowIsLateWeek: false, qualityDeficit: 1, goalFocus: focus))
        // Long run plausible: late week tomorrow and spacing satisfied.
        XCTAssertTrue(TrainingPlanEngine.legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: nil, hoursSinceLong: 100, tomorrowIsLateWeek: true, qualityDeficit: 0, goalFocus: focus))
        // Hybrid plausible: goal weight high enough and spacing satisfied.
        let hybridFocus = GoalTrainingFocus(running: 0.30, strength: 0.15, hybrid: 0.30, leadingGoal: "HYROX")
        XCTAssertTrue(TrainingPlanEngine.legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: 30, hoursSinceLong: nil, tomorrowIsLateWeek: false, qualityDeficit: 0, goalFocus: hybridFocus))
        // None of the three — must be false.
        XCTAssertFalse(TrainingPlanEngine.legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: 10, hoursSinceLong: 10, tomorrowIsLateWeek: false, qualityDeficit: 0, goalFocus: focus))
    }

    func testBestStrengthPatternNeverReturnsLegsWhenAvoidingThemForTomorrowsRun() {
        // Pierna would win overwhelmingly on both readiness and volume
        // deficit — avoidLegs must remove it from consideration entirely
        // rather than merely discourage it, so a run scheduled tomorrow
        // actually gets fresh legs.
        let muscles = [
            MuscleReadiness(name: "Cuádriceps", readiness: 95, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Glúteos", readiness: 95, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Isquios", readiness: 95, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Pecho", readiness: 55, lastTrained: nil, recentSets: 10),
            MuscleReadiness(name: "Hombros", readiness: 55, lastTrained: nil, recentSets: 8),
            MuscleReadiness(name: "Tríceps", readiness: 55, lastTrained: nil, recentSets: 6),
            MuscleReadiness(name: "Espalda", readiness: 52, lastTrained: nil, recentSets: 8),
            MuscleReadiness(name: "Bíceps", readiness: 52, lastTrained: nil, recentSets: 4)
        ]
        XCTAssertEqual(TrainingPlanEngine.bestStrengthPattern(muscles), "pierna", "Sanity check: without avoidLegs, pierna must win as before.")
        XCTAssertNotEqual(TrainingPlanEngine.bestStrengthPattern(muscles, avoidLegs: true), "pierna")
    }

    func testMuscleVolumeLandmarksDeriveMEVAndMRVFromMAV() {
        let espalda = MuscleVolumeLandmarkTable.landmarks(for: "Espalda")
        XCTAssertEqual(espalda.mav, 16)
        XCTAssertEqual(espalda.mev, 8)
        XCTAssertEqual(espalda.mrv, 24)
        // Unknown muscle name must fall back honestly, not crash or return 0.
        let unknown = MuscleVolumeLandmarkTable.landmarks(for: "Antebrazo")
        XCTAssertEqual(unknown.mav, 14)
    }

    func testMuscleVolumeLandmarkBucketsMatchMuscleRadarsPreexistingAggregates() {
        // Zero-regression check: MuscleRadar's own displayed targets must
        // be unchanged now that they're sourced from the shared table
        // instead of a second, separately hand-picked dictionary.
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Piernas"), 22)
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Brazos"), 16)
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Espalda"), 16)
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Pecho"), 15)
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Hombros"), 13)
        XCTAssertEqual(MuscleVolumeLandmarkTable.bucketMAV("Core"), 8)
    }

    func testBestStrengthPatternPrefersAPatternBelowMEVOverOneAlreadyPastItsMRV() {
        // Tirón (Espalda/Bíceps) is the most RECOVERED pattern but has
        // already passed its own weekly ceiling; pierna is a bit less
        // recovered but still eligible, and sits well below its own
        // weekly minimum. The volume deficit must be what wins here —
        // readiness alone (the old behavior) would have picked tirón.
        let muscles = [
            MuscleReadiness(name: "Espalda", readiness: 85, lastTrained: nil, recentSets: 25),   // MRV 24 — over
            MuscleReadiness(name: "Bíceps", readiness: 85, lastTrained: nil, recentSets: 12),     // MRV 11 — over
            MuscleReadiness(name: "Cuádriceps", readiness: 65, lastTrained: nil, recentSets: 1),  // MEV 4 — under
            MuscleReadiness(name: "Glúteos", readiness: 65, lastTrained: nil, recentSets: 1),     // MEV 3 — under
            MuscleReadiness(name: "Isquios", readiness: 65, lastTrained: nil, recentSets: 0),     // MEV 2 — under
            MuscleReadiness(name: "Pecho", readiness: 60, lastTrained: nil, recentSets: 10),
            MuscleReadiness(name: "Hombros", readiness: 60, lastTrained: nil, recentSets: 10),
            MuscleReadiness(name: "Tríceps", readiness: 60, lastTrained: nil, recentSets: 6)
        ]
        XCTAssertEqual(TrainingPlanEngine.bestStrengthPattern(muscles), "pierna")
    }

    func testBestStrengthPatternNeverLetsVolumeDeficitOverrideGenuineFatigue() {
        // Pierna has the biggest possible volume deficit (nothing trained
        // at all) but real readiness below the fatigue floor — it must
        // still lose to an eligible, merely-moderately-dosed pattern.
        let muscles = [
            MuscleReadiness(name: "Cuádriceps", readiness: 40, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Glúteos", readiness: 40, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Isquios", readiness: 40, lastTrained: nil, recentSets: 0),
            MuscleReadiness(name: "Pecho", readiness: 70, lastTrained: nil, recentSets: 10),
            MuscleReadiness(name: "Hombros", readiness: 70, lastTrained: nil, recentSets: 8),
            MuscleReadiness(name: "Tríceps", readiness: 70, lastTrained: nil, recentSets: 6),
            MuscleReadiness(name: "Espalda", readiness: 60, lastTrained: nil, recentSets: 24),
            MuscleReadiness(name: "Bíceps", readiness: 60, lastTrained: nil, recentSets: 11)
        ]
        XCTAssertEqual(TrainingPlanEngine.bestStrengthPattern(muscles), "empuje")
    }

    // PR2: TwinPhysiology.muscleFatigue drives weekAhead's simulated
    // freshness, but recentSets/lastTrained deliberately stay OUT of
    // TwinPhysiology (not canonical physiology) — weekAhead keeps
    // accumulating them separately in its own simulatedSets dict, exactly
    // as before PR2, so bestStrengthPattern's MEV/MAV/MRV volume-urgency
    // logic still works on simulated future days, not just today's real
    // one. Proven end to end here (not just via bestStrengthPattern's own
    // hand-constructed unit test) by forcing three consecutive real
    // simulated strength days from a hypertrophy-heavy profile with a
    // real baseline history: if simulatedSets reset to 0 (or never
    // accumulated) every simulated day, every one of these would
    // deterministically tie-break to the same pattern ("pierna", the
    // first group in bestStrengthPattern's own list) instead of rotating
    // as each pattern's own weekly volume gets used up.
    func testWeekAheadAccumulatesSimulatedSetsSoStrengthPatternRotatesAcrossDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = AthletePlanProfile.angelDefault
        profile.gymAvailable = true
        profile.goals = [TrainingGoal(id: UUID(), kind: .hypertrophy, title: "Hipertrofia", date: nil, targetValue: nil, unit: "", priority: .primary, isActive: true)]
        profile.trainingDaysPerWeek = 7

        // Real baseline (8 weeks, 4x/week) so the acute:chronic ratio gate
        // doesn't veto the whole week the way a genuinely empty history
        // would (the same fix already applied to the flaky weekAhead
        // tests above) — this is about volume accumulation, not about
        // readiness itself.
        let imports = ImportStore(persistToDisk: false)
        var importBaseline: [ImportedWorkout] = []
        for weekOffset in 1...8 {
            for dayOffset in [1, 3, 5, 7] {
                let liftDay = now.addingTimeInterval(-Double(weekOffset) * 7 * 86_400 - Double(dayOffset) * 86_400)
                importBaseline.append(ImportedWorkout(
                    title: "Empuje", start: liftDay, end: liftDay.addingTimeInterval(3_600),
                    exercises: [ImportedExercise(name: "Bench Press (Barbell)", sets: 4, volume: 1_600, totalReps: 32, averageWeight: 50, setDetails: nil)],
                    muscleSets: ["Pecho": 4]
                ))
            }
        }
        imports.restore(workouts: importBaseline, labs: [])

        let context = TwinContext(profile: profile, events: [], reviews: [], activeInjuries: [],
                                  calibration: neutralCalibration, personalAnchor: neutralAnchor)
        let week = TrainingPlanEngine.weekAhead(health: HealthStore(), imports: imports, checkIn: nil, context: context, now: now, days: 7)

        let strengthDays = week.prefix(3)
        XCTAssertTrue(strengthDays.allSatisfy { $0.kind == .strength },
                     "Sanity check: this scenario must actually produce three consecutive real strength days, or the test proves nothing.")
        let patterns = strengthDays.map(\.rationale)
        XCTAssertTrue(patterns[0].localizedCaseInsensitiveContains("pierna"))
        XCTAssertTrue(patterns[1].localizedCaseInsensitiveContains("empuje"))
        XCTAssertTrue(patterns[2].localizedCaseInsensitiveContains("tirón"),
                      "Three consecutive simulated strength days must rotate through different patterns as each one's own weekly volume gets used up — not repeat the same tie-broken pattern every day.")
    }

}
