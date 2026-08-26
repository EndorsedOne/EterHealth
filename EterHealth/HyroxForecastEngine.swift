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
    let transitionSeconds: Double
    let division: HyroxDivision
    let stations: [HyroxStationEvidence]
    let specificSessions: Int
    let completedRaces: Int
    let confidence: ConfidenceAssessment
    let bottleneck: String
    let basis: String
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
        vo2Max: Double? = nil, bodyFatPercentage: Double? = nil
    ) -> HyroxForecast? {
        guard let runForecast = running.tenK ?? running.fiveK else { return nil }
        let exercises = workouts
            .filter { $0.start <= now && $0.start >= now.addingTimeInterval(-240 * 86_400) }
            .flatMap(\.exercises).map { normalized($0.name) }
        let stations = stationDefinitions.map { name, terms in
            HyroxStationEvidence(name: name, observed: exercises.contains { exercise in terms.contains { exercise.contains($0) } })
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
        let stationSeconds = (stationBand.lowerBound + stationBand.upperBound) / 2
        let transitionSeconds = division == .doubles ? 270.0 : 330.0
        var central = runSeconds + stationSeconds + transitionSeconds

        let credibleSimulations = specific.map { $0.end.timeIntervalSince($0.start) }
            .filter { $0 >= 45 * 60 && $0 <= 180 * 60 }
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

        let optimistic = raceResults.isEmpty
            ? run8K * (1 + compromise.lowerBound) + stationBand.lowerBound + 240
            : central * 0.97
        let conservative = raceResults.isEmpty
            ? run8K * (1 + compromise.upperBound) + stationBand.upperBound + 480
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
        } else if stationCoverage < 4 { bottleneck = "La mayor incertidumbre está en las estaciones: solo hay \(stationCoverage)/8 observadas." }
        else if specific.count < 2 { bottleneck = "Falta medir cómo sostienes la carrera después de varias estaciones." }
        else if runForecast.confidence == .low { bottleneck = "La carrera base todavía procede de esfuerzos poco comparables." }
        else { bottleneck = "El siguiente salto de precisión requiere una simulación completa comparable." }
        let source = raceResults.isEmpty
            ? "8 km proyectados desde \(runForecast.distanceName), penalización por carrera comprometida y banda de estaciones \(division.rawValue)."
            : "\(raceResults.count) resultado\(raceResults.count == 1 ? "" : "s") completo\(raceResults.count == 1 ? "" : "s") localizado\(raceResults.count == 1 ? "" : "s")."
        return HyroxForecast(
            seconds: central, optimisticSeconds: min(optimistic, central),
            conservativeSeconds: max(conservative, central), runSeconds: runSeconds,
            stationSeconds: stationSeconds, transitionSeconds: transitionSeconds,
            division: division, stations: stations, specificSessions: specific.count,
            completedRaces: raceResults.count, confidence: confidence,
            bottleneck: bottleneck, basis: source
        )
    }

    nonisolated static func compromisedRunPenalty(stationCoverage: Int, specificSessions: Int) -> ClosedRange<Double> {
        let coverage = max(0, min(8, stationCoverage))
        let experience = max(0, min(4, specificSessions))
        let reduction = Double(coverage) * 0.004 + Double(experience) * 0.008
        return max(0.05, 0.10 - reduction)...max(0.10, 0.20 - reduction)
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
