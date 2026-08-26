import Foundation

struct StrengthProgressPoint: Identifiable {
    var id: String { "\(date.timeIntervalSince1970)|\(exercise)" }
    let date: Date
    let exercise: String
    let estimatedOneRM: Double
    let volume: Double
    let effectiveSets: Int
}

struct StrengthBestSet {
    let weight: Double
    let reps: Int
    let date: Date
    let estimatedOneRM: Double
}

struct ExerciseStrengthProgress: Identifiable {
    var id: String { name }
    let name: String
    let sessions: Int
    let points: [StrengthProgressPoint]
    let bestSet: StrengthBestSet?
    let latestOneRM: Double?
    let previousOneRM: Double?
    let latestVolume: Double
    let recentEffectiveSets: Int

    var changePercent: Double? {
        guard let latestOneRM, let previousOneRM, previousOneRM > 0 else { return nil }
        return (latestOneRM / previousOneRM - 1) * 100
    }

    var state: String {
        guard sessions >= 3, let changePercent else { return "Construyendo historial" }
        if changePercent >= 2 { return "Progresando" }
        if changePercent <= -4 { return "Revisar tendencia" }
        return "Estable"
    }
}

struct StrengthPatternLoad: Identifiable {
    var id: String { name }
    let name: String
    let sets: Int
    let share: Double
}

struct StrengthCoverageItem: Identifiable {
    var id: String { name }
    let name: String
    let completed: Int
    let target: ClosedRange<Int>

    var percentage: Int {
        if target.contains(completed) { return 100 }
        if completed < target.lowerBound { return Int((Double(completed) / Double(max(1, target.lowerBound)) * 100).rounded()) }
        return Int((Double(completed) / Double(max(1, target.upperBound)) * 100).rounded())
    }

    var state: String {
        if completed < target.lowerBound { return "Pendiente" }
        if completed <= target.upperBound { return "Adecuado" }
        if completed <= Int(Double(target.upperBound) * 1.25) { return "Alto" }
        return "Excesivo"
    }
}

struct StrengthCoverageSummary {
    let days: Int
    let items: [StrengthCoverageItem]
    let interpretation: String
    let context: String
}

struct StrengthProgressSummary {
    let exercises: [ExerciseStrengthProgress]
    let patterns: [StrengthPatternLoad]
    let sessions28Days: Int
    let effectiveSets28Days: Int
    let records28Days: Int
    let totalHistorySessions: Int
}

enum StrengthProgressEngine {
    /// Days since any session touched an exercise matching one of `terms` —
    /// the same name-matching GoalDistanceEngine already uses to track a
    /// bench-press/squat *goal's* own progress, reused here so the daily
    /// plan can tell "you did strength" apart from "you actually trained
    /// the specific lift you have a maintenance goal on". Generic "fuerza
    /// happened" bucketing let an unrelated pattern quietly satisfy the
    /// weekly quota while a named lift went untouched for good.
    nonisolated static func daysSinceLastSession(matchingTerms terms: [String], in workouts: [ImportedWorkout], now: Date = Date()) -> Double? {
        let matches = workouts.filter { workout in
            workout.start <= now && workout.exercises.contains { exercise in
                let name = exercise.name.lowercased()
                return terms.contains { name.contains($0) }
            }
        }
        guard let last = matches.map(\.start).max() else { return nil }
        return max(0, now.timeIntervalSince(last) / 86_400)
    }

    static func summarize(_ workouts: [ImportedWorkout], now: Date = Date()) -> StrengthProgressSummary {
        let exerciseNames = Set(workouts.flatMap(\.exercises).map(\.name))
        let exercises = exerciseNames.compactMap { progress(for: $0, workouts: workouts, now: now) }
            .sorted { left, right in
                if left.recentEffectiveSets != right.recentEffectiveSets { return left.recentEffectiveSets > right.recentEffectiveSets }
                return left.sessions > right.sessions
            }
        let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: now) ?? now
        let recent = workouts.filter { $0.start >= cutoff && $0.start <= now }
        let effectiveSets = Int(recent.flatMap(\.exercises).reduce(0.0) { $0 + ($1.setDetails.map(effectiveSetCount) ?? Double(workingSets($1).count)) }.rounded())
        let records = exercises.filter { progress in
            guard let best = progress.bestSet else { return false }
            return best.date >= cutoff
        }.count
        return StrengthProgressSummary(
            exercises: exercises,
            patterns: patternLoads(recent),
            sessions28Days: recent.count,
            effectiveSets28Days: effectiveSets,
            records28Days: records,
            totalHistorySessions: workouts.count
        )
    }

    @MainActor
    static func coverage(_ workouts: [ImportedWorkout], profile: AthletePlanProfile, healthWorkouts: [HealthWorkout] = [],
                         days: Int = 10, now: Date = Date()) -> StrengthCoverageSummary {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let recent = workouts.filter { $0.start >= cutoff && $0.start <= now }
        let names = ["Empuje", "Tirón", "Sentadilla", "Bisagra", "Core"]
        var totals = Dictionary(uniqueKeysWithValues: names.map { ($0, 0.0) })
        for exercise in recent.flatMap(\.exercises) {
            let sets = exercise.setDetails.map(effectiveSetCount) ?? Double(workingSets(exercise).count)
            guard sets > 0 else { continue }
            for pattern in patterns(for: exercise.name) { totals[pattern, default: 0] += sets }
        }
        // A Watch-only strength session (no Hevy import behind it) has no
        // per-exercise breakdown — only HealthStore's generic per-muscle
        // involvement (see HealthStore.muscles). Converted to a rough
        // sets-equivalent (~1 set per 5 min, the same heuristic
        // ContentView.combinedMuscleDistribution already uses for the
        // muscle radar) and folded in by pattern, so a real session logged
        // only on the Watch stops reading as if it never happened — while
        // staying visibly an estimate, never as precise as a real import.
        for workout in healthWorkouts
        where workout.date >= cutoff && workout.date <= now &&
              (workout.activity == "Fuerza" || workout.activity == "Fuerza funcional") &&
              !workout.source.localizedCaseInsensitiveContains("hevy") {
            let mirrored = recent.contains { imported in
                abs(imported.start.timeIntervalSince(workout.date)) <= 3 * 60 &&
                abs(imported.end.timeIntervalSince(imported.start) - workout.durationMinutes * 60) <= 8 * 60
            }
            guard !mirrored else { continue }
            let equivalentSets = max(1, workout.durationMinutes / 5)
            for (muscle, involvement) in workout.muscleGroups {
                guard let pattern = pattern(forMuscle: muscle) else { continue }
                totals[pattern, default: 0] += equivalentSets * involvement
            }
        }

        let focus = TrainingPlanEngine.goalFocus(for: profile, on: now)
        let strengthMultiplier: Double
        if focus.strength >= 0.42 { strengthMultiplier = 1.20 }
        else if focus.running >= 0.62 { strengthMultiplier = 0.78 }
        else { strengthMultiplier = 1.0 }
        let gymMultiplier = profile.gymAvailable ? 1.0 : 0.82
        let multiplier = strengthMultiplier * gymMultiplier
        let benchActive = profile.goals.contains { $0.isActive && $0.kind == .benchPress }
        let squatActive = profile.goals.contains { $0.isActive && $0.kind == .squat }
        let hyroxActive = profile.goals.contains { $0.isActive && $0.kind == .hyrox }
        // Previously 8-12/6-10/4-7 over 10 days (≈4-8.4 sets/week) — well
        // below the ~10-20 sets per muscle group per week resistance-
        // training research typically cites for hypertrophy/maintenance
        // (Schoenfeld et al.), which meant one real, ordinary dedicated
        // session could push a pattern straight to "Excesivo" with nothing
        // unusual having happened.
        let bases: [String: ClosedRange<Int>] = [
            "Empuje": 12...20, "Tirón": 12...20, "Sentadilla": 10...16, "Bisagra": 10...16, "Core": 6...10
        ]
        let items = names.map { name -> StrengthCoverageItem in
            let base = bases[name] ?? 4...8
            var low = max(2, Int((Double(base.lowerBound) * multiplier).rounded()))
            var high = max(low + 2, Int((Double(base.upperBound) * multiplier).rounded()))
            if name == "Empuje", benchActive { low += 1; high += 2 }
            if name == "Sentadilla", squatActive { low += 1; high += 2 }
            if hyroxActive && ["Sentadilla", "Bisagra", "Core"].contains(name) { high += 1 }
            return StrengthCoverageItem(name: name, completed: Int(totals[name, default: 0].rounded()), target: low...high)
        }

        let missing = items.filter { $0.completed < $0.target.lowerBound }
            .sorted { ($0.target.lowerBound - $0.completed) > ($1.target.lowerBound - $1.completed) }
        let excessive = items.filter { $0.state == "Excesivo" }
        let interpretation: String
        if let first = excessive.first {
            interpretation = "\(first.name) ya supera claramente el rango. No añadas más volumen de ese patrón hasta recuperar."
        } else if missing.isEmpty {
            interpretation = "Cobertura completa. No necesitas añadir fuerza solo para cumplir volumen; decide la próxima sesión por recuperación y objetivos."
        } else {
            let priorities = missing.prefix(2).map(\.name).joined(separator: " y ")
            interpretation = "Prioridad de fuerza: \(priorities), siempre que la recuperación de esas zonas lo permita."
        }
        let context = focus.running >= 0.62
            ? "Rangos de mantenimiento adaptados a un bloque con prioridad de running."
            : focus.strength >= 0.42 ? "Rangos elevados por el peso actual de tus objetivos de fuerza." : "Rangos equilibrados para un objetivo híbrido."
        return StrengthCoverageSummary(days: days, items: items, interpretation: interpretation, context: context)
    }

    private static func progress(for name: String, workouts: [ImportedWorkout], now: Date) -> ExerciseStrengthProgress? {
        let calendar = Calendar.current
        let entries = workouts.sorted { $0.start < $1.start }.compactMap { workout -> (Date, ImportedExercise, [ImportedSet])? in
            guard let exercise = workout.exercises.first(where: { $0.name == name }) else { return nil }
            let sets = workingSets(exercise)
            guard !sets.isEmpty else { return nil }
            return (workout.start, exercise, sets)
        }
        guard !entries.isEmpty else { return nil }

        let points = entries.compactMap { date, exercise, sets -> StrengthProgressPoint? in
            let estimates = sets.compactMap(estimatedOneRM)
            guard let best = estimates.max() else { return nil }
            return StrengthProgressPoint(date: date, exercise: name, estimatedOneRM: best, volume: exercise.volume, effectiveSets: sets.count)
        }
        let allSets = entries.flatMap { date, _, sets in sets.map { (date, $0) } }
        let bestSet = allSets.compactMap { date, set -> StrengthBestSet? in
            guard let estimate = estimatedOneRM(set) else { return nil }
            return StrengthBestSet(weight: set.weight, reps: set.reps, date: date, estimatedOneRM: estimate)
        }.max { $0.estimatedOneRM < $1.estimatedOneRM }

        let recentStart = calendar.date(byAdding: .day, value: -28, to: now) ?? now
        let priorStart = calendar.date(byAdding: .day, value: -84, to: now) ?? now
        let latest = points.filter { $0.date >= recentStart }.map(\.estimatedOneRM).max() ?? points.last?.estimatedOneRM
        let previous = points.filter { $0.date >= priorStart && $0.date < recentStart }.map(\.estimatedOneRM).max()
            ?? points.dropLast().suffix(3).map(\.estimatedOneRM).max()
        let latestVolume = entries.last?.1.volume ?? 0
        let recentSets = entries.filter { $0.0 >= recentStart }.reduce(0) { $0 + $1.2.count }

        return ExerciseStrengthProgress(name: name, sessions: entries.count, points: points, bestSet: bestSet, latestOneRM: latest, previousOneRM: previous, latestVolume: latestVolume, recentEffectiveSets: recentSets)
    }

    private static func workingSets(_ exercise: ImportedExercise) -> [ImportedSet] {
        // "La serie tiene contenido real", no "tiene repeticiones": una serie
        // de plancha o de trineo no tiene reps y sí es una serie hecha.
        // Filtrar por reps > 0 las descartaba enteras del progreso de fuerza.
        let details = (exercise.setDetails ?? []).filter {
            ($0.reps > 0 || ($0.durationSeconds ?? 0) > 0) && $0.weight >= 0
        }
        return workingSets(details)
    }

    // A lift's own warm-up ramp — ascending weight before the real working
    // sets, e.g. "las 3 primeras series subiendo el volumen, para calentar,
    // luego 3 o 4 series válidas" — inflates counted sets/volume and drags
    // the suggested working weight down toward the warm-up average if
    // nothing filters it out. Hevy's own set_type tag (warmup/calentamiento)
    // is the source of truth whenever the athlete actually used it — always
    // respected first, never overridden by a guess. When nothing in the
    // exercise was tagged at all (every set defaults to "normal" — true for
    // every éter-logged session, since there's no in-session warm-up toggle
    // yet, and for any Hevy session the athlete never bothered tagging),
    // this infers the same thing from the one signal that's always there:
    // an ascending ramp that plateaus at the final (heaviest) weight is a
    // warm-up ramp by definition, tagged or not. Never invents a ramp that
    // isn't there — flat sessions (no ramp, or already tagged) pass through
    // unchanged, and bodyweight movements (no meaningful weight signal)
    // are left alone entirely.
    static func workingSets(_ details: [ImportedSet]) -> [ImportedSet] {
        let explicitlyTagged = details.filter { let type = $0.type.lowercased(); return type.contains("warm") || type.contains("calent") }
        guard explicitlyTagged.isEmpty else {
            return details.filter { let type = $0.type.lowercased(); return !type.contains("warm") && !type.contains("calent") }
        }
        guard details.count >= 2, let workingWeight = details.last?.weight, workingWeight > 0 else { return details }
        var cursor = 0
        while cursor < details.count - 1,
              details[cursor].weight > 0, details[cursor].weight < workingWeight * 0.85,
              details[cursor].weight <= details[cursor + 1].weight {
            cursor += 1
        }
        return Array(details[cursor...])
    }

    /// Same rule as `workingSets` above, but returns which INDICES are
    /// warm-up instead of a filtered array — for display, where a set's
    /// position in the original list matters (e.g. a workout detail screen
    /// marking "Serie 1 (calentamiento)" next to the real set numbers).
    static func warmupIndices(_ details: [ImportedSet]) -> Set<Int> {
        let explicitlyTagged = details.contains { let type = $0.type.lowercased(); return type.contains("warm") || type.contains("calent") }
        if explicitlyTagged {
            return Set(details.indices.filter {
                let type = details[$0].type.lowercased(); return type.contains("warm") || type.contains("calent")
            })
        }
        guard details.count >= 2, let workingWeight = details.last?.weight, workingWeight > 0 else { return [] }
        var cursor = 0
        while cursor < details.count - 1,
              details[cursor].weight > 0, details[cursor].weight < workingWeight * 0.85,
              details[cursor].weight <= details[cursor + 1].weight {
            cursor += 1
        }
        return Set(0..<cursor)
    }

    // How much a set actually stimulates hypertrophy/fatigue scales with
    // proximity to failure, not just whether it happened — a recent
    // meta-regression (Robinson et al. 2024, pubmed 38970765) and review
    // (Grgic 2023, pubmed 36334240) both point to effort/proximity-to-
    // failure mattering more for hypertrophy than for pure strength,
    // without that meaning failure should be chased on every set. When
    // RPE/RIR was actually logged, a set far from failure counts for
    // less; when it wasn't (the common case — most sessions have no RPE
    // at all), this stays neutral (1.0) rather than guessing an effort
    // level nobody recorded. Never applied to strength/1RM estimation
    // (estimatedOneRM below) — a heavy top set's *weight* is what
    // matters there, not how many total sets it represents.
    static func effortWeight(_ set: ImportedSet) -> Double {
        set.rpe.map(effortWeight(forRPE:)) ?? 1.0
    }

    /// Same bands as above, taking a bare RPE instead of a logged set —
    /// for a session that hasn't happened yet (weekAhead's forward
    /// simulation, estimating a proposed set's effort from its
    /// prescribed RIR) as well as a real one.
    static func effortWeight(forRPE rpe: Double) -> Double {
        switch rpe {
        case 8...: return 1.0
        case 7..<8: return 0.85
        case 6..<7: return 0.7
        case 5..<6: return 0.55
        default: return 0.4
        }
    }

    // The effort-weighted equivalent of workingSets(_:).count — a real
    // set still counts as "happened" for warm-up filtering purposes, but
    // how much it contributes to muscle-fatigue/hypertrophy-volume
    // tallies scales by how close to failure it was.
    static func effectiveSetCount(_ details: [ImportedSet]) -> Double {
        workingSets(details).reduce(0.0) { $0 + effortWeight($1) }
    }

    private static func estimatedOneRM(_ set: ImportedSet) -> Double? {
        guard set.weight > 0, (1...12).contains(set.reps) else { return nil }
        return set.weight * (1 + Double(set.reps) / 30)
    }

    private static func patternLoads(_ workouts: [ImportedWorkout]) -> [StrengthPatternLoad] {
        let names = ["Empuje", "Tirón", "Sentadilla", "Bisagra", "Core"]
        var totals = Dictionary(uniqueKeysWithValues: names.map { ($0, 0.0) })
        for exercise in workouts.flatMap(\.exercises) {
            let sets = exercise.setDetails.map(effectiveSetCount) ?? Double(workingSets(exercise).count)
            guard sets > 0 else { continue }
            for pattern in patterns(for: exercise.name) { totals[pattern, default: 0] += sets }
        }
        let total = max(1.0, totals.values.reduce(0, +))
        return names.map { StrengthPatternLoad(name: $0, sets: Int(totals[$0, default: 0].rounded()), share: totals[$0, default: 0] / total) }
    }

    // Same muscle-to-pattern grouping patterns(for:) already falls back to
    // for an unrecognized exercise name — used here for HealthKit's generic
    // per-muscle involvement, which has no exercise name to match against.
    private static func pattern(forMuscle muscle: String) -> String? {
        switch muscle {
        case "Pecho", "Hombros", "Tríceps": return "Empuje"
        case "Espalda", "Bíceps": return "Tirón"
        case "Cuádriceps": return "Sentadilla"
        case "Glúteos", "Isquios": return "Bisagra"
        case "Core": return "Core"
        default: return nil
        }
    }

    private static func patterns(for exercise: String) -> [String] {
        let value = exercise.lowercased()
        if value.contains("deadlift") || value.contains("peso muerto") || value.contains("romanian") || value.contains("hip thrust") || value.contains("good morning") { return ["Bisagra"] }
        if value.contains("squat") || value.contains("sentadilla") || value.contains("leg press") || value.contains("lunge") || value.contains("zancada") || value.contains("split squat") { return ["Sentadilla"] }
        if value.contains("plank") || value.contains("plancha") || value.contains("crunch") || value.contains("ab ") || value.contains("core") || value.contains("sit up") { return ["Core"] }
        let muscles = Set(MuscleMap.groups(for: exercise))
        if !muscles.intersection(["Pecho", "Hombros", "Tríceps"]).isEmpty { return ["Empuje"] }
        if !muscles.intersection(["Espalda", "Bíceps"]).isEmpty { return ["Tirón"] }
        if !muscles.intersection(["Cuádriceps"]).isEmpty { return ["Sentadilla"] }
        if !muscles.intersection(["Glúteos", "Isquios"]).isEmpty { return ["Bisagra"] }
        if muscles.contains("Core") { return ["Core"] }
        return []
    }
}
