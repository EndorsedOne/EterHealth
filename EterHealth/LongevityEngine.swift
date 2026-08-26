import Foundation

enum LongevityPillar: String, CaseIterable, Identifiable {
    case functional = "Reserva funcional"
    case protection = "Protección cardiometabólica"
    case resilience = "Resiliencia"
    var id: String { rawValue }
}

struct LongevityDimension: Identifiable {
    var id: String { name }
    let name: String
    let pillar: LongevityPillar
    let score: Int
    let weight: Double
    let confidence: TrustLevel
    let evidence: String
}

struct LongevityPillarScore: Identifiable {
    var id: LongevityPillar { pillar }
    let pillar: LongevityPillar
    let score: Int
    let coverage: Int
}

struct LongevityIndex {
    let score: Int?
    let coverage: Int
    let confidence: TrustLevel
    let dimensions: [LongevityDimension]
    let pillars: [LongevityPillarScore]
    let priority: String?
    let missing: [String]
}

@MainActor
enum LongevityEngine {
    static func calculate(health: HealthStore, imports: ImportStore, injuries: InjuryStore? = nil,
                          now: Date = Date()) -> LongevityIndex {
        let injuries = injuries ?? .shared
        var dimensions: [LongevityDimension] = []
        var missing: [String] = []

        let systolic = health.systolicBloodPressureHistory.last?.value
        let diastolic = health.diastolicBloodPressureHistory.last?.value
        let resting = health.restingHeartRateHistory.suffix(14).map(\.value)
        var cardiovascular: [Double] = []
        if let systolic, let diastolic { cardiovascular.append(bloodPressureScore(systolic: systolic, diastolic: diastolic)) }
        else { missing.append("tensión arterial") }
        if !resting.isEmpty { cardiovascular.append(descendingScore(average(resting), ideal: 50, poor: 85)) }
        if !cardiovascular.isEmpty {
            dimensions.append(dimension(
                "Cardiovascular", .protection, cardiovascular, weight: 0.14,
                samples: health.systolicBloodPressureHistory.count + health.diastolicBloodPressureHistory.count + resting.count,
                evidence: evidence([systolic == nil ? nil : "tensión", resting.isEmpty ? nil : "pulso en reposo"])
            ))
        }

        if let vo2 = health.vo2MaxHistory.last?.value {
            dimensions.append(dimension(
                "Capacidad aeróbica", .functional, [ascendingScore(vo2, poor: 25, ideal: 50)],
                weight: 0.18, samples: health.vo2MaxHistory.count,
                evidence: "VO₂ máx. \(vo2.formatted(.number.precision(.fractionLength(1)))) ml/kg/min"
            ))
        } else { missing.append("VO₂ máx.") }

        // "hemoglobina glicosilada" never matched anything: the parser stores this
        // lab as "Hemoglobina glicada A1c" (glicada, not glicosilada) — HbA1c was
        // silently excluded from this domain until now.
        let metabolicNames = ["glucosa", "hba1c", "hemoglobina glicada", "ldl", "hdl", "triglic"]
        let metabolic = latestDistinctLabs(imports.labs, matching: metabolicNames)
        if !metabolic.isEmpty {
            let scores = metabolic.map { $0.status == "En rango" ? 85.0 : 45.0 }
            dimensions.append(dimension(
                "Metabólica", .protection, scores, weight: 0.16, samples: metabolic.count,
                evidence: "\(metabolic.count) marcadores con los rangos de sus informes"
            ))
        } else { missing.append("glucosa, HbA1c y lípidos") }

        // Endurance-athlete ("sports") anemia is common enough in runners that it
        // deserves its own signal, not just a hidden PhenoAge input. Same
        // in-range-vs-own-lab-range approach as "Metabólica" above — no invented
        // clinical cutoffs, just each marker's own reported reference range.
        // More specific substrings must be checked before "hemoglobina" itself —
        // latestDistinctLabs takes the FIRST matching key per lab, and "hemoglobina"
        // is also a substring of the MCH/MCHC entries below.
        //
        // A plain hemogram (Hb/Hto/VCM/HCM/CHCM/hematíes) only flags anemia once
        // it's already frank — iron-deficiency without anemia ("sports anemia" in
        // its earlier, more common form) shows up first as low ferritin with a
        // still-normal hemogram, which this dimension used to score as a clean
        // 100%. Ferritina and saturación transferrina are already imported
        // (ImportStore's lab patterns) but weren't part of this signal — added
        // here since they're the standard earlier-warning iron markers athletes'
        // panels actually track.
        // Names here must stay diacritic-free ("saturacion", not "saturación")
        // since `normalized` below has already had its accents folded away —
        // an accented literal would silently never match.
        let anemiaNames = ["hemoglobina corpuscular media", "conc. hemoglobina corpuscular",
                            "volumen corpuscular medio", "hematocrito", "hematies", "hemoglobina",
                            "saturacion transferrina", "ferritina"]
        let anemiaLabs = latestDistinctLabs(imports.labs, matching: anemiaNames)
        if anemiaLabs.count >= 3 {
            let inRange = anemiaLabs.filter { $0.status == "En rango" }
            let score = Double(inRange.count) / Double(anemiaLabs.count) * 100
            dimensions.append(dimension(
                "Riesgo de anemia del deportista", .protection, [score], weight: 0.06, samples: anemiaLabs.count,
                evidence: "\(inRange.count)/\(anemiaLabs.count) marcadores (Hb, Hto, VCM, HCM, CHCM, ferritina, saturación de transferrina) dentro de su propio rango de laboratorio"
            ))
        } else { missing.append("hemograma completo y marcadores de hierro para riesgo de anemia") }

        // Urea is a recognized training-stress/hydration marker in athletes
        // (rises with real overreaching) — surfaced as its own signal now that
        // it's captured, rather than only feeding another calculation.
        if let urea = imports.labs.filter({ $0.name == "Urea" }).max(by: { $0.date < $1.date }) {
            let score = urea.status == "En rango" ? 82.0 : urea.status == "Alto" ? 45.0 : 60.0
            dimensions.append(dimension(
                "Estrés de entrenamiento (Urea)", .resilience, [score], weight: 0.05, samples: 1,
                evidence: "Urea \(urea.value.formatted(.number.precision(.fractionLength(0...1)))) \(urea.unit) · \(urea.status.lowercased()) frente a su rango de laboratorio"
            ))
        } else { missing.append("urea") }

        let strength = StrengthProgressEngine.summarize(imports.workouts, now: now)
        if strength.totalHistorySessions > 0 {
            let sessionScore = min(100.0, Double(strength.sessions28Days) / 8 * 100)
            let patternCoverage = Double(strength.patterns.filter { $0.sets > 0 }.count) / 5 * 100
            dimensions.append(dimension(
                "Fuerza", .functional, [sessionScore, patternCoverage], weight: 0.14,
                samples: strength.totalHistorySessions,
                evidence: "\(strength.sessions28Days) sesiones/28 días · \(strength.patterns.filter { $0.sets > 0 }.count)/5 patrones"
            ))
        } else { missing.append("historial de fuerza") }

        // Daily steps — real NEAT/general movement, independent of
        // structured training and previously fetched (HealthStore already
        // queries and stores it) but never used anywhere: not shown, not
        // scored, not a lever for anything. 10,000/day is the well-known
        // reference number, not a precise clinical cutoff (it began as a
        // 1960s pedometer marketing figure) — ascendingScore's "poor"
        // floor at 4,000 keeps a genuinely sedentary pattern from scoring
        // near zero outright.
        let stepsRecent = health.stepsHistory.suffix(14).map(\.value)
        if stepsRecent.count >= 5 {
            let averageSteps = average(stepsRecent)
            // The score keeps 10.000 as a fixed evidence-based reference
            // (real gains up to roughly that range, then diminishing
            // returns) so it stays comparable over time. The target named
            // in the evidence text is the personalized one shown in the
            // Hoy tile instead — same number the person is actually
            // chasing today, not a second, disconnected figure.
            let (personalTarget, isPersonalized) = TrainingPlanEngine.personalizedStepTarget(stepsHistory: health.stepsHistory, now: now)
            dimensions.append(dimension(
                "Actividad diaria", .functional, [ascendingScore(averageSteps, poor: 4_000, ideal: 10_000)],
                weight: 0.08, samples: stepsRecent.count,
                evidence: "Media de \(Int(averageSteps.rounded())) pasos/día (14 días)" + (isPersonalized ? " · objetivo personal: \(personalTarget)" : " frente a una referencia de 10.000")
            ))
        } else { missing.append("historial de pasos") }

        if let bodyFat = health.bodyFatHistory.last?.value {
            // Deliberately broad until age, sex and measurement method are configured.
            let score = bodyFat >= 10 && bodyFat <= 30 ? 80.0 : bodyFat >= 7 && bodyFat <= 35 ? 60.0 : 40.0
            dimensions.append(dimension(
                "Composición", .protection, [score], weight: 0.08,
                samples: health.bodyFatHistory.count,
                evidence: "Grasa corporal \(bodyFat.formatted(.number.precision(.fractionLength(1))))% · banda amplia no clínica"
            ))
        } else if health.bodyWeightHistory.count >= 3 {
            dimensions.append(dimension(
                "Composición", .protection, [65], weight: 0.08,
                samples: health.bodyWeightHistory.count,
                evidence: "Tendencia de peso disponible; falta composición corporal"
            ))
        } else { missing.append("composición corporal") }

        // Moved above the sleep block below so "Recuperación" can reuse the
        // same personal baseline HRV/resilience already computes from,
        // instead of a second, separate PersonalBaselineEngine call.
        let baseline = PersonalBaselineEngine.profile(health: health, imports: imports, now: now)

        let sleep = health.sleepHistory.suffix(14).map(\.value)
        if !sleep.isEmpty {
            let hours = average(sleep)
            // A fixed 7-9h band alone treats a habitual 6.5h sleeper and a
            // habitual 8.5h sleeper identically to whether either is
            // currently sleeping enough FOR THEM — it only ever asked
            // "how much sleep in absolute terms," never "relative to this
            // person's own trend" or "have the last several nights been
            // adding up to a real shortfall." Three components now, each
            // answering a different one of those questions:
            var components = [hours >= 7 && hours <= 9 ? 85.0 : hours >= 6 && hours <= 10 ? 65.0 : 40.0]
            var evidenceParts = ["Sueño medio \(hours.formatted(.number.precision(.fractionLength(1)))) h"]
            // 1. Personal trend: the same favorableHigh-corrected z-score
            // PersonalBaselineEngine already computes for HRV/pulso below,
            // reused here rather than reinventing a second definition of
            // "relative to your own habitual."
            if let deviation = baseline.sleep.deviation {
                components.append(deviation >= 0.15 ? 85.0 : deviation >= -0.5 ? 70.0 : deviation >= -1.5 ? 50.0 : 30.0)
                evidenceParts.append(deviation >= 0.15 ? "por encima de tu habitual" : deviation < -0.5 ? "por debajo de tu habitual" : "en línea con tu habitual")
            }
            // 2. Sleep debt: cumulative shortfall against this person's own
            // habitual over the real last week — a single short night
            // buried inside a 14-day average can otherwise disappear
            // completely, while several short nights in a row (the thing
            // that actually accumulates fatigue) previously read no
            // differently from one bad night spread across two weeks.
            let recentWeek = Array(sleep.suffix(7))
            if let expected = baseline.sleep.expected, recentWeek.count >= 3 {
                let debtHours = recentWeek.reduce(0.0) { $0 + max(0, expected - $1) }
                components.append(debtHours <= 1 ? 90.0 : debtHours <= 3 ? 70.0 : debtHours <= 6 ? 45.0 : 20.0)
                if debtHours > 1 { evidenceParts.append("deuda de \(debtHours.formatted(.number.precision(.fractionLength(1)))) h en 7 noches") }
            }
            // 3. Schedule regularity: bedtime/wake-time consistency, a real
            // circadian factor a duration-only view has no way to see —
            // nil while real nightly schedule history is still
            // accumulating (sleepScheduleHistory only just started being
            // recorded), never a guessed score from too few nights.
            var regularityNights: Int?
            if let regularity = SleepRegularityEngine.evaluate(health.sleepScheduleHistory) {
                components.append(regularity.score)
                evidenceParts.append(regularity.evidence)
                regularityNights = regularity.samples
            }
            let injuryPenalty = min(20.0, Double(injuries.active.reduce(0) { $0 + $1.severity }) * 3)
            // Confidence must reflect the WEAKEST-evidenced ingredient,
            // not just how much duration history happens to exist —
            // regularity needs real, clean bedtime/wake samples (fewer
            // nights qualify than plain duration does, since some nights'
            // HealthKit data won't have distinguishable sleep stages), so
            // riding on sleep.count alone could report high confidence
            // for a dimension whose regularity component is still thin.
            let confidenceSamples = regularityNights.map { min(sleep.count, $0) } ?? sleep.count
            dimensions.append(dimension(
                "Recuperación", .resilience, [max(0, average(components) - injuryPenalty)], weight: 0.12,
                samples: confidenceSamples,
                evidence: evidenceParts.joined(separator: " · ") + (injuries.active.isEmpty ? "" : " · restricciones activas")
            ))
        } else { missing.append("historial de sueño") }

        // A deliberately separate dimension from "Recuperación" above —
        // that one asks how much you slept and how consistently; this
        // one asks what that sleep was actually made of. Two nights of
        // equal duration and equal regularity can still be very
        // differently restorative depending on how much was deep and
        // REM, which duration/regularity alone can't see. See
        // SleepArchitectureEngine's own header for why this exists and
        // its measurement caveats.
        if let architecture = SleepArchitectureEngine.evaluate(health.sleepStagesHistory) {
            dimensions.append(dimension(
                "Arquitectura del sueño", .resilience, [Double(architecture.score)], weight: 0.07,
                samples: architecture.nights, evidence: architecture.evidence
            ))
        } else { missing.append("fases de sueño (profundo/REM) suficientes") }

        var resilience: [Double] = []
        var resilienceEvidence: [String] = []
        if let deviation = baseline.hrv.deviation {
            resilience.append(deviation >= 0 ? 85 : deviation >= -1 ? 72 : deviation >= -1.5 ? 58 : 42)
            resilienceEvidence.append("HRV frente a tu base")
        }
        let heartRecovery = health.heartRateRecoveryHistory.suffix(5).map(\.value)
        if !heartRecovery.isEmpty {
            resilience.append(ascendingScore(average(heartRecovery), poor: 10, ideal: 30))
            resilienceEvidence.append("recuperación cardiaca")
        }
        if !resilience.isEmpty {
            dimensions.append(dimension(
                "Resiliencia fisiológica", .resilience, resilience, weight: 0.10,
                samples: baseline.hrv.samples + heartRecovery.count,
                evidence: resilienceEvidence.joined(separator: " + ")
            ))
        } else { missing.append("HRV y recuperación cardiaca") }

        let activityDates = health.workoutHistory.map(\.date) + imports.workouts.map(\.start)
        let cutoff = now.addingTimeInterval(-84 * 86_400)
        let activeDays = Set(activityDates.filter { $0 >= cutoff && $0 <= now }.map { Calendar.current.startOfDay(for: $0) })
        if !activeDays.isEmpty {
            let weeklyAverage = Double(activeDays.count) / 12
            let score = weeklyAverage >= 4 ? 90.0 : weeklyAverage >= 3 ? 80 : weeklyAverage >= 2 ? 65 : 45
            dimensions.append(dimension(
                "Continuidad de actividad", .functional, [score], weight: 0.08,
                samples: activeDays.count,
                evidence: "\(activeDays.count) días activos/12 semanas · \(weeklyAverage.formatted(.number.precision(.fractionLength(1)))) por semana"
            ))
        } else { missing.append("continuidad de actividad") }

        return combine(dimensions: dimensions, missing: missing)
    }

    nonisolated static func combine(dimensions: [LongevityDimension], missing: [String] = []) -> LongevityIndex {
        let availableWeight = dimensions.reduce(0) { $0 + $1.weight }
        let weighted = dimensions.reduce(0) { $0 + Double($1.score) * $1.weight }
        // Dimension weights aren't designed to sum to exactly 1.0 when every
        // one of them has data at once, so this could round past 100% without
        // the same clamp already applied to each pillar's own coverage below.
        let coverage = min(100, Int((availableWeight * 100).rounded()))
        let score = availableWeight >= 0.40 ? Int((weighted / availableWeight).rounded()) : nil
        let confidencePoints = dimensions.map {
            $0.confidence == .high ? 90 : $0.confidence == .medium ? 58 : 25
        }
        let confidenceScore = Int((Double(coverage) * 0.65 +
                                   (confidencePoints.isEmpty ? 0 : average(confidencePoints.map(Double.init))) * 0.35).rounded())
        let pillars = LongevityPillar.allCases.compactMap { pillar -> LongevityPillarScore? in
            let values = dimensions.filter { $0.pillar == pillar }
            let weight = values.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { return nil }
            let pillarScore = Int((values.reduce(0) { $0 + Double($1.score) * $1.weight } / weight).rounded())
            let targetWeight = targetWeight(for: pillar)
            return LongevityPillarScore(
                pillar: pillar, score: pillarScore,
                coverage: min(100, Int((weight / targetWeight * 100).rounded()))
            )
        }
        let priority = dimensions
            .filter { $0.confidence != .low }
            .min { $0.score < $1.score }
            .map(priorityText)
        return LongevityIndex(
            score: score, coverage: coverage, confidence: ConfidenceEngine.level(score: confidenceScore),
            dimensions: dimensions.sorted { $0.weight > $1.weight },
            pillars: pillars, priority: priority, missing: missing
        )
    }

    private nonisolated static func dimension(
        _ name: String, _ pillar: LongevityPillar, _ values: [Double],
        weight: Double, samples: Int, evidence: String
    ) -> LongevityDimension {
        LongevityDimension(
            name: name, pillar: pillar, score: Int(average(values).rounded()), weight: weight,
            confidence: ConfidenceEngine.level(samples: samples, medium: 3, high: 10),
            evidence: evidence
        )
    }

    private nonisolated static func targetWeight(for pillar: LongevityPillar) -> Double {
        switch pillar {
        case .functional: return 0.40
        case .protection: return 0.38
        case .resilience: return 0.22
        }
    }

    private nonisolated static func priorityText(_ dimension: LongevityDimension) -> String {
        switch dimension.name {
        case "Capacidad aeróbica": return "La mayor palanca medible es desarrollar capacidad aeróbica de forma progresiva."
        case "Fuerza": return "La mayor palanca medible es recuperar continuidad y equilibrio en fuerza."
        case "Cardiovascular": return "Conviene confirmar y seguir la tendencia cardiovascular; una lectura aislada no basta."
        case "Metabólica": return "La principal oportunidad está en revisar la evolución de los marcadores metabólicos con sus rangos clínicos."
        case "Composición": return "La principal oportunidad medible está en mejorar o completar el seguimiento de composición corporal."
        case "Recuperación": return "La principal oportunidad está en sueño, recuperación y resolución de restricciones activas."
        case "Resiliencia fisiológica": return "La principal oportunidad está en mejorar la respuesta entre carga y recuperación."
        case "Continuidad de actividad": return "La principal oportunidad es aumentar la regularidad semanal sin saltos bruscos de carga."
        case "Actividad diaria": return "La principal palanca es aumentar el movimiento cotidiano — no solo el entrenamiento estructurado — con paseos o más pasos repartidos en el día."
        default: return "Prioriza la dimensión peor puntuada con datos suficientes."
        }
    }

    private nonisolated static func bloodPressureScore(systolic: Double, diastolic: Double) -> Double {
        if systolic < 90 || diastolic < 55 { return 55 }
        if systolic < 120 && diastolic < 80 { return 90 }
        if systolic < 130 && diastolic < 85 { return 78 }
        if systolic < 140 && diastolic < 90 { return 62 }
        return 40
    }

    private nonisolated static func ascendingScore(_ value: Double, poor: Double, ideal: Double) -> Double {
        min(100, max(25, 25 + (value - poor) / max(1, ideal - poor) * 65))
    }

    private nonisolated static func descendingScore(_ value: Double, ideal: Double, poor: Double) -> Double {
        min(100, max(25, 90 - (value - ideal) / max(1, poor - ideal) * 65))
    }

    private nonisolated static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(1, values.count))
    }

    private static func evidence(_ values: [String?]) -> String {
        values.compactMap { $0 }.joined(separator: " + ")
    }

    private static func latestDistinctLabs(_ labs: [LabResult], matching names: [String]) -> [LabResult] {
        var found: [String: LabResult] = [:]
        for lab in labs.sorted(by: { $0.date > $1.date }) {
            let normalized = lab.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            guard let key = names.first(where: { normalized.contains($0) }), found[key] == nil else { continue }
            found[key] = lab
        }
        return Array(found.values)
    }
}
