import Foundation

struct HyroxStationEvidence: Identifiable {
    var id: String { name }
    let name: String
    let observed: Bool
}

struct HyroxForecast {
    let seconds: Double
    let optimisticSeconds: Double
    let conservativeSeconds: Double
    let runSeconds: Double
    let stationSeconds: Double
    // PR5: de dónde salen esos segundos — banda poblacional, tiempos reales
    // por estación, o implícitos de simulaciones completas. Que se pueda
    // leer es parte de la honestidad: un número personal y uno de banda no
    // valen lo mismo.
    let stationBasis: HyroxStationBasis
    let transitionSeconds: Double
    let division: HyroxDivision
    let stations: [HyroxStationEvidence]
    let specificSessions: Int
    let completedRaces: Int
    let confidence: ConfidenceAssessment
    let bottleneck: String
    let basis: String
}

enum HyroxStationBasis: String, Equatable {
    case populationBand = "banda de la división"
    case observedStations = "tiempos reales por estación"
    case impliedFromSimulations = "implícito de tus simulaciones"
    case enrichedRow = "ergómetros medidos y resto por banda"
}

enum HyroxForecastEngine {
    // Brandt et al. 2025 (the real HYROX-performance study, not an
    // influencer's opinion) found aerobic capacity and body composition —
    // not grip or muscle mass — the strongest correlates of total race
    // time: VO2max ρ=-0.71, aerobic training volume ρ=-0.68, body fat %
    // ρ=0.67. Neither fed this forecast at all before; both were tracked
    // elsewhere in the app (HealthStore.vo2MaxHistory, bodyFatHistory)
    // and simply never reached this engine.
    //
    // Deliberately NOT used to shift the predicted seconds: a correlation
    // coefficient alone gives no slope/intercept to convert "X ml/kg/min
    // of VO2max" into "Y seconds faster" without inventing one — and
    // 10K/5K race pace (already driving runSeconds below) is itself
    // highly correlated with VO2max, so adding a second VO2max-based time
    // adjustment on top would risk double-counting the same underlying
    // fitness rather than adding real new information. Used instead
    // exactly where this app already puts evidence it can't turn into a
    // number: the bottleneck explanation — same treatment
    // WellnessRecommendationEngine gives VO2max/body-fat elsewhere,
    // reusing its identical <35 / >30 reference bands so "outside range"
    // means the same thing in both places.
    nonisolated static func forecast(
        running: RunningPerformanceSummary, workouts: [ImportedWorkout],
        division: HyroxDivision = .open, now: Date = Date(),
        vo2Max: Double? = nil, bodyFatPercentage: Double? = nil,
        workoutEnrichments: [WorkoutEnrichment] = []
    ) -> HyroxForecast? {
        guard let runForecast = running.tenK ?? running.fiveK else { return nil }
        let exercises = workouts
            .filter { $0.start <= now && $0.start >= now.addingTimeInterval(-240 * 86_400) }
            .flatMap(\.exercises).map { normalized($0.name) }
        let enrichedDisciplines = Set(workoutEnrichments.filter {
            $0.useForHyrox && $0.workoutDate <= now &&
                $0.workoutDate >= now.addingTimeInterval(-240 * 86_400) &&
                (($0.distanceMeters ?? 0) > 0 || ($0.effectiveDurationSeconds ?? 0) > 0 || ($0.averagePowerWatts ?? 0) > 0)
        }.map(\.effectiveDiscipline))
        let stations = stationDefinitions.map { name, terms in
            let importedEvidence = exercises.contains { exercise in terms.contains { exercise.contains($0) } }
            let enriched = (name == "Row" && enrichedDisciplines.contains(.rowing)) ||
                (name == "SkiErg" && enrichedDisciplines.contains(.skiErg))
            return HyroxStationEvidence(name: name, observed: importedEvidence || enriched)
        }
        let stationCoverage = stations.filter(\.observed).count
        let specific = workouts.filter {
            let title = normalized($0.title)
            return $0.start <= now && $0.start >= now.addingTimeInterval(-120 * 86_400) &&
                (title.contains("hyrox") || title.contains("carrera bajo fatiga"))
        }
        let raceResults = specific.filter {
            let title = normalized($0.title)
            return title.contains("race") || title.contains("competicion") || title.contains("carrera completa")
        }

        let run8K = runForecast.distanceName == "10 km"
            ? runForecast.seconds * pow(0.8, 1.06)
            : runForecast.seconds * pow(8.0 / 5.0, 1.06)
        let compromise = compromisedRunPenalty(stationCoverage: stationCoverage, specificSessions: specific.count)
        let runSeconds = run8K * (1 + (compromise.lowerBound + compromise.upperBound) / 2)
        let stationBand = stationTimeBand(division)
        let priorStationSeconds = (stationBand.lowerBound + stationBand.upperBound) / 2
        let rowingEvidence = enrichedRowingEstimate(workoutEnrichments, division: division, now: now)
        let skiEvidence = enrichedErgometerEstimate(workoutEnrichments, discipline: .skiErg, now: now)
        let transitionSeconds = division == .doubles ? 270.0 : 330.0

        let credibleSimulations = specific.map { $0.end.timeIntervalSince($0.start) }
            .filter { $0 >= 45 * 60 && $0 <= 180 * 60 }

        // PR5: el componente de estaciones deja de ser sólo la banda de la
        // división en cuanto hay evidencia personal. Dos fuentes, y la más
        // directa gana.
        let observed = observedStationSeconds(specific, now: now)
        let impliedStationSeconds: Double? = credibleSimulations.count >= 2
            ? median(credibleSimulations).map { max(0, $0 - runSeconds - transitionSeconds) }
            : nil
        let stationSeconds: Double
        let stationBasis: HyroxStationBasis
        let stationSpread: Double
        if let observed, observed.stationsCovered >= 4 {
            // Medición directa de lo que se predice: pesa más que el prior.
            // El 0.65 es deliberadamente más que el 0.55 que la app da a una
            // simulación completa, porque una simulación mezcla descansos y
            // formatos parciales y esto no.
            stationSeconds = observed.total * 0.65 + priorStationSeconds * 0.35
            stationBasis = .observedStations
            // Banda estrecha porque hay medición: ±8% en vez de los ~18 min
            // de la banda poblacional. Heurística documentada, no un número
            // clínico.
            stationSpread = stationSeconds * 0.08
        } else if let impliedStationSeconds, impliedStationSeconds > 0 {
            // Indirecto: el resto de una simulación completa tras quitar
            // carrera y transiciones. Mismos pesos que la app ya usa para
            // mezclar una simulación con el prior (0.55 prior / 0.45 personal).
            stationSeconds = priorStationSeconds * 0.55 + impliedStationSeconds * 0.45
            stationBasis = .impliedFromSimulations
            stationSpread = stationSeconds * 0.12
        } else if rowingEvidence != nil || skiEvidence != nil {
            // Cada ergómetro sustituye sólo su propio prior. Tener SkiErg no
            // puede mejorar artificialmente el remo, ni al revés.
            let priorRow = priorRowingSeconds(division)
            let priorSki = priorSkiErgSeconds(division)
            let personalizedRow = rowingEvidence.map { priorRow * (1 - $0.weight) + $0.seconds * $0.weight } ?? priorRow
            let personalizedSki = skiEvidence.map { priorSki * (1 - $0.weight) + $0.seconds * $0.weight } ?? priorSki
            stationSeconds = priorStationSeconds - priorRow - priorSki + personalizedRow + personalizedSki
            stationBasis = .enrichedRow
            // Conservamos casi toda la amplitud poblacional: conocemos mejor
            // el remo, no el trineo, lunges o wall balls.
            let populationSpread = (stationBand.upperBound - stationBand.lowerBound) / 2
            let combinedWeight = (rowingEvidence?.weight ?? 0) + (skiEvidence?.weight ?? 0)
            stationSpread = populationSpread * (1 - 0.10 * min(1.5, combinedWeight))
        } else {
            stationSeconds = priorStationSeconds
            stationBasis = .populationBand
            stationSpread = (stationBand.upperBound - stationBand.lowerBound) / 2
        }

        var central = runSeconds + stationSeconds + transitionSeconds
        if !credibleSimulations.isEmpty {
            // A specific simulation is more personal than the structural station
            // prior, but remains blended because rests and partial formats vary.
            central = central * 0.55 + median(credibleSimulations)! * 0.45
        }
        if !raceResults.isEmpty {
            let results = raceResults.map { $0.end.timeIntervalSince($0.start) }
                .filter { $0 >= 45 * 60 && $0 <= 180 * 60 }
            if let result = median(results) { central = result }
        }

        // La banda ya no es siempre la poblacional: se estrecha cuando la
        // evidencia de estaciones es personal (stationSpread arriba).
        let optimistic = raceResults.isEmpty
            ? run8K * (1 + compromise.lowerBound) + (stationSeconds - stationSpread) + 240
            : central * 0.97
        let conservative = raceResults.isEmpty
            ? run8K * (1 + compromise.upperBound) + (stationSeconds + stationSpread) + 480
            : central * 1.04
        let confidence = ConfidenceEngine.hyrox(
            stationCoverage: stationCoverage, specificSessions: specific.count,
            completedRaces: raceResults.count, running: runForecast.confidence
        )
        let bottleneck: String
        if let vo2Max, vo2Max < 35 {
            bottleneck = "Tu palanca real es la capacidad aeróbica: tu VO2 máx. (\(Int(vo2Max.rounded())) ml/kg/min) está por debajo de lo asociado a mejores tiempos. Brandt et al. 2025 encontraron que el VO2 máx. es lo que más correlaciona con el tiempo total en HYROX (ρ=-0,71) — más que la fuerza de agarre o la masa muscular."
        } else if let bodyFatPercentage, bodyFatPercentage > 30 {
            bottleneck = "Tu palanca real es la composición corporal: el mismo estudio encontró que el % de grasa corporal correlaciona con un tiempo peor (ρ=0,67), mientras que ni el agarre ni la masa muscular predijeron el resultado."
        } else if stationCoverage < 4 {
            bottleneck = "La mayor incertidumbre está en las estaciones: solo hay \(stationCoverage)/8 observadas. El remo completado en Éter ya personaliza esa estación; su margen es mayor cuando la máquina no es la de competición."
        }
        else if specific.count < 2 { bottleneck = "Falta medir cómo sostienes la carrera después de varias estaciones." }
        else if runForecast.confidence == .low { bottleneck = "La carrera base todavía procede de esfuerzos poco comparables." }
        else { bottleneck = "El siguiente salto de precisión requiere una simulación completa comparable." }
        let source = raceResults.isEmpty
            ? "8 km proyectados desde \(runForecast.distanceName), penalización por carrera comprometida y estaciones por \(stationBasis.rawValue)."
            : "\(raceResults.count) resultado\(raceResults.count == 1 ? "" : "s") completo\(raceResults.count == 1 ? "" : "s") localizado\(raceResults.count == 1 ? "" : "s")."
        return HyroxForecast(
            seconds: central, optimisticSeconds: min(optimistic, central),
            conservativeSeconds: max(conservative, central), runSeconds: runSeconds,
            stationSeconds: stationSeconds, stationBasis: stationBasis, transitionSeconds: transitionSeconds,
            division: division, stations: stations, specificSessions: specific.count,
            completedRaces: raceResults.count, confidence: confidence,
            bottleneck: bottleneck, basis: source
        )
    }

    // Suma de duraciones reales por estación dentro de UNA sola sesión
    // específica — la más reciente que tenga al menos 4 de las 8 medidas.
    // De una sola sesión y no mezclando varias a propósito: sumar el trineo
    // de una y el remo de otra daría un total que nadie ha corrido nunca.
    // Y con cobertura parcial el total infraestima, así que el llamante exige
    // >= 4 antes de usarlo.
    nonisolated static func observedStationSeconds(_ specific: [ImportedWorkout],
                                                   now: Date = Date()) -> (total: Double, stationsCovered: Int)? {
        for workout in specific.sorted(by: { $0.start > $1.start }) {
            var total = 0.0
            var covered = 0
            for (_, terms) in stationDefinitions {
                var seconds = 0.0
                for exercise in workout.exercises {
                    let name = normalized(exercise.name)
                    guard terms.contains(where: { name.contains($0) }) else { continue }
                    guard let details = exercise.setDetails else { continue }
                    for set in details {
                        if let duration = set.durationSeconds, duration > 0 { seconds += duration }
                    }
                }
                if seconds > 0 {
                    total += seconds
                    covered += 1
                }
            }
            if covered > 0 { return (total, covered) }
        }
        return nil
    }

    nonisolated static func compromisedRunPenalty(stationCoverage: Int, specificSessions: Int) -> ClosedRange<Double> {
        let coverage = max(0, min(8, stationCoverage))
        let experience = max(0, min(4, specificSessions))
        let reduction = Double(coverage) * 0.004 + Double(experience) * 0.008
        return max(0.05, 0.10 - reduction)...max(0.10, 0.20 - reduction)
    }

    /// Equivalente de 1.000 m. Metros+tiempo son la señal principal; los
    /// vatios sirven como segunda estimación o control de coherencia mediante
    /// la relación potencia/ritmo de ergómetro. La diferencia de máquina baja
    /// el peso, nunca descarta la sesión.
    nonisolated static func enrichedRowingEstimate(
        _ values: [WorkoutEnrichment], division: HyroxDivision = .open,
        now: Date = Date()
    ) -> (seconds: Double, weight: Double)? {
        enrichedErgometerEstimate(values, discipline: .rowing, now: now)
    }

    nonisolated static func enrichedErgometerEstimate(
        _ values: [WorkoutEnrichment], discipline: ErgometerDiscipline,
        now: Date = Date()
    ) -> (seconds: Double, weight: Double)? {
        let recent = values.filter {
            $0.useForHyrox && $0.workoutDate <= now &&
                $0.workoutDate >= now.addingTimeInterval(-240 * 86_400) &&
                $0.effectiveDiscipline == discipline
        }.compactMap { value -> (Double, Double)? in
            let paceEstimate: Double? = {
                guard let meters = value.distanceMeters, meters >= 250,
                      let seconds = value.effectiveDurationSeconds, seconds >= 45 else { return nil }
                return seconds * 1_000 / meters
            }()
            let powerEstimate: Double? = {
                guard let watts = value.averagePowerWatts, watts >= 40 else { return nil }
                // Concept2: P = 2.8 / (t/500)^3; despejado para 1.000 m.
                return 1_000 * pow(2.8 / watts, 1.0 / 3.0)
            }()
            let estimate: Double
            if let paceEstimate, let powerEstimate {
                estimate = paceEstimate * 0.8 + powerEstimate * 0.2
            } else if let paceEstimate { estimate = paceEstimate }
            else if let powerEstimate { estimate = powerEstimate }
            else { return nil }
            guard (150...600).contains(estimate) else { return nil }
            let isConcept2 = value.machine == .concept2 || value.machine == .concept2SkiErg
            let machineReliability: Double = isConcept2 ? 0.82 : 0.62
            let completeness = paceEstimate != nil && powerEstimate != nil ? 1.0 : 0.86
            return (estimate, machineReliability * completeness)
        }
        guard !recent.isEmpty else { return nil }
        let seconds = median(recent.map { $0.0 })!
        let base = recent.map { $0.1 }.reduce(0, +) / Double(recent.count)
        let repetitionGain = min(0.16, Double(recent.count - 1) * 0.04)
        return (seconds, min(0.9, base + repetitionGain))
    }

    private nonisolated static func priorRowingSeconds(_ division: HyroxDivision) -> Double {
        switch division {
        case .open: return 270
        case .pro: return 260
        case .doubles: return 250
        }
    }

    private nonisolated static func priorSkiErgSeconds(_ division: HyroxDivision) -> Double {
        switch division {
        case .open: return 270
        case .pro: return 260
        case .doubles: return 250
        }
    }

    private nonisolated static func stationTimeBand(_ division: HyroxDivision) -> ClosedRange<Double> {
        switch division {
        case .open: return 35 * 60...50 * 60
        case .pro: return 38 * 60...55 * 60
        case .doubles: return 25 * 60...38 * 60
        }
    }

    private nonisolated static let stationDefinitions: [(String, [String])] = [
        ("SkiErg", ["skierg", "ski erg"]),
        ("Sled Push", ["sled push", "empuje de trineo", "empuje trineo"]),
        ("Sled Pull", ["sled pull", "arrastre de trineo", "arrastre trineo"]),
        ("Burpee Broad Jump", ["burpee broad", "burpee salto"]),
        ("Row", ["rowing machine", "remo ergometro", "row erg", "concept2 row"]),
        ("Farmers Carry", ["farmer carry", "farmers carry", "paseo del granjero"]),
        ("Sandbag Lunges", ["sandbag lunge", "zancada con saco"]),
        ("Wall Balls", ["wall ball"])
    ]

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    private nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
