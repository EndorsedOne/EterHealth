import Foundation

struct InjurySafetyResult {
    let allowed: Bool
    let reason: String?
}

enum InjurySafetyEngine {
    // PR8: la versión estructurada de lo que TwinEngine.safeRecommendation
    // hacía reescribiendo el texto en español. Ese método miraba
    // `recommendation.lowercased().contains("carrera")`, `"tirada"`,
    // `"brick"`, `"empuje"`, `"tirón"`, `"pierna"`, `"natación"`,
    // `"ciclismo"`, `"fuerza"` y devolvía OTRO string —
    // "Recuperación o trabajo sin impacto", "Tren superior compatible"— que
    // WorkoutPlanner volvía a parsear para elegir la sesión. Tres capas de
    // texto para expresar un veto que es, literalmente, un Set de enums.
    //
    // Aquí vive el conocimiento de qué bloquea cada restricción, en el mismo
    // archivo que ya era la única definición de eso para ejercicios
    // concretos (exerciseSafety) y para la sesión ya construida (sanitize).
    // TrainingPlanEngine.status lo aplica ANTES de publicar
    // WeeklyPlanStatus.nextSession, así que el plan que sale del motor ya es
    // compatible con las restricciones activas — no un plan que la UI
    // tuviera que corregir después.
    //
    // Fidelidad deliberada al comportamiento anterior en dos puntos:
    // - `.hybrid` no lo bloquea `.avoidRunning`. El texto que se
    //   comparaba antes era "Trabajo híbrido", que no contiene "carrera",
    //   así que nunca se bloqueó; sanitize sigue filtrando sus ejercicios
    //   uno a uno, que es donde la carrera de enlace sí se retira.
    // - `.raceDay` no lo bloquea nada. Una restricción activa no cancela
    //   una competición del calendario; el protocolo de competición
    //   incluye sus propios criterios de parada.
    nonisolated static func allows(_ kind: PlannedSessionKind, injuries: [InjuryRecord]) -> Bool {
        let restrictions = Set(injuries.flatMap(\.restrictions))
        switch kind {
        case .easyRun, .qualityRun, .longRun:
            return !restrictions.contains(.avoidRunning) && !restrictions.contains(.avoidLowerBody)
        case .brick:
            // Bici + carrera: le aplican las dos restricciones.
            return !restrictions.contains(.avoidRunning) && !restrictions.contains(.avoidLowerBody)
        case .bike:
            return !restrictions.contains(.avoidLowerBody)
        case .swim:
            return !restrictions.contains(.avoidUpperBody)
        case .strength:
            // `.avoidStrength` mata la sesión entera; las restricciones de
            // tren superior/inferior sólo vetan patrones, y eso lo resuelve
            // allowedPatterns abajo — puede quedar uno compatible.
            return !restrictions.contains(.avoidStrength)
        case .hybrid, .raceDay, .recovery:
            return true
        }
    }

    // Qué patrones de fuerza siguen siendo entrenables. Vacío significa que
    // no queda ninguno: quien pregunte debe proponer otra cosa, no elegir
    // uno "por defecto".
    nonisolated static func allowedPatterns(injuries: [InjuryRecord]) -> [StrengthPattern] {
        let restrictions = Set(injuries.flatMap(\.restrictions))
        guard !restrictions.contains(.avoidStrength) else { return [] }
        return StrengthPattern.allCases.filter { pattern in
            switch pattern {
            case .legs: return !restrictions.contains(.avoidLowerBody)
            case .push, .pull: return !restrictions.contains(.avoidUpperBody)
            }
        }
    }

    static func sessionAllowsRunning(_ injuries: [InjuryRecord]) -> InjurySafetyResult {
        if let injury = injuries.first(where: { $0.restrictions.contains(.avoidRunning) }) {
            return InjurySafetyResult(allowed: false, reason: "Carrera bloqueada por la restricción activa en \(injury.area).")
        }
        if let injury = injuries.first(where: { lowerBodyArea($0.area) && $0.severity >= 4 }) {
            return InjurySafetyResult(allowed: false, reason: "Carrera bloqueada por la lesión activa de intensidad \(injury.severity)/5 en \(injury.area).")
        }
        return InjurySafetyResult(allowed: true, reason: nil)
    }

    static func exerciseSafety(_ exercise: String, injuries: [InjuryRecord]) -> InjurySafetyResult {
        guard !injuries.isEmpty else { return InjurySafetyResult(allowed: true, reason: nil) }
        let muscles = Set(MuscleMap.groups(for: exercise))
        let lower = !muscles.isDisjoint(with: ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"])
        let upper = !muscles.isDisjoint(with: ["Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps"])

        for injury in injuries {
            if injury.restrictions.contains(.avoidStrength) {
                return blocked(exercise, injury: injury, restriction: "fuerza")
            }
            if lower && injury.restrictions.contains(.avoidLowerBody) {
                return blocked(exercise, injury: injury, restriction: "tren inferior")
            }
            if upper && injury.restrictions.contains(.avoidUpperBody) {
                return blocked(exercise, injury: injury, restriction: "tren superior")
            }
            if injury.severity >= 4 && specificAreaConflict(injury.area, exercise: exercise, muscles: muscles) {
                return blocked(exercise, injury: injury, restriction: "zona lesionada")
            }
        }
        return InjurySafetyResult(allowed: true, reason: nil)
    }

    static func sanitize(_ workout: ProposedWorkout, injuries: [InjuryRecord]) -> ProposedWorkout {
        // PR8: la sesión dice de qué tipo es (ProposedWorkout.kind), no se
        // deduce de su título. Antes esto buscaba "carrera"/"tirada"/"brick"
        // en el título, con dos errores que el propio dato ya sabía evitar:
        // "Brick bici-carrera" contiene "carrera", así que un brick se
        // clasificaba como carrera Y como brick a la vez; y una sesión de
        // HYROX ("Trabajo híbrido"), que sí lleva carrera de enlace real
        // dentro, no se clasificaba como carrera en absoluto — sólo la
        // salvaba el `exercises.contains("carrera")` de rebote.
        let usesRunning: Bool
        switch workout.kind {
        case .easyRun, .qualityRun, .longRun, .brick, .hybrid: usesRunning = true
        case .strength, .swim, .bike, .recovery, .raceDay: usesRunning = false
        }
        // El ejercicio suelto sigue contando: una propuesta de recuperación
        // puede ofrecer una carrera Z2 opcional (ver WorkoutPlanner's
        // "Después del tren superior"), y esa carrera está igual de
        // restringida que la de una sesión de carrera entera.
        let offersRunningExercise = workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("carrera") }
        if usesRunning || offersRunningExercise, let reason = sessionAllowsRunning(injuries).reason {
            return recoveryAlternative(reason: reason)
        }
        // Swimming is upper-body/shoulder dominant and cycling is a
        // sustained lower-body/hip-knee load — neither maps onto the
        // exercise-by-exercise strength filter below (their "exercises" are
        // set descriptions, not named lifts MuscleMap recognizes), so each
        // gets the same restriction-based block sessionAllowsRunning gives
        // running — now keyed off the session's own kind.
        if workout.kind == .swim,
           let injury = injuries.first(where: { $0.restrictions.contains(.avoidUpperBody) }) {
            return recoveryAlternative(reason: "Natación bloqueada por la restricción activa en \(injury.area).")
        }
        if workout.kind == .bike || workout.kind == .brick,
           let injury = injuries.first(where: { $0.restrictions.contains(.avoidLowerBody) && $0.severity >= 4 }) {
            return recoveryAlternative(reason: "Ciclismo bloqueado por la lesión activa de intensidad \(injury.severity)/5 en \(injury.area).")
        }

        let retained = workout.exercises.filter { exerciseSafety($0.name, injuries: injuries).allowed }
        let removed = workout.exercises.count - retained.count
        guard !retained.isEmpty else {
            return recoveryAlternative(reason: "La sesión propuesta entra en conflicto con tus restricciones activas.")
        }
        guard removed > 0 else { return workout }
        return ProposedWorkout(
            title: workout.title,
            duration: workout.duration,
            intent: workout.intent,
            exercises: retained,
            note: "\(workout.note) · Éter ha retirado \(removed) ejercicio\(removed == 1 ? "" : "s") incompatible\(removed == 1 ? "" : "s") con tus restricciones activas.",
            kind: workout.kind,
            strengthPattern: workout.strengthPattern
        )
    }

    static func filter(_ routine: StrengthRoutine, injuries: [InjuryRecord]) -> StrengthRoutine {
        let allowed = routine.exercises.filter { exerciseSafety($0.name, injuries: injuries).allowed }
        return StrengthRoutine(
            name: routine.name,
            subtitle: allowed.isEmpty ? "Bloqueada por restricciones activas" : allowed.map(\.name).joined(separator: " · "),
            exercises: allowed,
            lastPerformed: routine.lastPerformed,
            historicalVolume: routine.historicalVolume
        )
    }

    private static func recoveryAlternative(reason: String) -> ProposedWorkout {
        ProposedWorkout(
            title: "Recuperación compatible",
            duration: "15–30 min",
            intent: "No agravar la restricción activa",
            exercises: [ProposedExercise(name: "Movilidad sin dolor", prescription: "10–15 min · rango cómodo", cue: "Detente si aparece dolor o aumenta la molestia")],
            note: reason + " La alternativa no sustituye la valoración de un profesional sanitario.",
            // Recuperación de verdad, no la sesión que se ha bloqueado: la UI
            // pregunta por `kind` para decidir si ofrecer iniciarla como
            // sesión de fuerza, y conservar el kind original haría que
            // ofreciera empezar una sesión que acabamos de retirar.
            kind: .recovery
        )
    }

    private static func blocked(_ exercise: String, injury: InjuryRecord, restriction: String) -> InjurySafetyResult {
        InjurySafetyResult(allowed: false, reason: "\(exercise) bloqueado por \(restriction): \(injury.area).")
    }

    private static func lowerBodyArea(_ area: String) -> Bool {
        contains(area, any: ["rodilla", "tobillo", "pie", "cadera", "ingle", "cuadr", "isqu", "gemelo", "glúte", "glute", "aquiles"])
    }

    private static func specificAreaConflict(_ area: String, exercise: String, muscles: Set<String>) -> Bool {
        let value = normalized(area)
        let name = normalized(exercise)
        if contains(value, any: ["rodilla", "rotula", "rótula"]) {
            return muscles.contains("Cuádriceps") || contains(name, any: ["squat", "sentadilla", "lunge", "zancada", "leg press", "prensa", "leg extension"])
        }
        if contains(value, any: ["hombro", "manguito"]) {
            return muscles.contains("Hombros") || contains(name, any: ["press", "dip", "fondos", "lateral raise", "elevacion"])
        }
        if contains(value, any: ["codo", "muñeca", "muneca"]) {
            return upperLimbExercise(name)
        }
        if contains(value, any: ["lumbar", "espalda baja"]) {
            return contains(name, any: ["deadlift", "peso muerto", "bent over", "remo inclinado", "squat", "sentadilla", "swing"])
        }
        if contains(value, any: ["isqu", "femoral"]) { return muscles.contains("Isquios") }
        if contains(value, any: ["gemelo", "aquiles", "tobillo", "pie"]) { return muscles.contains("Gemelos") }
        return false
    }

    private static func upperLimbExercise(_ exercise: String) -> Bool {
        contains(exercise, any: ["press", "push", "pull", "row", "remo", "curl", "extension", "extensión", "dip", "fondos", "raise", "elevacion", "elevación"])
    }

    private static func contains(_ value: String, any terms: [String]) -> Bool {
        let normalizedValue = normalized(value)
        return terms.contains { normalizedValue.contains(normalized($0)) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
