import Foundation

struct InjurySafetyResult {
    let allowed: Bool
    let reason: String?
}

enum InjurySafetyEngine {
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
        let isRunning = workout.title.localizedCaseInsensitiveContains("carrera") ||
            workout.title.localizedCaseInsensitiveContains("tirada") ||
            workout.title.localizedCaseInsensitiveContains("brick") ||
            workout.exercises.contains { $0.name.localizedCaseInsensitiveContains("carrera") }
        if isRunning, let reason = sessionAllowsRunning(injuries).reason {
            return recoveryAlternative(reason: reason)
        }
        // Swimming is upper-body/shoulder dominant and cycling is a
        // sustained lower-body/hip-knee load — neither maps onto the
        // exercise-by-exercise strength filter below (their "exercises" are
        // set descriptions, not named lifts MuscleMap recognizes), so each
        // gets the same restriction-based block sessionAllowsRunning gives
        // running, checked directly against the workout's own title.
        if workout.title.localizedCaseInsensitiveContains("natación"),
           let injury = injuries.first(where: { $0.restrictions.contains(.avoidUpperBody) }) {
            return recoveryAlternative(reason: "Natación bloqueada por la restricción activa en \(injury.area).")
        }
        if (workout.title.localizedCaseInsensitiveContains("ciclismo") || workout.title.localizedCaseInsensitiveContains("brick")),
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
            note: "\(workout.note) · Éter ha retirado \(removed) ejercicio\(removed == 1 ? "" : "s") incompatible\(removed == 1 ? "" : "s") con tus restricciones activas."
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
            note: reason + " La alternativa no sustituye la valoración de un profesional sanitario."
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
