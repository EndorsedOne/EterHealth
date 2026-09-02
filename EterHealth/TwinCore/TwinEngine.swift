import Foundation

struct TwinAssessment {
    let score: Int
    let state: String
    let recommendation: String
    let explanation: String
    let signals: [TwinSignal]
    let muscles: [MuscleReadiness]
    let baselineConfidence: Int
    // The same alert ContentView's physiologicalAlertCard shows — carried
    // here too so every other caller of TrainingPlanEngine.status can pass
    // it through and get the identical hard-override behavior, instead of
    // the card and the actual plan being able to disagree.
    let physiologicalAlert: PhysiologicalAlert?
    // PR2: today's real vector state — score/muscles above are unchanged
    // (still real-signal-driven, still what the plan actually consumes),
    // this is the same underlying data formally routed through
    // TwinPhysiology/TwinReadout so callers that want the vector itself
    // (weekAhead's forward simulation, TwinStateStore's tomorrow
    // prediction) can read it instead of re-deriving their own copy.
    let physiology: TwinPhysiology
    let readout: TwinReadout
    // PR15: el impacto del viaje activo, calculado UNA vez y publicado. Lo
    // consumen la puntuación de hoy (las dos señales de abajo), la fisiología
    // (donde decae), el techo de intensidad de status(), la tarjeta de Viajes
    // y el simulador. Ninguno lo recalcula: dos estimaciones del mismo viaje
    // es exactamente lo que había antes de este PR entre la app y el widget.
    let travel: TravelImpact
    // PR16: las tasas de re-sincronización que ESTA evaluación ha usado — las
    // aprendidas cuando hay evidencia, el prior cuando no. Publicadas para que
    // weekAhead simule con las mismas y no con el prior: si la semana decayera
    // el desajuste más despacio que hoy, la tira mostraría un techo que la
    // tarjeta ya ha levantado.
    let travelRates: ReentrainmentRates
    // Replaces TwinStateStore's old predictedTomorrow(from:) — a real
    // step() of today's physiology through tomorrow's proposed session,
    // never a match on the Spanish recommendation string.
    let predictedTomorrow: TwinReadout
}

struct TwinSignal: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let impact: Int
    let detail: String
}

struct MuscleReadiness: Identifiable {
    var id: String { name }
    let name: String
    let readiness: Int
    let lastTrained: Date?
    let recentSets: Int
}

@MainActor
enum TwinEngine {
    // TwinCore: every value below that used to be read from a singleton
    // instance inside this function (LifestyleFactorStore, WorkoutReviewStore,
    // InjuryStore, TwinStateStore's calibration/personalAnchor, GoalStore's
    // profile) is now a required argument instead — the caller (outside
    // TwinCore) reads the real store and passes the value in. No default
    // on it: a call site that forgets to build one should fail to compile,
    // not silently fall back to a store this function can no longer see.
    static func assess(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn? = nil,
                       context: TwinContext, now: Date = Date()) -> TwinAssessment {
        let events = context.events, reviews = context.reviews, activeInjuries = context.activeInjuries
        let calibration = context.calibration, anchor = context.personalAnchor
        var score = anchor.score
        var signals: [TwinSignal] = []
        let personal = PersonalBaselineEngine.profile(health: health, imports: imports, now: now)
        // Reuses the same PersonalBaselineProfile just computed above — no
        // second, possibly-inconsistent pass over HRV/pulso/sueño — and is
        // threaded into TrainingPlanEngine.status below so a "prioriza
        // recuperación" alert can never coexist with a demanding proposal.
        let physiologicalAlert = PhysiologicalAlertEngine.evaluate(profile: personal, checkIn: checkIn, now: now)
        let habitAssociations = Dictionary(uniqueKeysWithValues: HabitAssociationEngine.analyze(
            events: events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory,
            sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory,
            travelEpisodes: context.travelHistory, now: now
        ).map { ($0.kind, $0) })
        var appliedLearnedHabits: Set<HabitKind> = []
        var appliedElectrolytes = false
        let prolongedExerciseMinutes = health.recentWorkouts
            .filter { $0.date <= now && now.timeIntervalSince($0.date) <= 24 * 3_600 }
            .map(\.durationMinutes).max() ?? 0

        func learnedHabit(_ kind: HabitKind) -> (impact: Int, detail: String) {
            guard appliedLearnedHabits.insert(kind).inserted,
                  let association = habitAssociations[kind] else { return (0, "") }
            let impact = HabitAssociationEngine.readinessImpact(association)
            if impact == 0 {
                return (0, " Patrón personal disponible con confianza \(association.confidence.level.rawValue.lowercased()); se muestra como contexto y todavía no modifica la puntuación.")
            }
            return (impact, " Tu historial posterior muestra \(association.headline.lowercased()) Ajuste aprendido y limitado: \(String(format: "%+d", impact)) puntos · confianza \(association.confidence.level.rawValue.lowercased()).")
        }

        if anchor.confidence > 0, let median = anchor.personalMedian {
            signals.append(TwinSignal(
                name: "Base personal", value: "\(anchor.score)/100", impact: anchor.score - 70,
                detail: "Ancla aprendida de \(anchor.observations) mañanas en los últimos 90 días · mediana \(Int(median.rounded())) · confianza \(anchor.confidence)%."
            ))
        }

        if let current = personal.hrv.current, let baseline = personal.hrv.expected, baseline > 0 {
            let delta = (current - baseline) / baseline
            let impact = confidenceWeighted(clamp(Int((personal.hrv.deviation ?? 0) * 7), -15, 12), confidence: personal.hrv.confidence)
            score += impact
            signals.append(TwinSignal(name: "HRV", value: "\(Int(current.rounded())) ms", impact: impact, detail: personalDetail(personal.hrv, delta: delta)))
        }

        if let current = personal.restingHeartRate.current, let baseline = personal.restingHeartRate.expected, baseline > 0 {
            let delta = (current - baseline) / baseline
            let impact = confidenceWeighted(clamp(Int((personal.restingHeartRate.deviation ?? 0) * 7), -15, 10), confidence: personal.restingHeartRate.confidence)
            score += impact
            signals.append(TwinSignal(name: "Pulso en reposo", value: "\(Int(current.rounded())) ppm", impact: impact, detail: personalDetail(personal.restingHeartRate, delta: -delta)))
        }

        if let sleep = personal.sleep.current, let expected = personal.sleep.expected, expected > 0 {
            let difference = sleep - expected
            let rawImpact = clamp(Int((difference / max(expected * 0.12, 0.6) * 7).rounded()), -15, 10)
            let impact = confidenceWeighted(rawImpact, confidence: personal.sleep.confidence)
            score += impact
            signals.append(TwinSignal(name: "Sueño", value: String(format: "%.1f h", sleep), impact: impact, detail: String(format: "Tu referencia para hoy es %.1f h · %@", expected, personal.sleep.context)))
        } else if health.snapshot.sleepHours > 0 {
            let sleep = health.snapshot.sleepHours
            let impact = sleep >= 7.5 ? 6 : sleep >= 6.5 ? 1 : -7
            score += impact
            signals.append(TwinSignal(name: "Sueño", value: String(format: "%.1f h", sleep), impact: impact, detail: "Referencia provisional mientras aprendemos tu patrón"))
        }

        if let checkIn {
            let energyImpact = (checkIn.energy - 3) * 3
            let fatigueImpact = (3 - checkIn.fatigue) * 3
            let stressImpact = (3 - checkIn.stress) * 2
            let motivationImpact = checkIn.motivation - 3
            let sleepFeelingImpact = (checkIn.sleepFeeling - 3) * 2
            let sorenessLoad = checkIn.soreness.values.reduce(0, +)
            let sorenessImpact = -min(10, max(0, sorenessLoad - checkIn.soreness.count))
            let painImpact = -min(14, checkIn.painAreas.count * 5)
            let illnessImpact = checkIn.illness ? -22 : 0
            let subjectiveImpact = energyImpact + fatigueImpact + stressImpact + motivationImpact + sleepFeelingImpact + sorenessImpact + painImpact + illnessImpact
            score += subjectiveImpact
            let status: String
            if checkIn.illness { status = "Síntomas de enfermedad declarados" }
            else if !checkIn.painAreas.isEmpty { status = "Molestias: \(checkIn.painAreas.joined(separator: ", "))" }
            else if subjectiveImpact >= 4 { status = "Sensaciones mejores de lo habitual" }
            else if subjectiveImpact <= -5 { status = "Sensaciones aconsejan moderar" }
            else { status = "Sensaciones estables" }
            signals.append(TwinSignal(name: "Check-in", value: "\(checkIn.energy)/5 energía", impact: subjectiveImpact, detail: status))
        }

        for event in events where event.date <= now && now.timeIntervalSince(event.date) <= 7 * 86_400 {
            let ageHours = now.timeIntervalSince(event.date) / 3600
            if event.alcoholDrinks > 0 && ageHours <= 36 {
                let learned = learnedHabit(.alcohol)
                let impact = -min(15, event.alcoholDrinks * 3) + learned.impact
                score += impact
                signals.append(TwinSignal(name: "Alcohol", value: "\(event.alcoholDrinks) bebidas", impact: impact,
                    detail: "Registrado recientemente; se aplica una cautela temporal." + learned.detail))
            }
            if event.saunaMinutes > 0 && ageHours <= 36 {
                let learned = learnedHabit(.sauna)
                score += learned.impact
                signals.append(TwinSignal(name: "Sauna", value: "\(event.saunaMinutes) min", impact: learned.impact,
                    detail: "Registrada para estudiar su relación con hidratación, sueño y recuperación." + learned.detail))
            }
            if event.coldMinutes > 0 && ageHours <= 36 {
                let learned = learnedHabit(.cold)
                score += learned.impact
                signals.append(TwinSignal(name: "Agua fría", value: "\(event.coldMinutes) min", impact: learned.impact,
                    detail: "Registrada como contexto." + learned.detail))
            }
            // Same treatment as sauna/agua fría above: no guessed acute
            // effect for any of these — magnesium, melatonin and
            // ashwagandha are typically taken before sleep, so the next
            // morning's readiness read is exactly the window worth
            // checking; creatine and L-theanine are less time-bound but
            // get the same window for consistency. Only a real, personally
            // learned pattern (via learnedHabit) ever moves the score.
            // Ages off `supplementsDate` (falling back to the event's own
            // date, same as caffeineDate does) rather than the shared
            // `ageHours` above — a dose logged for yesterday but timed
            // separately for this morning shouldn't inherit yesterday's age.
            let supplementAgeHours = now.timeIntervalSince(event.supplementsDate ?? event.date) / 3600
            if supplementAgeHours <= 36 {
                for supplement in event.supplements {
                    let kind = HabitKind.forSupplement(supplement)
                    let learned = learnedHabit(kind)
                    score += learned.impact
                    signals.append(TwinSignal(name: supplement.rawValue, value: "Registrado", impact: learned.impact,
                        detail: "Registrado para estudiar su relación con tu HRV, pulso y sueño." + learned.detail))
                }
            }
            // Falls back to `event.date` — never leave caffeine's effect
            // silently dropped just because caffeineDate itself is nil
            // (the common case: nothing has explicitly overridden the
            // "Hora de consumo" picker away from the event's own date/time).
            let consumed = event.caffeineDate ?? event.date
            if event.caffeineMg > 0, consumed <= now {
                let caffeineAge = now.timeIntervalSince(consumed) / 3600
                if caffeineAge <= 18 {
                    let remaining = Double(event.caffeineMg) * pow(0.5, caffeineAge / 5)
                    let isLate = Calendar.current.component(.hour, from: consumed) >= 14
                    let learned = isLate ? learnedHabit(.lateCaffeine) : (impact: 0, detail: "")
                    score += learned.impact
                    signals.append(TwinSignal(name: "Cafeína", value: "\(event.caffeineMg) mg", impact: learned.impact,
                        detail: "Quedan aproximadamente \(Int(remaining.rounded())) mg según una semivida provisional de 5 h; no es una medición clínica." + learned.detail))
                }
            }
            if event.hydration == .low && ageHours <= 24 {
                let compounded = event.alcoholDrinks > 0 || event.saunaMinutes > 0
                let learned = learnedHabit(.lowHydration)
                let impact = (compounded ? -5 : -2) + learned.impact
                score += impact
                signals.append(TwinSignal(name: "Hidratación", value: "Baja", impact: impact,
                    detail: (compounded ? "Hidratación baja combinada con alcohol o sauna; conviene corregirla antes de añadir carga." : "Declarada baja; se aplica una cautela pequeña.") + learned.detail))
            }
            if (!event.digestiveSymptoms.isEmpty || event.lateDinner || event.heavyDinner) && ageHours <= 24 {
                let learned = learnedHabit(.lateOrHeavyDinner)
                let impact = (event.digestiveSymptoms.isEmpty ? 0 : -3) + learned.impact
                score += impact
                let context = event.digestiveSymptoms.isEmpty ? "Cena tardía o copiosa registrada para interpretar el sueño posterior." : event.digestiveSymptoms.joined(separator: ", ")
                signals.append(TwinSignal(name: "Digestión", value: event.digestiveSymptoms.isEmpty ? "Contexto" : "Molestias", impact: impact, detail: context + learned.detail))
            }
            if (event.fastingHours > 0 || event.trainedFasted) && ageHours <= 24 {
                let learned: (impact: Int, detail: String)
                if event.trainedFasted {
                    learned = learnedHabit(.fastedTraining)
                } else if event.fastingHours >= 12 {
                    learned = learnedHabit(.fasting)
                } else {
                    learned = (impact: 0, detail: "")
                }
                score += learned.impact
                let signalName = event.trainedFasted ? "Entrenamiento en ayunas" : "Ayuno"
                let value = event.fastingHours > 0 ? "\(event.fastingHours) h" : "Registrado"
                let detail = event.trainedFasted
                    ? "Se conserva como contexto de la sesión. No penaliza por defecto: Éter solo aplicará un efecto cuando exista un patrón personal con confianza suficiente."
                    : "Se conserva como contexto metabólico."
                signals.append(TwinSignal(name: signalName, value: value, impact: learned.impact,
                    detail: detail + learned.detail))
            }
            if (event.foodQuality == .healthy || event.foodQuality == .indulgent) && ageHours <= 24 {
                let kind: HabitKind = event.foodQuality == .healthy ? .healthyFood : .indulgentFood
                let learned = learnedHabit(kind)
                score += learned.impact
                signals.append(TwinSignal(
                    name: "Alimentación", value: event.foodQuality.rawValue, impact: learned.impact,
                    detail: "Registro declarado; por sí solo no se interpreta como bueno o malo para la disponibilidad." + learned.detail
                ))
            }
            if event.electrolytes && ageHours <= 24 && !appliedElectrolytes {
                let mitigation = HabitAssociationEngine.electrolyteMitigation(
                    hydrationLow: event.hydration == .low,
                    saunaMinutes: event.saunaMinutes,
                    prolongedExerciseMinutes: prolongedExerciseMinutes
                )
                appliedElectrolytes = true
                if mitigation > 0 {
                    score += mitigation
                    signals.append(TwinSignal(
                        name: "Electrolitos", value: "Registrados", impact: mitigation,
                        detail: "Compensan parcialmente la cautela por hidratación, calor o ejercicio prolongado; no se interpretan como recuperación adicional."
                    ))
                } else {
                    signals.append(TwinSignal(
                        name: "Electrolitos", value: "Registrados", impact: 0,
                        detail: "Sin un estresor compatible registrado, se conservan como contexto y no modifican la puntuación."
                    ))
                }
            }
        }

        if let review = reviews.first(where: { $0.workoutDate <= now && now.timeIntervalSince($0.workoutDate) <= 36 * 3600 }) {
            var impact = review.effort >= 9 ? -6 : review.effort >= 7 ? -3 : 0
            if review.outcome == .worse { impact -= 3 }
            if review.pain { impact -= 8 }
            score += impact
            let detail = review.pain ? "Declaraste dolor o molestias; la recomendación debe ser conservadora." : "Tu esfuerzo y margen declarados afinan la carga real de la última sesión."
            signals.append(TwinSignal(name: "Post-entreno", value: "RPE \(review.effort)/10", impact: impact, detail: detail))
        }

        for injury in activeInjuries {
            let impact = -min(12, injury.severity * 2)
            score += impact
            signals.append(TwinSignal(name: "Restricción activa", value: injury.area, impact: impact,
                                      detail: injury.restrictions.map(\.rawValue).sorted().joined(separator: ", ")))
        }

        if let session = completedSessionToday(health.recentWorkouts, now: now) {
            let penalty = postSessionPenalty(session)
            score += penalty
            let distance = session.distanceKilometers.map { String(format: " · %.1f km", $0) } ?? ""
            signals.append(TwinSignal(
                name: "Sesión de hoy", value: "\(Int(session.durationMinutes.rounded())) min\(distance)", impact: penalty,
                detail: "Carga ya realizada hoy; la recomendación pasa de planificar a asimilar la sesión."
            ))
        }

        let trainingLoad = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        // PR3d: la misma guidance por canal que gatea el plan
        // (TrainingPlanEngine.status via governingRatio), no la combinada.
        // Con la mezcla, el score podía no penalizar una sobrecarga real de
        // un solo canal que el plan sí frenaba: el número que ves en Hoy
        // decía "todo bien" y la recomendación del mismo día decía recuperar.
        let loadGuidance = trainingLoad.dual.guidance
        let loadImpact: Int
        switch loadGuidance {
        case .absorb: loadImpact = -3
        case .deload: loadImpact = -5
        case .overload: loadImpact = -10
        default: loadImpact = 0
        }
        if loadImpact != 0 || loadGuidance == .returning {
            score += loadImpact
            signals.append(TwinSignal(
                name: "Carga acumulada",
                // Dice de qué canal, porque "×1.60" a secas era justo lo que
                // el ratio combinado no sabía atribuir.
                value: "×\(trainingLoad.dual.governingRatio.formatted(.number.precision(.fractionLength(2)))) \(trainingLoad.dual.governingChannel)",
                impact: loadImpact,
                detail: loadGuidance.advice
            ))
        }

        let muscleReadiness = calculateMuscles(imports.workouts, healthWorkouts: health.recentWorkouts, learnedRecovery: personal.muscleRecoveryHours, checkIn: checkIn, now: now)
        let fatiguedCount = muscleReadiness.filter { $0.readiness < 55 }.count
        if fatiguedCount >= 4 { score -= 7 }

        if calibration.scoreAdjustment != 0 {
            score += calibration.scoreAdjustment
            let direction = calibration.scoreAdjustment > 0 ? "subestimaba" : "sobreestimaba"
            signals.append(TwinSignal(
                name: "Calibración personal",
                value: String(format: "%+d pt", calibration.scoreAdjustment),
                impact: calibration.scoreAdjustment,
                detail: "En sus últimas \(calibration.observations) comparaciones, el modelo \(direction) tu disponibilidad. Ajuste limitado y ponderado por una confianza del \(calibration.confidence)%."
            ))
        }
        score = clamp(score, 0, 100)

        // PR15: el viaje, una sola vez y antes de que nada más lo necesite.
        // Los confusores salen de datos que esta función YA tiene, así que el
        // motor no necesita leer ningún store para saber que este episodio no
        // sirve para aprender con el mismo peso.
        var confounders: TravelConfounders = []
        if checkIn?.illness == true { confounders.insert(.illness) }
        if !activeInjuries.isEmpty { confounders.insert(.injury) }
        if TrainingPlanEngine.eventToday(now, profile: context.profile) != nil { confounders.insert(.race) }
        if events.contains(where: { $0.alcoholDrinks > 0 && now.timeIntervalSince($0.date) <= 36 * 3_600 }) {
            confounders.insert(.alcohol)
        }
        if PerformanceEngine.summarize(health: health, imports: imports, now: now).dual.guidance == .overload {
            confounders.insert(.extraordinaryLoad)
        }
        // PR16: lo aprendido de los tramos ya medidos. Función pura del
        // historial, sin tocar HealthKit — por eso funciona con episodios de
        // hace dos años, cuando las series de sueño y HRV de aquellos días ya
        // no existen.
        let travelRates = TravelLearningEngine.profile(episodes: context.travelHistory).rates
        let travelImpact = TravelImpactEngine.impact(
            episode: context.travel, at: now,
            signals: TravelSignalContext(
                baseline: personal, sleepHistory: health.sleepHistory, hrvHistory: health.hrvHistory,
                restingHeartRateHistory: health.restingHeartRateHistory,
                sleepSchedule: health.sleepScheduleHistory, confounders: confounders
            ),
            rates: travelRates
        )
        // DOS señales y no una. La señal "Viaje" única de antes escondía cuál
        // de los dos fenómenos mandaba, y decaen a ritmos muy distintos: un
        // Madrid–Buenos Aires fatiga mucho y desajusta poco; un Madrid–Nueva
        // York al revés. El coste sale de TravelImpact, la misma definición que
        // usa la proyección de mañana en TwinReadout.derive.
        if travelImpact.isMeaningful {
            let learned = learnedHabit(.travel)
            if travelImpact.circadianReadinessCost != 0 {
                let impact = travelImpact.circadianReadinessCost + learned.impact
                score += impact
                signals.append(TwinSignal(
                    name: "Desajuste circadiano",
                    value: String(format: "%.0f h", abs(travelImpact.circadianOffsetHours)),
                    impact: impact,
                    detail: "\(travelImpact.phase.rawValue) de \(context.travel?.title ?? "tu viaje"). "
                        + travelImpact.confidence.reason + learned.detail
                ))
            }
            if travelImpact.fatigueReadinessCost != 0 {
                score += travelImpact.fatigueReadinessCost
                let causes = travelImpact.structuralFactors.filter { if case .circadianOffset = $0 { return false } else { return true } }
                signals.append(TwinSignal(
                    name: "Fatiga de viaje",
                    value: "\(Int((travelImpact.travelFatigue * 100).rounded()))%",
                    impact: travelImpact.fatigueReadinessCost,
                    detail: causes.isEmpty
                        ? "Fatiga de tránsito, que se resuelve en horas o pocos días — distinta del desajuste horario."
                        : causes.map { $0.description }.joined(separator: " · ") + ". Se resuelve en horas o pocos días, a diferencia del desajuste horario."
                ))
            }
        }

        let plan = TrainingPlanEngine.status(health: health, imports: imports, readiness: score, muscles: muscleReadiness, checkIn: checkIn,
                                             context: context, physiologicalAlert: physiologicalAlert,
                                             travel: travelImpact, now: now)
        // PR8: el titular sale del plan (kind + patrón ya elegido y ya
        // compatible con las restricciones activas), no de un segundo
        // selector de patrón aquí ni de una reescritura por substrings del
        // texto ya renderizado. Ver TrainingPlanEngine.headline y
        // InjurySafetyEngine.allows/allowedPatterns.
        let recommendation = TrainingPlanEngine.headline(for: plan.nextSession, pattern: plan.strengthPattern, readiness: score)
        let state = TwinReadout.label(for: score)
        let explanation = explanation(score: score, signals: signals, muscles: muscleReadiness) + " " + plan.rationale

        // PR2: today's real vector, and tomorrow's prediction stepped from
        // it — see TwinAssessment's own comment for why score/muscles
        // above stay exactly as they were (real signals, unchanged).
        let sleepDebtHours = (personal.sleep.current).flatMap { current in
            personal.sleep.expected.map { expected in max(0, expected - current) }
        } ?? 0
        // Las desviaciones de HOY, medidas, entran en el estado: son la misma
        // PersonalBaselineProfile que las señales de arriba ya usan, así que no
        // hay una segunda pasada sobre HRV/pulso que pueda discrepar.
        let physiology = TwinPhysiology.derive(health: health, imports: imports, muscleReadiness: muscleReadiness,
                                               hrvDeviation: personal.hrv.deviation ?? 0,
                                               restingHeartRateDeviation: personal.restingHeartRate.deviation ?? 0,
                                               sleepDebtHours: sleepDebtHours, illness: checkIn?.illness ?? false,
                                               travel: travelImpact, now: now)
        let readout = TwinReadout(score: score, state: state, confidence: personal.confidence)
        // No hay forma honesta de conocer hoy el HRV/sueño/check-in reales
        // de mañana — RecoverySignals.none dice explícitamente "sin
        // información nueva", no "todo normal". El único dato real que
        // step() sí tiene es la sesión que el plan propone para hoy, la
        // misma que folded into el propio weekAhead.
        //
        // Eso sigue siendo cierto y por eso se pasa .none. Lo que SÍ llega a
        // mañana es la desviación autonómica medida hoy, que ya viaja dentro
        // de `physiology` y que step() decae hacia la base: no se asume un HRV
        // futuro, se arrastra el de hoy perdiendo peso. Antes esa medición no
        // entraba en el vector en absoluto, así que dos atletas con la misma
        // carga y un HRV muy distinto predecían el mismo mañana.
        let tomorrowPhysiology = step(physiology, session: SessionLoad.forecast(plan.nextSession),
                                      recoverySignals: .none, dtDays: 1, rates: travelRates)
        let predictedTomorrow = TwinReadout.derive(from: tomorrowPhysiology, anchor: anchor, calibration: calibration)

        return TwinAssessment(score: score, state: state, recommendation: recommendation, explanation: explanation, signals: signals, muscles: muscleReadiness, baselineConfidence: personal.confidence, physiologicalAlert: physiologicalAlert, physiology: physiology, readout: readout, travel: travelImpact, travelRates: travelRates, predictedTomorrow: predictedTomorrow)
    }

    private static func calculateMuscles(_ workouts: [ImportedWorkout], healthWorkouts: [HealthWorkout], learnedRecovery: [String: Double], checkIn: DailyCheckIn?, now: Date) -> [MuscleReadiness] {
        let names = ["Cuádriceps", "Glúteos", "Isquios", "Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Core", "Gemelos"]
        // Computed once per workout, not once per muscle per workout — and
        // from effectiveMuscleSets (recomputed from exercises/setDetails),
        // never the stored muscleSets field. Reading the stored field here
        // was exactly the bug: the radar showed corrected, warm-up-
        // filtered, discount-weighted numbers while this fatigue model —
        // the one actually driving today's plan and "Cobertura" — kept
        // reading the pre-refinement numbers for the same historical
        // session, since nothing recomputed them for anyone but the radar.
        let effectiveByWorkout = workouts.filter { $0.start <= now }.map { ($0, $0.effectiveMuscleSets) }
        return names.map { muscle in
            var fatigue = 0.0
            var recentSets = 0
            var last: Date?
            for (workout, effectiveSets) in effectiveByWorkout {
                guard let sets = effectiveSets[muscle], sets > 0 else { continue }
                if last == nil || workout.start > last! { last = workout.start }
                let hours = max(0, now.timeIntervalSince(workout.start) / 3600)
                if hours <= 168 { recentSets += Int(sets.rounded()) }
                let halfLife = (learnedRecovery[muscle] ?? 72) / 2
                fatigue += Double(sets) * 5.2 * pow(0.5, hours / halfLife)
            }
            for workout in healthWorkouts where workout.date <= now {
                // Hevy sessions are already represented with richer CSV data.
                guard !workout.source.lowercased().contains("hevy"), let involvement = workout.muscleGroups[muscle] else { continue }
                let mirroredStrength = (workout.activity == "Fuerza" || workout.activity == "Fuerza funcional") && workouts.contains { imported in
                    abs(imported.start.timeIntervalSince(workout.date)) <= 3 * 60 &&
                    abs(imported.end.timeIntervalSince(imported.start) - workout.durationMinutes * 60) <= 8 * 60
                }
                guard !mirroredStrength else { continue }
                let hours = max(0, now.timeIntervalSince(workout.date) / 3600)
                let load = min(55, max(8, workout.durationMinutes * 0.85)) * involvement
                fatigue += load * pow(0.5, hours / 30)
                if last == nil || workout.date > last! { last = workout.date }
            }
            let subjective = sorenessIntensity(for: muscle, checkIn: checkIn)
            let subjectivePenalty = [0, 7, 17, 30][max(0, min(3, subjective))]
            return MuscleReadiness(name: muscle, readiness: clamp(Int((100 - fatigue).rounded()) - subjectivePenalty, 0, 100), lastTrained: last, recentSets: recentSets)
        }.sorted { $0.readiness > $1.readiness }
    }

    private static func completedSessionToday(_ workouts: [HealthWorkout], now: Date) -> HealthWorkout? {
        workouts.filter { workout in
            Calendar.current.isDate(workout.date, inSameDayAs: now) &&
            workout.date.addingTimeInterval(workout.durationMinutes * 60) <= now
        }.max { $0.date < $1.date }
    }

    private static func postSessionPenalty(_ workout: HealthWorkout) -> Int {
        if workout.activity == "Carrera" {
            if (workout.distanceKilometers ?? 0) >= 10 || workout.durationMinutes >= 60 { return -14 }
            if workout.durationMinutes >= 35 { return -9 }
            return -5
        }
        if workout.activity.contains("Intervalos") { return -12 }
        return workout.durationMinutes >= 45 ? -7 : -4
    }

    private static func explanation(score: Int, signals: [TwinSignal], muscles: [MuscleReadiness]) -> String {
        let positive = signals.max { $0.impact < $1.impact }
        let negative = signals.min { $0.impact < $1.impact }
        let tired = muscles.sorted { $0.readiness < $1.readiness }.prefix(2).map(\.name).joined(separator: " y ")
        var parts: [String] = []
        if let positive, positive.impact > 0 { parts.append("\(positive.name) favorece tu disponibilidad") }
        if let negative, negative.impact < 0 { parts.append("\(negative.name) aconseja moderar la carga") }
        if !tired.isEmpty { parts.append("\(tired) son las zonas menos recuperadas") }
        if parts.isEmpty { parts.append(score >= 62 ? "Tus señales están cerca de su línea base" : "Faltan señales suficientes; la recomendación es prudente") }
        return parts.joined(separator: ". ") + "."
    }

    private static func comparison(_ delta: Double) -> String {
        let percent = abs(delta * 100)
        if percent < 3 { return "En tu línea base" }
        return delta > 0 ? String(format: "%.0f%% sobre tu base", percent) : String(format: "%.0f%% bajo tu base", percent)
    }

    private static func personalDetail(_ baseline: PersonalMetricBaseline, delta: Double) -> String {
        let expected = baseline.expected ?? 0
        let direction = comparison(delta)
        return "\(direction) (tu referencia: \(expected.formatted(.number.precision(.fractionLength(0...1))))) · \(baseline.context)"
    }

    private static func confidenceWeighted(_ impact: Int, confidence: Int) -> Int {
        Int((Double(impact) * (0.35 + 0.65 * Double(confidence) / 100)).rounded())
    }

    private static func sorenessIntensity(for muscle: String, checkIn: DailyCheckIn?) -> Int {
        guard let soreness = checkIn?.soreness else { return 0 }
        let area: String
        switch muscle {
        case "Cuádriceps", "Isquios", "Gemelos": area = "Piernas"
        case "Glúteos": area = "Glúteos"
        case "Pecho": area = "Pecho"
        case "Espalda": area = "Espalda"
        case "Hombros": area = "Hombros"
        case "Bíceps", "Tríceps": area = "Brazos"
        case "Core": area = "Core"
        default: return 0
        }
        return soreness[area] ?? 0
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(high, max(low, value)) }
}
