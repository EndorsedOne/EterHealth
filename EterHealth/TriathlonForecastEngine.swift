import Foundation

struct TriathlonForecast {
    let seconds: Double
    let optimisticSeconds: Double
    let conservativeSeconds: Double
    let swimSeconds: Double
    let swimIsPersonal: Bool
    let bikeSeconds: Double
    let bikeIsPersonal: Bool
    let runSeconds: Double
    let transitionSeconds: Double
    let distance: TriathlonDistance
    let swimSessions: Int
    let bikeSessions: Int
    let brickSessions: Int
    let confidence: ConfidenceAssessment
    let bottleneck: String
    let basis: String
    // Purely descriptive — median of the athlete's own recent outdoor
    // rides when the recording device captured it. Never used to adjust
    // the speed forecast: without a proper FTP test, a power number alone
    // can't be converted into a race-day speed with any real confidence.
    let averageBikePowerWatts: Double?
    let averageBikeCadenceRpm: Double?
    // Set only when the active goal has entered real course details —
    // disclosure text, not a further numeric adjustment.
    let courseCaveat: String?
}

enum TriathlonForecastEngine {
    // Only the run leg is hard-gated to "no forecast at all" — it's the one
    // discipline this app has an actual personal pace model for (Riegel,
    // already validated elsewhere in the app). Swim and bike fall back to
    // an explicitly-labelled generic pace/speed instead of refusing to
    // forecast entirely: unlike running there's no existing personal model
    // to fall back to, but a triathlete choosing a goal wants a number to
    // plan against from day one, not silence until they've logged enough
    // pool sessions. `swimIsPersonal`/`bikeIsPersonal` say which is which,
    // and the UI must never present the generic figures as this athlete's own.
    nonisolated static func forecast(distance: TriathlonDistance, running: RunningPerformanceSummary,
                                     workouts: [HealthWorkout], courseDetails: EventCourseDetails? = nil,
                                     now: Date = Date()) -> TriathlonForecast? {
        guard let runForecast = runForecast(for: distance, from: running) else { return nil }

        let swims = swimSessions(workouts, now: now)
        let bikes = bikeSessions(workouts, now: now)
        let swim = swimForecast(distance: distance, sessions: swims, raceWaterType: courseDetails?.waterType)
        let bike = bikeForecast(distance: distance, sessions: bikes)
        let brickCount = brickSessionCount(workouts, now: now)

        // Running off the bike is measurably slower than a stand-alone run
        // at the same pace — the "compromised run" HyroxForecastEngine
        // already models for HYROX's carrera-bajo-fatiga, applied here to
        // the same physiological cause (legs pre-fatigued by a different
        // discipline). Narrows toward a floor as brick evidence accumulates,
        // exactly like the HYROX station-coverage penalty does.
        let penalty = runOffBikePenalty(brickSessions: brickCount)
        let runSeconds = runForecast.seconds * (1 + penalty)
        let transitionSeconds = transitionTime(for: distance)
        let central = swim.seconds + bike.seconds + runSeconds + transitionSeconds

        let confidence = ConfidenceEngine.triathlon(
            swimSessions: swims.count, swimIsPersonal: swim.isPersonal,
            bikeSessions: bikes.count, bikeIsPersonal: bike.isPersonal,
            brickSessions: brickCount, running: runForecast.confidence
        )
        var gaps: [String] = []
        if !swim.isPersonal { gaps.append("natación (sin sesiones registradas: usa un ritmo recreativo genérico, no el tuyo)") }
        if !bike.isPersonal { gaps.append("ciclismo (sin salidas registradas: usa una velocidad genérica, no la tuya)") }
        if brickCount == 0 { gaps.append("nunca has corrido justo después de la bici, así que la penalización de fatiga es estructural, no medida en ti") }
        let bottleneck = gaps.isEmpty
            ? "El siguiente salto de precisión requiere una simulación completa: natación, bici y carrera seguidas, como en la carrera real."
            : "La mayor incertidumbre está en: \(gaps.joined(separator: "; "))."
        let uncertainty = confidence.level == .high ? 0.05 : confidence.level == .medium ? 0.09 : 0.16
        let basis = "Natación \(swim.isPersonal ? "de tu propio historial" : "genérica")\(swim.adjustmentNote), ciclismo \(bike.isPersonal ? "de tu propio historial" : "genérico") y carrera desde tu marca de \(runForecast.distanceName) con un \(Int((penalty * 100).rounded()))% de penalización por fatiga de bici."

        let power = medianStat(bikes.filter { $0.isIndoor != true }, \.averageCyclingPowerWatts)
        let cadence = medianStat(bikes.filter { $0.isIndoor != true }, \.averageCyclingCadenceRpm)
        let courseCaveat = courseCaveat(for: courseDetails)

        return TriathlonForecast(
            seconds: central, optimisticSeconds: central * (1 - uncertainty), conservativeSeconds: central * (1 + uncertainty),
            swimSeconds: swim.seconds, swimIsPersonal: swim.isPersonal,
            bikeSeconds: bike.seconds, bikeIsPersonal: bike.isPersonal,
            runSeconds: runSeconds, transitionSeconds: transitionSeconds, distance: distance,
            swimSessions: swims.count, bikeSessions: bikes.count, brickSessions: brickCount,
            confidence: confidence, bottleneck: bottleneck, basis: basis,
            averageBikePowerWatts: power, averageBikeCadenceRpm: cadence, courseCaveat: courseCaveat
        )
    }

    // Discloses what the forecast does NOT correct for, rather than
    // pretending to model it: real per-kilometer grade-adjusted cycling
    // power/time modelling needs weight, aerodynamics and a power curve
    // this app has none of, so a hilly course is named as a caveat, not
    // silently baked into a fake-precise number. Wetsuit legality is a
    // genuine fact (water below ~24.5°C), surfaced the same honest way.
    private nonisolated static func courseCaveat(for courseDetails: EventCourseDetails?) -> String? {
        guard let courseDetails, !courseDetails.isEmpty else { return nil }
        var parts: [String] = []
        if let elevation = courseDetails.courseElevationMeters, elevation > 200 {
            parts.append("el recorrido tiene \(Int(elevation)) m de desnivel — esta proyección no ajusta por pendiente y probablemente sea optimista en la pierna de bici")
        }
        if let legal = courseDetails.wetsuitLikelyLegal {
            parts.append(legal ? "el neopreno probablemente sea legal por temperatura del agua (suele dar algo más de flotación y velocidad)" : "el neopreno probablemente NO sea legal por temperatura del agua")
        }
        if let air = courseDetails.expectedAirTemperatureCelsius, air >= 28 {
            parts.append("con \(Int(air))°C previstos, el calor es un factor real de ritmo que esta proyección no reduce por sí sola")
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "; ")
        return joined.prefix(1).uppercased() + String(joined.dropFirst())
    }

    private nonisolated static func runForecast(for distance: TriathlonDistance, from running: RunningPerformanceSummary) -> RaceForecast? {
        switch distance {
        case .sprint: return running.fiveK
        case .olympic: return running.tenK
        case .half: return running.halfMarathon
        case .full: return running.marathon
        }
    }

    nonisolated static func swimSessions(_ workouts: [HealthWorkout], now: Date = Date(), lookbackDays: Double = 120) -> [HealthWorkout] {
        let cutoff = now.addingTimeInterval(-lookbackDays * 86_400)
        return workouts.filter { $0.activity == "Natación" && $0.date <= now && $0.date >= cutoff && ($0.distanceKilometers ?? 0) >= 0.2 && $0.durationMinutes > 0 }
    }

    nonisolated static func bikeSessions(_ workouts: [HealthWorkout], now: Date = Date(), lookbackDays: Double = 120) -> [HealthWorkout] {
        let cutoff = now.addingTimeInterval(-lookbackDays * 86_400)
        return workouts.filter { $0.activity == "Ciclismo" && $0.date <= now && $0.date >= cutoff && ($0.distanceKilometers ?? 0) >= 5 && $0.durationMinutes > 0 }
    }

    /// Median personal pace, seconds per 100 m — shared with WorkoutPlanner's
    /// swim session prescriptions so the same personal number drives both the
    /// forecast and the actual training pace, never two disconnected guesses.
    nonisolated static func personalSwimPace100mSeconds(_ sessions: [HealthWorkout]) -> Double? {
        let paces = sessions.compactMap { session -> Double? in
            guard let km = session.distanceKilometers, km > 0 else { return nil }
            return (session.durationMinutes * 60) / (km * 1000 / 100)
        }
        return median(paces)
    }

    /// Median personal speed, km/h — cycling speed is far more terrain/wind-
    /// dependent than running pace, so this uses the median of recent rides
    /// rather than the single fastest one (which could just be a tailwind or
    /// a downhill outlier) — a steadier number for a discipline where the
    /// "best effort" heuristic running uses is less trustworthy.
    nonisolated static func personalBikeSpeedKmh(_ sessions: [HealthWorkout]) -> Double? {
        let speeds = sessions.compactMap { session -> Double? in
            guard let km = session.distanceKilometers, km > 0, session.durationMinutes > 0 else { return nil }
            return km / (session.durationMinutes / 60)
        }
        return median(speeds)
    }

    // Pool and open-water pace aren't comparable — no current, sighting, or
    // wetsuit drag in a pool — so this prefers whichever evidence actually
    // matches the race's own water type (defaulting to open water, since
    // that's what almost every triathlon swim leg is) and only extrapolates
    // from the other kind, with a disclosed adjustment, when that's all
    // there is.
    private nonisolated static func swimForecast(distance: TriathlonDistance, sessions: [HealthWorkout],
                                                  raceWaterType: WaterType?) -> (seconds: Double, isPersonal: Bool, adjustmentNote: String) {
        let targetMeters = distance.swimKilometers * 1000
        let poolSessions = sessions.filter { $0.swimLocation == .pool }
        let openWaterSessions = sessions.filter { $0.swimLocation == .openWater }
        let raceIsPool = raceWaterType == .pool

        if let pace = personalSwimPace100mSeconds(raceIsPool ? poolSessions : openWaterSessions) {
            return (targetMeters / 100 * pace, true, "")
        }
        if !raceIsPool, let pace = personalSwimPace100mSeconds(poolSessions) {
            // Open water is typically ~6% slower than pool pace for most
            // athletes (no wall push-offs, sighting, current/chop) — a
            // deliberately modest, disclosed adjustment, not a personal
            // measurement.
            let adjusted = pace * 1.06
            return (targetMeters / 100 * adjusted, true, " (ritmo de piscina extrapolado a aguas abiertas, +6%)")
        }
        // No location metadata at all on any session (older recordings, or
        // a source that never set it) — fall back to treating everything
        // as one pool, the previous behavior, rather than discarding real
        // sessions just because they're unclassified.
        if let pace = personalSwimPace100mSeconds(sessions) {
            return (targetMeters / 100 * pace, true, "")
        }
        // ~2:15/100 m — an unremarkable recreational pool pace, used only
        // as a visible placeholder until real sessions exist.
        return (targetMeters / 100 * 135, false, "")
    }

    // Indoor trainer speed/distance often isn't comparable to real road
    // riding (many smart trainers report a "virtual" distance that has no
    // fixed relationship to outdoor speed), so this prefers outdoor
    // evidence and only falls back to indoor rides when that's all there is.
    private nonisolated static func bikeForecast(distance: TriathlonDistance, sessions: [HealthWorkout]) -> (seconds: Double, isPersonal: Bool) {
        let outdoor = sessions.filter { $0.isIndoor != true }
        guard let speed = personalBikeSpeedKmh(outdoor.isEmpty ? sessions : outdoor) else {
            // ~24 km/h — an unremarkable flat-road recreational speed.
            return (distance.bikeKilometers / 24 * 3_600, false)
        }
        return (distance.bikeKilometers / speed * 3_600, true)
    }

    private nonisolated static func medianStat(_ sessions: [HealthWorkout], _ path: KeyPath<HealthWorkout, Double?>) -> Double? {
        median(sessions.compactMap { $0[keyPath: path] })
    }

    /// A "brick" is a bike immediately followed by a run — the specific
    /// evidence that this athlete has actually trained running on
    /// bike-fatigued legs, not just trained the two disciplines separately.
    nonisolated static func brickSessionCount(_ workouts: [HealthWorkout], now: Date = Date(), lookbackDays: Double = 120) -> Int {
        brickSessions(workouts, now: now, lookbackDays: lookbackDays).count
    }

    /// Every real bike→run pair, bike and run paired up, within the window
    /// — the shared building block `brickSessionCount` and (with a 7-day
    /// window) the brick weekly-dose tracker in TrainingPlanEngine both use,
    /// so "did a brick happen" and "how many minutes was it" never disagree.
    nonisolated static func brickSessions(_ workouts: [HealthWorkout], now: Date = Date(), lookbackDays: Double = 120) -> [(bike: HealthWorkout, run: HealthWorkout)] {
        let cutoff = now.addingTimeInterval(-lookbackDays * 86_400)
        let bikes = workouts.filter { $0.activity == "Ciclismo" && $0.date >= cutoff && $0.date <= now }
        let runs = workouts.filter { $0.activity == "Carrera" && $0.date >= cutoff && $0.date <= now }
        return bikes.compactMap { bike in
            let bikeEnd = bike.date.addingTimeInterval(bike.durationMinutes * 60)
            guard let run = runs.first(where: { $0.date >= bikeEnd && $0.date <= bikeEnd.addingTimeInterval(30 * 60) }) else { return nil }
            return (bike, run)
        }
    }

    /// Total minutes (bike + run) across every brick in the window — the
    /// actual dose, not just whether one happened.
    nonisolated static func brickMinutes(_ workouts: [HealthWorkout], now: Date = Date(), lookbackDays: Double = 120) -> Double {
        brickSessions(workouts, now: now, lookbackDays: lookbackDays).reduce(0) { $0 + $1.bike.durationMinutes + $1.run.durationMinutes }
    }

    nonisolated static func runOffBikePenalty(brickSessions: Int) -> Double {
        let capped = max(0, min(6, brickSessions))
        return max(0.03, 0.12 - Double(capped) * 0.015)
    }

    /// Swim→bike and bike→run transitions ("T1"/"T2") — gear complexity (and
    /// therefore time lost) scales with distance: a sprint is wetsuit-off,
    /// helmet-on and gone, while a full-distance transition tent involves
    /// changing kit, nutrition, and often a full shoe change.
    nonisolated static func transitionTime(for distance: TriathlonDistance) -> Double {
        switch distance {
        case .sprint: return 120
        case .olympic: return 180
        case .half: return 300
        case .full: return 480
        }
    }

    private nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
