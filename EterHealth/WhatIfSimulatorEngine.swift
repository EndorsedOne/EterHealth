import Foundation

// The combinable "¿qué pasa si...?" this app was missing: every prior
// simulator here (DecisionSimulatorEngine's lifestyle cases) only ever
// let you test ONE hypothetical at a time, with alcohol reduced to a
// bare drink count. A real evening is rarely just one thing — "cena de
// trabajo con vino" plausibly means wine AND a late dinner AND a later
// bedtime, all at once — so this scenario is genuinely composable, and
// every factor in it is grounded in either this person's OWN learned
// association (HabitAssociationEngine) or, when that's not confident yet,
// a real, disclosed reference (NIAAA standard drinks, caffeine's textbook
// elimination half-life) — never a number invented for this feature.
struct WhatIfScenario: Equatable {
    var drinks: [DrinkSelection] = []
    var caffeineMg: Int = 0
    var caffeineHour: Int? = nil
    var extraBedtimeMinutes: Int = 0
    var lateOrHeavyDinner: Bool = false

    var isEmpty: Bool {
        StandardDrinkCalculator.totalStandardDrinks(drinks) <= 0 &&
        (caffeineHour == nil || caffeineMg <= 0) &&
        extraBedtimeMinutes <= 0 && !lateOrHeavyDinner
    }
}

struct WhatIfFactorImpact: Identifiable {
    let kind: HabitKind
    var id: HabitKind { kind }
    let label: String
    // Signed, already scaled by real dose/timing — negative is adverse.
    let readinessImpact: Int
    let isLearned: Bool
    let confidence: TrustLevel
    let detail: String
}

struct WhatIfProjection {
    let scenario: WhatIfScenario
    let factorImpacts: [WhatIfFactorImpact]
    let totalReadinessImpact: Int
    let baselineReadiness: Int
    let projectedReadiness: Int
    // Percentage-point deltas vs. this person's own personal architecture
    // baseline (SleepArchitectureEngine) — nil when no active factor has a
    // confident enough learned deep/REM-specific association to say a
    // number, not a fabricated placeholder.
    let projectedDeepShareDeltaPoints: Double?
    let projectedRemShareDeltaPoints: Double?
    let headline: String
    // Non-nil when two or more factors are active AND this person hasn't
    // actually lived that exact combination enough times to learn it
    // jointly — the honest "this is the sum of individually-learned
    // effects, not a jointly observed one" disclosure.
    let combinationCaveat: String?
    let confidence: TrustLevel
    let qualitativeNotes: [String]
}

@MainActor
enum WhatIfSimulatorEngine {
    // A real evening plausibly combines several of these — see
    // WhatIfScenario. Every active factor gets its own impact, summed;
    // see combineImpacts for how honesty about the combination itself
    // (not just each piece) is handled.
    // PR15: `travel` inyectado y no leído de un `.shared` como los cinco de
    // abajo — TravelEpisodeStore no tiene singleton a propósito. Sin él, este
    // simulador proyectaría un mañana que ignora el viaje mientras la tarjeta
    // de hoy lo tiene en cuenta.
    static func simulate(_ scenario: WhatIfScenario, health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                         travel: TravelEpisode?, travelHistory: [TravelEpisode],
                         now: Date = Date()) -> WhatIfProjection {
        // TwinCore's TwinEngine.assess no longer reads these singletons
        // internally — this (outside TwinCore) is where they're read.
        let events = LifestyleFactorStore.shared.events
        let context = TwinContext(profile: GoalStore.shared.profile, events: events, reviews: WorkoutReviewStore.shared.reviews,
                                  activeInjuries: InjuryStore.shared.active, calibration: TwinStateStore.shared.calibration,
                                  personalAnchor: TwinStateStore.shared.personalAnchor(now: now),
                                  travel: travel, travelHistory: travelHistory)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context, now: now)
        let associations = HabitAssociationEngine.analyze(
            events: events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory, sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory,
            deepShare: SleepArchitectureEngine.dailyDeepShareSeries(health.sleepStagesHistory),
            remShare: SleepArchitectureEngine.dailyRemShareSeries(health.sleepStagesHistory),
            sleepSchedule: health.sleepScheduleHistory, now: now
        )
        func association(_ kind: HabitKind) -> HabitAssociation? { associations.first { $0.kind == kind } }

        var impacts: [WhatIfFactorImpact] = []
        var qualitativeNotes: [String] = []

        let totalStandardDrinks = StandardDrinkCalculator.totalStandardDrinks(scenario.drinks)
        if totalStandardDrinks > 0 {
            impacts.append(alcoholImpact(standardDrinks: totalStandardDrinks, association: association(.alcohol)))
            // Alcohol suppressing REM is one of the most replicated
            // findings in sleep science (Ebrahim et al. 2013, and the
            // same literature Walker himself cites) — real enough to say
            // qualitatively even before this person has enough of their
            // own logged episodes to quantify it personally.
            let remLearned = association(.alcohol)?.effects.first { $0.name == "REM" }
            if remLearned == nil {
                qualitativeNotes.append("El alcohol suele suprimir el sueño REM (evidencia general) — todavía no hay suficientes episodios tuyos registrados para cuantificar cuánto en tu caso.")
            }
        }

        if let caffeineHour = scenario.caffeineHour, scenario.caffeineMg > 0 {
            impacts.append(caffeineImpact(mg: scenario.caffeineMg, hour: caffeineHour, schedule: health.sleepScheduleHistory, association: association(.lateCaffeine)))
        }

        if scenario.extraBedtimeMinutes > 0 {
            impacts.append(lateBedtimeImpact(extraMinutes: scenario.extraBedtimeMinutes, association: association(.lateBedtime)))
        }

        if scenario.lateOrHeavyDinner {
            impacts.append(genericImpact(
                kind: .lateOrHeavyDinner, label: "Cena tardía o copiosa", association: association(.lateOrHeavyDinner),
                genericImmediate: -2, genericDetail: "Sin coste inmediato grande asumido por sí solo; afecta sobre todo si se combina con acostarse pronto después."
            ))
        }

        return combine(scenario: scenario, impacts: impacts, qualitativeNotes: qualitativeNotes, assessment: assessment, health: health, associations: associations)
    }

    // MARK: - Per-factor impacts

    // Reference dose: DecisionSimulatorEngine's own prior generic alcohol
    // estimate ("2 cervezas" ≈ 2 standard drinks ≈ -6pt) becomes the
    // anchor this scales from — not a new number, the same one already
    // shipped, now correctly scaled by REAL ethanol dose instead of
    // silently reused for any drink count/type. Scaling ratio capped at
    // 3x (6 standard drinks): dose-response linearity is a reasonable
    // approximation near the reference dose, not something to trust
    // extrapolated arbitrarily far.
    static func alcoholImpact(standardDrinks: Double, association: HabitAssociation?) -> WhatIfFactorImpact {
        let referenceStandardDrinks = 2.0
        let referenceGenericImpact = -6.0
        let doseRatio = min(3.0, standardDrinks / referenceStandardDrinks)
        let genericImpact = Int((referenceGenericImpact * doseRatio).rounded())
        let grams = StandardDrinkCalculator.ethanolGramsPerStandardDrink * standardDrinks

        let hasConfidentLearning = association.map { $0.confidence.level != .low && $0.direction != .neutral } ?? false
        let impact: Int
        let isLearned: Bool
        let confidence: TrustLevel
        let detail: String
        if let association, hasConfidentLearning {
            let learned = HabitAssociationEngine.readinessImpact(association)
            impact = Int((Double(learned) * doseRatio).rounded())
            isLearned = true
            confidence = association.confidence.level
            detail = "Basado en tu propio efecto aprendido sobre \(association.samples) episodios, escalado a \(standardDrinks.formatted(.number.precision(.fractionLength(0...1)))) bebidas estándar (~\(Int(grams.rounded())) g de alcohol puro)."
        } else {
            impact = genericImpact
            isLearned = false
            confidence = .low
            detail = "Sin suficiente historial personal de alcohol todavía — estimación general para \(standardDrinks.formatted(.number.precision(.fractionLength(0...1)))) bebidas estándar (~\(Int(grams.rounded())) g de alcohol puro; referencia NIAAA, 14 g por bebida estándar)."
        }
        return WhatIfFactorImpact(kind: .alcohol, label: "Alcohol", readinessImpact: impact, isLearned: isLearned, confidence: confidence, detail: detail)
    }

    // Residual caffeine at bedtime, never a binary clock-time cutoff. Learned
    // effects are scaled against the mean bedtime exposure that produced the
    // personal association, so 10 mg and 60 mg are not treated alike.
    static func caffeineImpact(mg: Int, hour: Int, schedule: [NightlySleepSchedule], association: HabitAssociation?) -> WhatIfFactorImpact {
        let typicalBedtimeHour = medianBedtimeHour(schedule) ?? 23.0
        let hoursUntilBed = CaffeinePharmacokinetics.hoursUntilBedtime(intakeHour: Double(hour), bedtimeHour: typicalBedtimeHour)
        let residual = CaffeinePharmacokinetics.residualFraction(hoursElapsed: hoursUntilBed)
        let residualMg = Double(mg) * residual
        let referenceDoseMg = 80.0 // one espresso-ish reference, matches a typical single-shot serving
        let doseFactor = min(2.5, Double(mg) / referenceDoseMg)
        let referenceGenericImpact = -4.0 // same order of magnitude as this app's other same-day cautions (poorHydration -2, alcohol -6 for 2 drinks)
        let genericImpact = Int((referenceGenericImpact * doseFactor * residual).rounded())

        let hasConfidentLearning = association.map { $0.confidence.level != .low && $0.direction != .neutral } ?? false
        let impact: Int
        let isLearned: Bool
        let confidence: TrustLevel
        let bedtimeText = String(format: "%02d:%02d", Int(typicalBedtimeHour.truncatingRemainder(dividingBy: 24)), Int((typicalBedtimeHour * 60).truncatingRemainder(dividingBy: 60)))
        let detail: String
        if let association, hasConfidentLearning {
            let learned = HabitAssociationEngine.readinessImpact(association)
            let learnedReference = max(1, association.averageExposureLevel ?? referenceDoseMg)
            let exposureRatio = min(2.5, residualMg / learnedReference)
            impact = Int((Double(learned) * exposureRatio).rounded())
            isLearned = true
            confidence = association.confidence.level
            let metricProjection = association.effects.prefix(3).map { effect in
                let projected = effect.changePercent * exposureRatio
                return "\(effect.name) \(projected >= 0 ? "+" : "")\(Int(projected.rounded()))%"
            }.joined(separator: " · ")
            detail = "A tu hora habitual de dormir (~\(bedtimeText)) quedarían ~\(Int(residualMg.rounded())) mg. Tu patrón personal para esta exposición estima: \(metricProjection). Asociación, no medición clínica."
        } else {
            impact = genericImpact
            isLearned = false
            confidence = .low
            detail = "Sin suficiente historial personal todavía — a tu hora habitual de dormir (~\(bedtimeText)) quedarían ~\(Int(residualMg.rounded())) mg (vida media general ~5 h, no medida en ti). Éter lo observará como contexto, sin atribuir porcentajes personales aún."
        }
        return WhatIfFactorImpact(kind: .lateCaffeine, label: "Cafeína", readinessImpact: impact, isLearned: isLearned, confidence: confidence, detail: detail)
    }

    static func lateBedtimeImpact(extraMinutes: Int, association: HabitAssociation?) -> WhatIfFactorImpact {
        let referenceMinutes = 60.0
        let genericImmediatePerHour = -4.0
        let doseFactor = min(2.5, Double(extraMinutes) / referenceMinutes)
        let genericImpact = Int((genericImmediatePerHour * doseFactor).rounded())
        let hasConfidentLearning = association.map { $0.confidence.level != .low && $0.direction != .neutral } ?? false
        let impact: Int
        let isLearned: Bool
        let confidence: TrustLevel
        let detail: String
        if let association, hasConfidentLearning {
            let learned = HabitAssociationEngine.readinessImpact(association)
            impact = Int((Double(learned) * doseFactor).rounded())
            isLearned = true
            confidence = association.confidence.level
            detail = "Basado en tu propio patrón real (noches que te acostaste tarde frente a tu mediana habitual), sobre \(association.samples) noches, escalado a \(extraMinutes) min de retraso."
        } else {
            impact = genericImpact
            isLearned = false
            confidence = .low
            detail = "Sin suficiente historial personal todavía — estimación general para \(extraMinutes) min más tarde de lo habitual."
        }
        return WhatIfFactorImpact(kind: .lateBedtime, label: "Acostarse tarde", readinessImpact: impact, isLearned: isLearned, confidence: confidence, detail: detail)
    }

    private static func genericImpact(kind: HabitKind, label: String, association: HabitAssociation?, genericImmediate: Int, genericDetail: String) -> WhatIfFactorImpact {
        let hasConfidentLearning = association.map { $0.confidence.level != .low && $0.direction != .neutral } ?? false
        if let association, hasConfidentLearning {
            let learned = HabitAssociationEngine.readinessImpact(association)
            return WhatIfFactorImpact(
                kind: kind, label: label, readinessImpact: learned, isLearned: true, confidence: association.confidence.level,
                detail: "Basado en tu propio efecto aprendido sobre \(association.samples) episodios."
            )
        }
        return WhatIfFactorImpact(kind: kind, label: label, readinessImpact: genericImmediate, isLearned: false, confidence: .low, detail: genericDetail)
    }

    // MARK: - Combination

    private static func combine(scenario: WhatIfScenario, impacts: [WhatIfFactorImpact], qualitativeNotes: [String], assessment: TwinAssessment, health: HealthStore, associations: [HabitAssociation]) -> WhatIfProjection {
        let totalImpact = impacts.reduce(0) { $0 + $1.readinessImpact }
        let projected = min(100, max(0, assessment.score + totalImpact))

        let architecture = SleepArchitectureEngine.evaluate(health.sleepStagesHistory)
        let activeKinds = impacts.map(\.kind)
        let deepDelta = architectureImpactPoints(activeKinds: activeKinds, associations: associations, metricName: "Sueño profundo", baselineShare: architecture?.averageDeepShare)
        let remDelta = architectureImpactPoints(activeKinds: activeKinds, associations: associations, metricName: "REM", baselineShare: architecture?.averageRemShare)

        let headline: String
        if projected >= 70 { headline = "Mañana seguirías con buena disponibilidad" }
        else if projected >= 50 { headline = "Mañana convendría ajustar la intensidad" }
        else { headline = "Mañana probablemente tocaría recuperar" }

        let activeCount = impacts.count
        let learnedCount = impacts.filter(\.isLearned).count
        let combinationCaveat: String?
        if activeCount >= 2 {
            combinationCaveat = "Es la suma de \(activeCount) efectos calculados por separado (\(learnedCount) de ellos con tu propio historial) — no algo aprendido de esta combinación exacta ocurriendo junta. Si sueles vivir estas cosas juntas, el efecto real conjunto podría ser distinto (mejor o peor) de la simple suma."
        } else {
            combinationCaveat = nil
        }

        let confidence: TrustLevel = impacts.isEmpty ? .low
            : learnedCount == activeCount ? (impacts.map(\.confidence).min(by: trustRank) ?? .low)
            : learnedCount > 0 ? .medium : .low

        return WhatIfProjection(
            scenario: scenario, factorImpacts: impacts, totalReadinessImpact: totalImpact,
            baselineReadiness: assessment.score, projectedReadiness: projected,
            projectedDeepShareDeltaPoints: deepDelta, projectedRemShareDeltaPoints: remDelta,
            headline: headline, combinationCaveat: combinationCaveat, confidence: confidence,
            qualitativeNotes: qualitativeNotes
        )
    }

    // Sums the SAME per-factor learned "Sueño profundo"/"REM" %-changes
    // (HabitAssociationEngine's own metric names) across every active,
    // confidently-learned factor, applied to this person's own personal
    // average share — nil when nothing active has a confident enough
    // architecture-specific association to say a real number.
    private static func architectureImpactPoints(activeKinds: [HabitKind], associations: [HabitAssociation], metricName: String, baselineShare: Double?) -> Double? {
        guard let baselineShare else { return nil }
        let percentChanges = activeKinds.compactMap { kind -> Double? in
            guard let association = associations.first(where: { $0.kind == kind }), association.confidence.level != .low else { return nil }
            return association.effects.first { $0.name == metricName }?.changePercent
        }
        guard !percentChanges.isEmpty else { return nil }
        let totalPercentChange = percentChanges.reduce(0, +)
        return baselineShare * 100 * (totalPercentChange / 100)
    }

    private static func trustRank(_ a: TrustLevel, _ b: TrustLevel) -> Bool {
        func rank(_ level: TrustLevel) -> Int { level == .high ? 2 : level == .medium ? 1 : 0 }
        return rank(a) < rank(b)
    }

    private static func medianBedtimeHour(_ schedule: [NightlySleepSchedule]) -> Double? {
        guard schedule.count >= 5 else { return nil }
        let calendar = Calendar.current
        let hours = schedule.map { night -> Double in
            let hour = Double(calendar.component(.hour, from: night.bedtime)) + Double(calendar.component(.minute, from: night.bedtime)) / 60.0
            return hour < 12 ? hour + 24 : hour
        }
        let sorted = hours.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return median.truncatingRemainder(dividingBy: 24)
    }
}
