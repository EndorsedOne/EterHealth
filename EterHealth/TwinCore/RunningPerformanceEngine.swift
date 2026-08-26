import Foundation

struct RunningWeek: Identifiable {
    var id: Date { start }
    let start: Date
    let kilometers: Double
    let minutes: Double
    let sessions: Int
}

struct RunningSessionMetric: Identifiable {
    let id: UUID
    let date: Date
    let kilometers: Double
    let minutes: Double
    let averageHeartRate: Double?
    let elevationMeters: Double?
    var pace: Double { minutes / max(kilometers, 0.01) }
}

struct RaceForecast {
    let distanceName: String
    let seconds: Double
    let confidence: TrustLevel
    let basis: String

    var uncertainty: Double {
        switch confidence { case .high: return 0.015; case .medium: return 0.03; case .low: return 0.055 }
    }
    var optimisticSeconds: Double { seconds * (1 - uncertainty) }
    var conservativeSeconds: Double { seconds * (1 + uncertainty) }
}

enum ForecastDistance: String, CaseIterable, Identifiable {
    case fiveK = "5 km"
    case tenK = "10 km"
    case halfMarathon = "Media"
    case marathon = "Maratón"
    var id: String { rawValue }
    var kilometers: Double {
        switch self { case .fiveK: return 5; case .tenK: return 10; case .halfMarathon: return 21.0975; case .marathon: return 42.195 }
    }
    var fullName: String { self == .halfMarathon ? "Media maratón" : rawValue }
}

struct RaceForecastTrendPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let seconds: Double
    let confidence: TrustLevel
}

struct RunningPerformanceSummary {
    let sessions: [RunningSessionMetric]
    let weeks: [RunningWeek]
    let kilometers7Days: Double
    let priorKilometers7Days: Double
    let fiveK: RaceForecast?
    let tenK: RaceForecast?
    let halfMarathon: RaceForecast?
    // Riegel (T2 = T1×(D2/D1)^1.06) is well-validated for extrapolating
    // between distances that are reasonably close together — it's known to
    // run optimistic projecting all the way out to a full marathon from a
    // 5K/10K, since it can't model the glycogen-depletion fade that shows up
    // specifically past ~30-32km. RunningPerformanceView surfaces this
    // explicitly rather than presenting it with the same confidence as the
    // other three distances.
    let marathon: RaceForecast?
    let easyPercentage: Double
    let hardPercentage: Double
    let hasZoneData: Bool

    var toleranceChange: Double? {
        guard priorKilometers7Days > 0 else { return nil }
        return (kilometers7Days / priorKilometers7Days - 1) * 100
    }
}

struct RunningCoverageSummary {
    let days: Int
    let kilometers: Double
    let kilometerTarget: ClosedRange<Double>
    let longestRun: Double
    let longRunTarget: ClosedRange<Double>
    let runs: Int
    let targetRuns: Int
    let qualityRuns: Int
    let targetQuality: Int
    let easyPercentage: Double?
    let easyTarget: ClosedRange<Double>
    let cyclingMinutes: Double
    let interpretation: String
    let context: String
}

enum RunningPerformanceEngine {
    static func hardIntensityTarget(for block: TrainingBlock) -> ClosedRange<Double> {
        switch block.phase {
        case .taper: return 10...28
        case .transition: return 15...38
        case .base, .buildSpecific, .race: return 12...32
        }
    }

    static func easyIntensityTarget(for block: TrainingBlock) -> ClosedRange<Double> {
        let hard = hardIntensityTarget(for: block)
        return (100 - hard.upperBound)...(100 - hard.lowerBound)
    }

    static func summarize(workouts: [HealthWorkout], zones: [HeartRateZone], reviews: [WorkoutReview] = [], now: Date = Date()) -> RunningPerformanceSummary {
        let calendar = Calendar.current
        let runs = workouts.filter { $0.activity == "Carrera" && $0.date <= now }.compactMap { workout -> RunningSessionMetric? in
            guard let distance = workout.distanceKilometers, distance > 0.25, workout.durationMinutes > 0 else { return nil }
            return RunningSessionMetric(id: workout.id, date: workout.date, kilometers: distance, minutes: workout.durationMinutes, averageHeartRate: workout.averageHeartRate, elevationMeters: workout.elevationMeters)
        }.sorted { $0.date < $1.date }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let weeks = (-5...0).map { offset -> RunningWeek in
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart) ?? weekStart
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
            let values = runs.filter { $0.date >= start && $0.date < end }
            return RunningWeek(start: start, kilometers: values.reduce(0) { $0 + $1.kilometers }, minutes: values.reduce(0) { $0 + $1.minutes }, sessions: values.count)
        }
        let seven = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let fourteen = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let current = runs.filter { $0.date >= seven }.reduce(0) { $0 + $1.kilometers }
        let previous = runs.filter { $0.date >= fourteen && $0.date < seven }.reduce(0) { $0 + $1.kilometers }
        let zoneMap = Dictionary(uniqueKeysWithValues: zones.map { ($0.zone, $0.percentage) })
        let easy = (zoneMap[1] ?? 0) + (zoneMap[2] ?? 0)
        let hard = 100 - easy
        return RunningPerformanceSummary(
            sessions: runs,
            weeks: weeks,
            kilometers7Days: current,
            priorKilometers7Days: previous,
            fiveK: forecast(name: "5 km", targetKilometers: 5, runs: runs, reviews: reviews, asOf: now),
            tenK: forecast(name: "10 km", targetKilometers: 10, runs: runs, reviews: reviews, asOf: now),
            halfMarathon: forecast(name: "Media maratón", targetKilometers: 21.0975, runs: runs, reviews: reviews, asOf: now),
            marathon: forecast(name: "Maratón", targetKilometers: 42.195, runs: runs, reviews: reviews, asOf: now),
            easyPercentage: easy,
            hardPercentage: max(0, hard),
            hasZoneData: !zones.isEmpty
        )
    }

    static func forecastTrend(distance: ForecastDistance, workouts: [HealthWorkout], reviews: [WorkoutReview],
                              days: Int, now: Date = Date()) -> [RaceForecastTrendPoint] {
        let calendar = Calendar.current
        let runs = workouts.filter { $0.activity == "Carrera" && $0.date <= now }.compactMap { workout -> RunningSessionMetric? in
            guard let kilometers = workout.distanceKilometers, kilometers > 0.25, workout.durationMinutes > 0 else { return nil }
            return RunningSessionMetric(id: workout.id, date: workout.date, kilometers: kilometers,
                                        minutes: workout.durationMinutes, averageHeartRate: workout.averageHeartRate,
                                        elevationMeters: workout.elevationMeters)
        }
        let step = days <= 31 ? 2 : days <= 100 ? 7 : 14
        let offsets = Array(stride(from: -days, through: 0, by: step)) + (days % step == 0 ? [] : [0])
        return offsets.compactMap { offset -> RaceForecastTrendPoint? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let knownRuns = runs.filter { $0.date <= date }
            let knownReviews = reviews.filter { $0.workoutDate <= date && $0.recordedAt <= date }
            guard let value = forecast(name: distance.fullName, targetKilometers: distance.kilometers,
                                       runs: knownRuns, reviews: knownReviews, asOf: date) else { return nil }
            return RaceForecastTrendPoint(date: date, seconds: value.seconds, confidence: value.confidence)
        }
    }

    // zoneBoundaries opcional: es el peldaño de pulso de
    // SessionClassification. Quien no lo tenga a mano pasa nil y ese peldaño
    // no se usa — nunca se sustituye por las zonas agregadas de la semana,
    // que no dicen nada de una sesión concreta.
    static func coverage(workouts: [HealthWorkout], reviews: [WorkoutReview], summary: RunningPerformanceSummary,
                         targetRuns: Int, targetQuality: Int, block: TrainingBlock,
                         zoneBoundaries: HeartRateZoneBoundaries? = nil, now: Date = Date()) -> RunningCoverageSummary {
        let calendar = Calendar.current
        let seven = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let runs = workouts.filter { $0.activity == "Carrera" && $0.date >= seven && $0.date <= now }
        let priorDistances = (1...3).map { index -> Double in
            let end = calendar.date(byAdding: .day, value: -7 * index, to: now) ?? now
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
            return workouts.filter { $0.activity == "Carrera" && $0.date >= start && $0.date < end }
                .compactMap(\.distanceKilometers).reduce(0, +)
        }.filter { $0 > 0 }
        let baseline = median(priorDistances)
        let recentAverage = priorDistances.isEmpty ? max(4, summary.kilometers7Days / Double(max(1, runs.count)))
                                                   : baseline / Double(max(1, targetRuns))
        // Previously string-matched block.name.lowercased() for "compet"/
        // "afinamiento"/"transición" — the race-day block's name is actually
        // the goal's own title (e.g. "Media maratón"), never literally
        // "Competición", so that specific check only ever worked by accident
        // via the block.start == block.end fallback. block.phase removes the
        // guesswork.
        let phaseFactor: Double
        switch block.phase {
        case .race: phaseFactor = 0.30
        case .taper: phaseFactor = 0.72
        case .transition: phaseFactor = 0.88
        case .base, .buildSpecific: phaseFactor = 1.05
        }
        var midpoint = max(Double(max(1, targetRuns)) * recentAverage, baseline) * phaseFactor
        if baseline > 0 && phaseFactor >= 1 { midpoint = min(midpoint, baseline * 1.10) }
        midpoint = max(targetRuns > 0 ? 8 : 0, midpoint)
        let kilometerTarget = roundedRange(midpoint * 0.92, midpoint * 1.06, step: 1)

        let priorCutoff = calendar.date(byAdding: .day, value: -35, to: now) ?? now
        let priorLong = workouts.filter { $0.activity == "Carrera" && $0.date >= priorCutoff && $0.date < seven }
            .compactMap(\.distanceKilometers).max() ?? 0
        var longMid = priorLong > 0 ? min(priorLong + 2, priorLong * 1.10) : kilometerTarget.upperBound * 0.38
        if phaseFactor < 1 { longMid *= phaseFactor }
        longMid = max(targetRuns > 0 ? 6 : 0, min(longMid, kilometerTarget.upperBound * 0.55))
        let longTarget = roundedRange(longMid * 0.92, longMid * 1.06, step: 0.5)

        // PR4: esta era la SEGUNDA definición de "sesión de calidad" del repo
        // —con RPE >= 8, mientras la otra no miraba el review— y las dos
        // caían en el mismo proxy de kcal/min. Ahora las dos llaman a
        // SessionClassification. El umbral de ritmo sale de los forecasts que
        // ya se han calculado justo arriba, así que no hay recursión.
        let quality = runs.filter(SessionClassification.qualityRunPredicate(
            reviews: reviews,
            // Los forecasts vienen ya hechos en `summary` — no se recalculan
            // aquí, que además sería el camino directo a una recursión.
            thresholdPace: SessionClassification.thresholdPaceSecondsPerKm(fiveK: summary.fiveK, tenK: summary.tenK),
            thresholdHeartRate: zoneBoundaries.map { Double($0.z3z4) }
        )).count
        let longest = runs.compactMap(\.distanceKilometers).max() ?? 0
        let easyTarget = easyIntensityTarget(for: block)
        let cycling = workouts.filter { $0.activity == "Ciclismo" && $0.date >= seven && $0.date <= now }
            .reduce(0) { $0 + $1.durationMinutes }

        var gaps: [String] = []
        if summary.kilometers7Days < kilometerTarget.lowerBound { gaps.append("volumen") }
        if longest < longTarget.lowerBound { gaps.append("tirada larga") }
        if quality < targetQuality { gaps.append("calidad") }
        let interpretation: String
        if summary.kilometers7Days > kilometerTarget.upperBound * 1.15 {
            interpretation = "El volumen ya supera el rango del ciclo. Prioriza asimilación antes de añadir kilómetros."
        } else if gaps.isEmpty {
            interpretation = "Cobertura de running completa. La siguiente decisión depende de recuperación y del resto de tus objetivos."
        } else {
            interpretation = "Pendiente: \(gaps.joined(separator: ", ")). El orden final lo decide el gemelo según fatiga y separación entre sesiones clave."
        }
        let context = baseline > 0
            ? "Rangos construidos desde tus tres semanas previas y modulados por \(block.name.lowercased())."
            : "Rangos provisionales: todavía falta historial semanal suficiente para personalizarlos."
        return RunningCoverageSummary(days: 7, kilometers: summary.kilometers7Days, kilometerTarget: kilometerTarget,
                                      longestRun: longest, longRunTarget: longTarget, runs: runs.count, targetRuns: targetRuns,
                                      qualityRuns: quality, targetQuality: targetQuality,
                                      easyPercentage: summary.hasZoneData ? summary.easyPercentage : nil,
                                      easyTarget: easyTarget, cyclingMinutes: cycling, interpretation: interpretation, context: context)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func roundedRange(_ lower: Double, _ upper: Double, step: Double) -> ClosedRange<Double> {
        let low = max(0, (lower / step).rounded() * step)
        let high = max(low + step, (upper / step).rounded() * step)
        return low...high
    }

    /// Grade-adjusted flat-equivalent time for a run, using the energy-cost-of-
    /// running-on-a-slope polynomial from Minetti AE et al., "Energy cost of
    /// walking and running at extreme uphill and downhill slopes", J Appl
    /// Physiol 2002;93(3):1039-46 (the same model behind Strava's "Grade
    /// Adjusted Pace"). Only the recorded ascent is known here (HealthKit's
    /// elevationAscended, not a per-kilometer gradient profile), so this uses
    /// one AVERAGE grade for the whole run and only corrects for climbing —
    /// a real but approximate refinement, not a precise per-kilometer model.
    /// Returns the original minutes unchanged when there's no elevation data
    /// or the average grade is negligible.
    nonisolated static func gradeAdjustedMinutes(minutes: Double, kilometers: Double, elevationMeters: Double?) -> Double {
        guard let elevationMeters, kilometers > 0 else { return minutes }
        let grade = elevationMeters / (kilometers * 1_000)
        guard grade > 0.005 else { return minutes }
        func costOfRunning(_ i: Double) -> Double {
            155.4 * pow(i, 5) - 30.4 * pow(i, 4) - 43.3 * pow(i, 3) + 46.3 * pow(i, 2) + 19.5 * i + 3.6
        }
        let flatCost = costOfRunning(0)
        let gradedCost = costOfRunning(min(grade, 0.30)) // clamp: the polynomial isn't validated beyond extreme slopes
        guard gradedCost > 0 else { return minutes }
        return minutes * flatCost / gradedCost
    }

    private static func forecast(name: String, targetKilometers: Double, runs: [RunningSessionMetric],
                                 reviews: [WorkoutReview], asOf: Date) -> RaceForecast? {
        let reviewsByID = Dictionary(uniqueKeysWithValues: reviews.map { ($0.workoutID, $0) })
        let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: asOf) ?? .distantPast
        let distanceCandidates = runs.filter { run in
            guard run.date >= cutoff && run.date <= asOf else { return false }
            if targetKilometers < 10 { return run.kilometers >= 3 && run.kilometers <= 15 }
            return run.kilometers >= 5 && run.kilometers <= 25
        }
        let qualified = distanceCandidates.filter { run in
            guard let review = reviewsByID["health-\(run.id.uuidString)"] else { return false }
            if review.pain || review.outcome == .worse || review.purpose == .easy { return false }
            return review.purpose == .test || review.purpose == .race || review.purpose == .quality || review.effort >= 8
        }
        guard !distanceCandidates.isEmpty else { return nil }
        func riegelSeconds(_ run: RunningSessionMetric) -> Double {
            let flatMinutes = gradeAdjustedMinutes(minutes: run.minutes, kilometers: run.kilometers, elevationMeters: run.elevationMeters)
            return flatMinutes * 60 * pow(targetKilometers / run.kilometers, 1.06)
        }
        if !qualified.isEmpty {
            let predictions = qualified.map(riegelSeconds).sorted()
            let index = min(predictions.count - 1, max(0, predictions.count / 3))
            return RaceForecast(distanceName: name, seconds: predictions[index],
                                 confidence: ConfidenceEngine.samples(qualified.count, medium: 2, high: 5, label: "tests o carreras comparables").level,
                                 basis: "\(qualified.count) tests/sesiones exigentes · modelo de Riegel")
        }
        // No session here has ever been reviewed as a test/race/quality effort,
        // so there's nothing to Riegel-project except ordinary training runs —
        // most of which are correctly easy (this app's own 80/20 guidance).
        // The median of that pool is the run's actual bug: it's dragged down
        // by easy volume and reads as a far slower race pace than real
        // capability, exactly backwards from how any race calculator works
        // (Riegel tables, Strava, Garmin all project from your BEST recent
        // comparable effort, not your average training pace). Use the
        // fastest run instead, restricted to the last 60 days so an old,
        // no-longer-representative effort can't dominate — still explicitly
        // caveated as unverified, since a single run can be a GPS/pace outlier.
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -60, to: asOf) ?? cutoff
        let recentCandidates = distanceCandidates.filter { $0.date >= recentCutoff }
        let pool = recentCandidates.isEmpty ? distanceCandidates : recentCandidates
        let seconds = pool.map(riegelSeconds).min() ?? riegelSeconds(pool[0])
        return RaceForecast(distanceName: name, seconds: seconds, confidence: ConfidenceEngine.level(score: 0),
                             basis: "Tu marca más rápida reciente a distancia comparable (sin test valorado) · modelo de Riegel")
    }
}
