import Foundation

// Cómo se mide un ejercicio. Era un booleano `isTimed`, y con dos estados no
// se podía expresar ni "cuenta repeticiones y además cronometro cuánto tardo"
// (lo que hace Hevy) ni "trineo/remo/ski, que son tiempo Y distancia y no
// tienen repeticiones en absoluto".
enum ExerciseMeasurement: String, Equatable {
    // Estándar: repeticiones. La duración es OPCIONAL — se puede cronometrar
    // la serie sin que eso cambie que lo que cuenta son las reps.
    case reps
    // Planchas y holds: sólo tiempo. "Cuántas repeticiones de plancha" no es
    // una pregunta coherente.
    case time
    // Trineo, remo, ski: tiempo Y distancia. Ninguna de las dos por separado
    // describe la serie — 200 m de trineo en 90 s y en 150 s no son lo mismo.
    case timeAndDistance
}

struct ExerciseDescriptor: Identifiable {
    var id: String { name }
    let name: String
    let pattern: String
    let equipment: String
    let symbol: String
    var measurement: ExerciseMeasurement = .reps
    /// El equipamiento que significa "sin carga externa que registrar".
    static let bodyweightEquipment = "Peso corporal"

    // Un ergómetro de remo o ski no tiene carga externa que registrar: pedir
    // kilos ahí es pedir un dato que no existe. El trineo sí la tiene, así que
    // no se puede inferir del tipo de medición.
    // (Hevy hace lo mismo: para el Ski Erg muestra KM y TIME, sin KG.)
    //
    // Lo que sí se puede inferir es el peso corporal, y es lo que faltaba: una
    // plancha y unas flexiones pedían kilos porque el default era `true` y
    // nadie las había marcado a mano. Ahora se DERIVA del equipamiento, que ya
    // estaba correctamente puesto en todo el catálogo, así que ningún ejercicio
    // de peso corporal que se añada en el futuro puede volver a pedirlos por
    // olvido. `weightOverride` queda para lo que el equipamiento no explica —
    // los ergómetros, que son máquinas sin carga.
    var weightOverride: Bool? = nil
    var tracksWeight: Bool { weightOverride ?? (equipment != Self.bodyweightEquipment) }

    // Conveniencia derivada, no un segundo estado: "no se cuenta por reps".
    var isTimed: Bool { measurement != .reps }
    var tracksDistance: Bool { measurement == .timeAndDistance }
}

enum ExerciseCatalog {
    static let descriptors: [ExerciseDescriptor] = [
        .init(name: "Bench Press (Barbell)", pattern: "Empuje horizontal", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Bench Press (Dumbbell)", pattern: "Empuje horizontal", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Incline Bench Press (Dumbbell)", pattern: "Empuje inclinado", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Push Up", pattern: "Empuje horizontal", equipment: "Peso corporal", symbol: "figure.strengthtraining.functional"),
        .init(name: "Dip", pattern: "Empuje vertical", equipment: "Peso corporal", symbol: "figure.strengthtraining.functional"),
        .init(name: "Standing Military Press (Barbell)", pattern: "Empuje vertical", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Shoulder Press (Dumbbell)", pattern: "Empuje vertical", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Lateral Raise (Dumbbell)", pattern: "Aislamiento de hombro", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Chest Fly (Cable)", pattern: "Aislamiento de pecho", equipment: "Polea", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Triceps Extension (Cable)", pattern: "Aislamiento de tríceps", equipment: "Polea", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Skullcrusher (Barbell)", pattern: "Aislamiento de tríceps", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Pull Up", pattern: "Tirón vertical", equipment: "Peso corporal", symbol: "figure.strengthtraining.functional"),
        .init(name: "Chin Up", pattern: "Tirón vertical", equipment: "Peso corporal", symbol: "figure.strengthtraining.functional"),
        .init(name: "Lat Pulldown (Cable)", pattern: "Tirón vertical", equipment: "Polea", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Seated Cable Row", pattern: "Tirón horizontal", equipment: "Polea", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Bent Over Row (Barbell)", pattern: "Tirón horizontal", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "One Arm Row (Dumbbell)", pattern: "Tirón horizontal", equipment: "Mancuerna", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Face Pull", pattern: "Tirón y hombro", equipment: "Polea", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Biceps Curl (Dumbbell)", pattern: "Aislamiento de bíceps", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Hammer Curl (Dumbbell)", pattern: "Aislamiento de bíceps", equipment: "Mancuernas", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Squat (Barbell)", pattern: "Sentadilla", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Front Squat (Barbell)", pattern: "Sentadilla", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Goblet Squat", pattern: "Sentadilla", equipment: "Mancuerna", symbol: "figure.strengthtraining.functional"),
        .init(name: "Leg Press (Machine)", pattern: "Sentadilla", equipment: "Máquina", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Bulgarian Split Squat", pattern: "Sentadilla unilateral", equipment: "Mancuernas", symbol: "figure.strengthtraining.functional"),
        .init(name: "Walking Lunge", pattern: "Sentadilla unilateral", equipment: "Libre", symbol: "figure.walk"),
        .init(name: "Leg Extension (Machine)", pattern: "Aislamiento de cuádriceps", equipment: "Máquina", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Deadlift (Barbell)", pattern: "Bisagra", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Romanian Deadlift (Barbell)", pattern: "Bisagra", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Hip Thrust (Barbell)", pattern: "Bisagra", equipment: "Barra", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Leg Curl (Machine)", pattern: "Aislamiento de isquios", equipment: "Máquina", symbol: "figure.strengthtraining.traditional"),
        .init(name: "Calf Raise", pattern: "Gemelos", equipment: "Libre", symbol: "figure.strengthtraining.functional"),
        .init(name: "Plank", pattern: "Core anti-extensión", equipment: "Peso corporal", symbol: "figure.core.training", measurement: .time),
        .init(name: "Side Plank", pattern: "Core lateral", equipment: "Peso corporal", symbol: "figure.core.training", measurement: .time),
        .init(name: "Dead Bug", pattern: "Core anti-extensión", equipment: "Peso corporal", symbol: "figure.core.training"),
        .init(name: "Pallof Press", pattern: "Core anti-rotación", equipment: "Polea", symbol: "figure.core.training"),
        .init(name: "Hanging Leg Raise", pattern: "Core", equipment: "Peso corporal", symbol: "figure.core.training"),
        .init(name: "Farmer Carry", pattern: "Carga y core", equipment: "Mancuernas", symbol: "figure.strengthtraining.functional", measurement: .time),
        .init(name: "Kettlebell Swing", pattern: "Bisagra explosiva", equipment: "Kettlebell", symbol: "figure.strengthtraining.functional"),
        .init(name: "Thruster (Dumbbell)", pattern: "Cuerpo completo", equipment: "Mancuernas", symbol: "figure.cross.training"),
        // Estaciones de HYROX que el catálogo no tenía: sin ellas no se podían
        // registrar en éter, y por tanto tampoco alimentar el componente de
        // estaciones del forecast. Las cuatro se miden en tiempo y distancia.
        .init(name: "Sled Push", pattern: "Empuje horizontal cargado", equipment: "Trineo",
              symbol: "figure.strengthtraining.functional", measurement: .timeAndDistance),
        .init(name: "Sled Pull", pattern: "Tirón horizontal cargado", equipment: "Trineo",
              symbol: "figure.strengthtraining.functional", measurement: .timeAndDistance),
        .init(name: "Rowing Machine", pattern: "Tirón cíclico", equipment: "Remo ergómetro",
              symbol: "figure.rower", measurement: .timeAndDistance, weightOverride: false),
        .init(name: "SkiErg", pattern: "Tirón vertical cíclico", equipment: "Ski ergómetro",
              symbol: "figure.skiing.crosscountry", measurement: .timeAndDistance, weightOverride: false)
    ]

    static func descriptor(for name: String) -> ExerciseDescriptor {
        descriptors.first { normalized($0.name) == normalized(name) }
            ?? ExerciseDescriptor(name: name, pattern: inferredPattern(name), equipment: inferredEquipment(name),
                                  symbol: "figure.strengthtraining.traditional", measurement: inferredMeasurement(name),
                                  // Sólo se declara cuando la inferencia dice
                                  // explícitamente "sin carga"; en el resto se
                                  // deja derivar del equipamiento inferido, que
                                  // ya reconoce el peso corporal.
                                  weightOverride: inferredTracksWeight(name) ? nil : false)
    }

    /// Construye la serie que se persiste desde una serie en vivo de éter.
    /// Vive aquí, junto a `isTimed`, para que la interpretación de "este número
    /// son segundos, no repeticiones" tenga un solo sitio — y para que sea
    /// testeable, que dentro de la vista de sesión no lo era.
    /// `reps` son repeticiones de verdad (0 en los ejercicios que no las
    /// tienen), y la duración/distancia van en sus propios campos. Antes los
    /// segundos viajaban dentro de `reps`, donde eran indistinguibles de
    /// repeticiones e inflaban el volumen (peso × reps).
    static func loggedSet(weight: Double, reps: Int, type: String, exerciseName: String,
                          durationSeconds: Double? = nil, distanceMeters: Double? = nil) -> ImportedSet {
        let measurement = descriptor(for: exerciseName).measurement
        // En un ejercicio por tiempo o por tiempo y distancia no hay
        // repeticiones que contar: se guarda 0, no el número de segundos.
        let countedReps = measurement == .reps ? reps : 0
        return ImportedSet(weight: weight, reps: countedReps, type: type, rpe: nil,
                           durationSeconds: durationSeconds.flatMap { $0 > 0 ? $0 : nil },
                           distanceMeters: measurement == .timeAndDistance ? distanceMeters.flatMap { $0 > 0 ? $0 : nil } : nil)
    }

    /// Name-based fallback for holds/carries not in the fixed catalog above
    /// (custom entries, different Hevy naming, etc.) — same idea as
    /// inferredPattern/inferredEquipment below.
    /// Ergómetros: sin carga externa que registrar. El trineo sí la lleva.
    private static func inferredTracksWeight(_ name: String) -> Bool {
        let value = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return !["row erg", "rowing machine", "remo ergometro", "concept2", "skierg", "ski erg"]
            .contains { value.contains($0) }
    }

    private static func inferredMeasurement(_ name: String) -> ExerciseMeasurement {
        let value = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        // Nombres distintos para la misma estación (catálogo propio, otro
        // idioma, nomenclatura de Hevy) tienen que caer en el mismo tipo.
        if ["sled", "trineo", "row erg", "rowing machine", "remo ergometro", "concept2",
            "skierg", "ski erg"].contains(where: { value.contains($0) }) { return .timeAndDistance }
        if ["plank", "plancha", "wall sit", "dead hang", "hollow hold", "l-sit", "lsit", "carry",
            "acarreo", "granjero"].contains(where: { value.contains($0) }) { return .time }
        return .reps
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private static func inferredPattern(_ name: String) -> String {
        let muscles = Set(MuscleMap.groups(for: name))
        if !muscles.intersection(["Pecho", "Hombros", "Tríceps"]).isEmpty { return "Empuje" }
        if !muscles.intersection(["Espalda", "Bíceps"]).isEmpty { return "Tirón" }
        if !muscles.intersection(["Cuádriceps"]).isEmpty { return "Sentadilla" }
        if !muscles.intersection(["Glúteos", "Isquios"]).isEmpty { return "Bisagra" }
        if muscles.contains("Core") { return "Core" }
        return "Fuerza"
    }

    private static func inferredEquipment(_ name: String) -> String {
        let value = name.lowercased()
        if value.contains("barbell") || value.contains("barra") { return "Barra" }
        if value.contains("dumbbell") || value.contains("mancuerna") { return "Mancuernas" }
        if value.contains("cable") || value.contains("polea") { return "Polea" }
        if value.contains("machine") || value.contains("máquina") { return "Máquina" }
        // Ampliado: la lista corta dejaba fuera fondos, dominadas en español,
        // abdominales, sentadillas al aire y los holds de core — todos peso
        // corporal, y todos pidiendo kilos por ese motivo. Con tracksWeight
        // ahora derivado del equipamiento, esta lista es la que decide si un
        // ejercicio desconocido muestra la columna KG.
        let bodyweight = ["pull up", "pull-up", "dominada", "chin up", "push up", "push-up", "flexion",
                          "dip", "fondo", "plank", "plancha", "sit up", "crunch", "abdominal",
                          "air squat", "sentadilla al aire", "burpee", "mountain climber",
                          "hollow", "dead bug", "l-sit", "lsit", "wall sit", "dead hang",
                          "glute bridge", "puente de gluteo", "pike"]
        // Pero "peso corporal" y "sin kilos" no son lo mismo: una dominada
        // lastrada o un fondo con cinturón son exactamente los movimientos en
        // los que el lastre ES el dato que hay que registrar. Un test lo pilló:
        // "Weighted Pull Up" contiene "pull up" y perdía la columna de KG.
        let loaded = ["weighted", "lastrad", "con lastre", "con peso", "belt", "cinturon", "banded"]
        let normalized = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if loaded.contains(where: { normalized.contains($0) }) { return "Libre" }
        if bodyweight.contains(where: { normalized.contains($0) }) { return "Peso corporal" }
        return "Libre"
    }
}

// What a given strength exercise is actually *for*, right now, for this
// athlete — the missing branch the critique correctly flagged: éter used to
// prescribe every exercise with the same hypertrophy-shaped rep range and
// progression rule regardless of whether the athlete's real goal was a
// tracked 1RM lift, general muscle growth, or just staying durable for an
// endurance event. One fixed template can't serve all three at once —
// specificity work wants low reps near failure, minimum-effective-dose work
// wants the opposite, and neither is "hypertrophy with different numbers."
enum StrengthGoalContext { case liftSpecificity, enduranceSupport, hypertrophy }

enum StrengthPrescriptionEngine {
    private static let enduranceGoalKinds: Set<TrainingGoalKind> = [.marathon, .halfMarathon, .triathlon, .ironman, .hyrox, .fiveK, .tenK]
    private static let strengthFocusGoalKinds: Set<TrainingGoalKind> = [.benchPress, .squat, .deadlift, .hypertrophy]

    /// A tracked 1RM goal only earns lift-specific treatment on the *exact*
    /// lift it tracks — "100 kg de press banca" doesn't make every push
    /// exercise low-rep, just Bench Press itself; everything else around it
    /// still serves hypertrophy/support the way it did before. Exact-name
    /// comparison, not substring `contains`, because "bench press" as a
    /// substring also matches "Incline Bench Press (Dumbbell)" and
    /// "deadlift (barbell)" also matches "Romanian Deadlift (Barbell)" —
    /// neither is the flat-barbell lift the goal's number actually means.
    private static func matchesTrackedLift(_ exerciseName: String, kind: TrainingGoalKind) -> Bool {
        let canonicalNames: [String]
        switch kind {
        case .benchPress: canonicalNames = ["Bench Press (Barbell)", "Press Banca"]
        case .squat: canonicalNames = ["Squat (Barbell)", "Sentadilla"]
        case .deadlift: canonicalNames = ["Deadlift (Barbell)", "Peso Muerto"]
        default: return false
        }
        return canonicalNames.contains { exerciseName.localizedCaseInsensitiveCompare($0) == .orderedSame }
    }

    /// The single place this decision gets made, so the live routine
    /// builder (`prescribe`) and the "Entrenamiento propuesto" preview
    /// (`WorkoutPlanner.gym`) always agree on why today's session looks the
    /// way it does.
    static func goalContext(for exerciseName: String, goals: [TrainingGoal]) -> StrengthGoalContext {
        let active = goals.filter(\.isActive)
        if active.contains(where: { matchesTrackedLift(exerciseName, kind: $0.kind) }) { return .liftSpecificity }
        let kinds = Set(active.map(\.kind))
        // An athlete training for a race/HYROX strength-trains to stay
        // durable, not to maximize muscle — minimum effective dose, clear of
        // failure, so it never eats into running/riding recovery. Only
        // kicks in when there's no competing explicit strength/hypertrophy
        // goal; someone chasing both a marathon and a bench PR still needs
        // real work on the parts that aren't the tracked lift.
        if !kinds.isDisjoint(with: enduranceGoalKinds) && kinds.isDisjoint(with: strengthFocusGoalKinds) { return .enduranceSupport }
        return .hypertrophy
    }

    /// The set×rep×RIR template for a given context. `light` is the existing
    /// deload signal `WorkoutPlanner.gym` already carries; endurance-support
    /// has no separate deload variant because it's already the conservative
    /// end of the spectrum. `sets`/`estimatedRIR` are the same numbers
    /// already embedded in `label`'s text, exposed numerically too — for
    /// weekAhead's forward fatigue simulation, which needs to compute a
    /// real effective-set count instead of parsing the display string.
    static func repRange(for context: StrengthGoalContext, light: Bool)
        -> (label: String, minReps: Int, maxReps: Int, rationale: String, sets: Int, estimatedRIR: Double) {
        switch context {
        case .liftSpecificity:
            return light
                ? ("3 × 5–6 · RIR 3", 5, 6, "Descarga: técnica cerca de tu rango objetivo, sin buscar el límite.", 3, 3)
                : ("4 × 3–5 · RIR 1–2", 3, 5, "Especificidad de fuerza para tu objetivo de 1RM: pocas repeticiones, cerca del fallo real.", 4, 1.5)
        case .enduranceSupport:
            return ("2–3 × 10–12 · RIR 4", 10, 12, "Dosis mínima eficaz: mantiene la fuerza sin restar recuperación a tu carrera/triatlón.", 3, 4)
        case .hypertrophy:
            return light
                ? ("3 × 8–10 · RIR 3", 8, 10, "", 3, 3)
                : ("3–4 × 6–10 · RIR 2", 6, 10, "", 4, 2)
        }
    }

    /// Same readiness→load-factor bands `prescribe` already used inline, now
    /// shared with DecisionSimulatorEngine's "cómo vas a rendir hoy" note so
    /// there is exactly one definition of what a given readiness does to load.
    static func readinessLoadFactor(_ readiness: Int) -> Double {
        if readiness < 45 { return 1.0 - 0.12 }
        if readiness < 60 { return 1.0 - 0.07 }
        if readiness >= 84 { return 1.0 + 0.015 }
        return 1.0
    }

    static func prescribe(
        _ exercise: RoutineExercise,
        workouts: [ImportedWorkout],
        readiness: Int,
        muscleReadiness: [MuscleReadiness],
        injuries: [InjuryRecord] = [],
        goals: [TrainingGoal] = [],
        now: Date = Date()
    ) -> RoutineExercise? {
        guard InjurySafetyEngine.exerciseSafety(exercise.name, injuries: injuries).allowed else { return nil }
        let history = workouts.sorted { $0.start > $1.start }.compactMap { workout -> (Date, ImportedExercise, [ImportedSet])? in
            guard let match = workout.exercises.first(where: { equivalent($0.name, exercise.name) }) else { return nil }
            let working = workingSets(match)
            return working.isEmpty ? nil : (workout.start, match, working)
        }.prefix(5)
        guard let latest = history.first else {
            var result = exercise
            result.prescriptionNote = "Sin historial comparable: propuesta inicial editable"
            result.historySessions = 0
            return result
        }

        let sessions = Array(history)
        let setCount = medianInt(sessions.map { $0.2.count })
        let representative = latest.2.sorted { estimatedOneRM($0) > estimatedOneRM($1) }.first ?? latest.2[0]
        var targetWeight = representative.weight
        var targetReps = representative.reps
        var reasons: [String] = ["basado en \(sessions.count) sesión\(sessions.count == 1 ? "" : "es")"]

        let relevant = Set(MuscleMap.groups(for: exercise.name))
        let local = muscleReadiness.filter { relevant.contains($0.name) }.map(\.readiness).min() ?? readiness
        let effectiveReadiness = min(readiness, local)
        let days = max(0, Calendar.current.dateComponents([.day], from: latest.0, to: now).day ?? 0)

        var loadFactor = readinessLoadFactor(effectiveReadiness)
        if effectiveReadiness < 45 { reasons.append("recuperación baja") }
        else if effectiveReadiness < 60 { reasons.append("recuperación parcial") }
        else if effectiveReadiness >= 84 { reasons.append("buena disponibilidad") }

        if days >= 42 { loadFactor -= 0.10; reasons.append("\(days) días sin practicarlo") }
        else if days >= 21 { loadFactor -= 0.05; reasons.append("retorno tras \(days) días") }

        let context = goalContext(for: exercise.name, goals: goals)
        let latestRPE = latest.2.compactMap(\.rpe).max()
        let recentEstimates = sessions.compactMap { session in session.2.map(estimatedOneRM).max() }
        let stableOrImproving = recentEstimates.count >= 2 && recentEstimates[0] >= recentEstimates[1] * 0.98
        // Endurance-support deliberately skips the progression push — the
        // point of this context is a flat minimum effective dose that never
        // competes with the athlete's actual sport for recovery, not a
        // steadily heavier lift.
        if context != .enduranceSupport, effectiveReadiness >= 65, days < 21, stableOrImproving, (latestRPE ?? 8) <= 8.5 {
            if targetReps < 12 {
                targetReps += 1
                reasons.append("progresión de 1 repetición")
            } else {
                loadFactor += 0.025
                targetReps = max(5, targetReps - 2)
                reasons.append("progresión de carga")
            }
        }

        // Bend the historically-typical rep count toward what this exercise
        // is actually *for* today, re-deriving weight from the same e1RM
        // estimate `representative` was picked by — a tracked lift held at
        // whatever rep count it happened to be logged at last time isn't
        // specificity, and an endurance-support exercise inheriting a
        // hypertrophy rep count isn't a minimum effective dose.
        if context != .hypertrophy {
            let band = repRange(for: context, light: false)
            let clampedReps = min(max(targetReps, band.minReps), band.maxReps)
            let e1RM = estimatedOneRM(representative)
            if e1RM > 0 { targetWeight = e1RM / (1 + Double(min(12, clampedReps)) / 30) }
            targetReps = clampedReps
            reasons.append(context == .liftSpecificity ? "especificidad de fuerza (\(band.minReps)-\(band.maxReps) reps)" : "apoyo de resistencia (\(band.minReps)-\(band.maxReps) reps)")
        }

        targetWeight = roundedLoad(targetWeight * loadFactor)
        if targetWeight == 0 { targetReps = max(1, representative.reps) }
        let prescribed = (0..<max(1, setCount)).map { _ in
            ImportedSet(weight: targetWeight, reps: max(1, targetReps), type: "normal", rpe: nil)
        }
        var result = exercise
        result.sets = prescribed
        result.prescriptionNote = reasons.joined(separator: " · ")
        result.historySessions = sessions.count
        return result
    }

    private static func workingSets(_ exercise: ImportedExercise) -> [ImportedSet] {
        let detailed = (exercise.setDetails ?? []).filter {
            let type = $0.type.lowercased()
            return $0.reps > 0 && $0.weight >= 0 && !type.contains("warm") && !type.contains("calent") && !type.contains("drop")
        }
        if !detailed.isEmpty { return detailed }
        guard exercise.sets > 0 else { return [] }
        let reps = max(1, (exercise.totalReps ?? exercise.sets * 8) / exercise.sets)
        return (0..<exercise.sets).map { _ in
            ImportedSet(weight: exercise.averageWeight ?? 0, reps: reps, type: "normal", rpe: nil)
        }
    }

    private static func equivalent(_ left: String, _ right: String) -> Bool {
        left.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == right.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func estimatedOneRM(_ set: ImportedSet) -> Double {
        guard set.weight > 0 else { return 0 }
        return set.weight * (1 + Double(min(12, set.reps)) / 30)
    }

    private static func medianInt(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 3 }
        let sorted = values.sorted()
        return max(1, sorted[sorted.count / 2])
    }

    private static func roundedLoad(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let step = value < 20 ? 1.0 : 2.5
        return (value / step).rounded() * step
    }
}
