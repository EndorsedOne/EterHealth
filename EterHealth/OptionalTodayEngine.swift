import Foundation

/// Un ejercicio concreto de una sesión opcional (movilidad, core, cardio, HIIT).
struct OptionalExercise: Identifiable {
    var id: String { name }
    let name: String
    /// Series/reps/tiempo — la pauta concreta.
    let detail: String
}

/// La sesión opcional que el gemelo propone para HOY si el usuario tiene ganas
/// y cuerpo. No es obligatoria: es "lo óptimo ahora" dado tu estado de
/// recuperación, de bajo compromiso y sin pisar lo que necesita recuperar.
struct OptionalSession {
    enum Kind { case mobilityCore, easyCardio, hiit, freshStrength }
    let kind: Kind
    let title: String
    let rationale: String
    /// Qué evitar hoy (p. ej. cargar pierna con agujetas). nil si no aplica.
    let avoid: String?
    let duration: String
    let exercises: [OptionalExercise]
    /// Presente solo en freshStrength: el patrón fresco a entrenar (para poder
    /// arrancar la sesión de fuerza real).
    let strengthPattern: StrengthPattern?
}

@MainActor
enum OptionalTodayEngine {
    /// Recomienda la mejor sesión opcional para hoy según la recuperación
    /// actual. El gemelo decide UNA; prioriza no cargar lo que está fatigado.
    static func recommend(assessment: TwinAssessment) -> OptionalSession {
        let muscles = assessment.muscles
        func readiness(of names: [String]) -> Double {
            let values = names.compactMap { name in muscles.first { $0.name == name }?.readiness }
            return values.isEmpty ? 60 : Double(values.reduce(0, +)) / Double(values.count)
        }
        let legReadiness = readiness(of: ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"])
        let upperReadiness = readiness(of: ["Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps"])
        let overall = Double(assessment.score)
        let legsFatigued = legReadiness < 58
        let upperFatigued = upperReadiness < 62

        // 1) Todo cargado (tu caso tras Push/Pull/Pierna seguidos, con agujetas):
        //    lo óptimo es movilidad + core / recuperación activa. Baja fatiga,
        //    ayuda a recuperar y no pisa nada.
        if (legsFatigued && upperFatigued) || overall < 55 {
            return mobilityCore(legsFatigued: legsFatigued)
        }

        // 2) Piernas frescas y readiness alta: si hay ganas de intensidad, HIIT
        //    de bajo impacto para pierna (bici/remo) es una opción válida.
        if !legsFatigued && legReadiness >= 65 && overall >= 68 {
            return hiit()
        }

        // 3) Piernas razonables pero sin readiness para intensidad: cardio suave
        //    Z2, que suma volumen aeróbico sin fatiga apreciable.
        if legReadiness >= 60 {
            return easyCardio()
        }

        // 4) Por defecto (piernas cargadas pero tren superior ok, u otros):
        //    movilidad + core sigue siendo lo más seguro y útil.
        return mobilityCore(legsFatigued: legsFatigued)
    }

    private static func mobilityCore(legsFatigued: Bool) -> OptionalSession {
        OptionalSession(
            kind: .mobilityCore,
            title: "Movilidad + core",
            rationale: "Hoy no hay nada obligatorio y los grupos grandes están cargados. Lo óptimo si quieres moverte es movilidad y core: baja fatiga, mejora la recuperación y no interfiere con lo que ya has entrenado.",
            avoid: legsFatigued ? "Carga de pierna y esfuerzo máximo — las piernas están con agujetas." : "Cargas altas y fallo muscular.",
            duration: "25–35 min",
            exercises: [
                OptionalExercise(name: "90/90 de cadera", detail: "2 × 8/lado, controlado"),
                OptionalExercise(name: "Rotación torácica (cuadrupedia)", detail: "2 × 8/lado"),
                OptionalExercise(name: "Dislocaciones de hombro con banda", detail: "2 × 12"),
                OptionalExercise(name: "Rodilla a pared (tobillo)", detail: "2 × 10/lado"),
                OptionalExercise(name: "Dead bug", detail: "3 × 8/lado"),
                OptionalExercise(name: "Plancha", detail: "3 × 40 s"),
                OptionalExercise(name: "Pallof press", detail: "3 × 10/lado")
            ],
            strengthPattern: nil
        )
    }

    private static func easyCardio() -> OptionalSession {
        OptionalSession(
            kind: .easyCardio,
            title: "Cardio suave (Z2)",
            rationale: "Las piernas aguantan volumen suave y no toca fuerza. Un rodaje fácil suma base aeróbica sin apenas fatiga y ayuda a recuperar.",
            avoid: "Nada de series ni sprints; mantén el pulso bajo (deberías poder hablar).",
            duration: "30–40 min",
            exercises: [
                OptionalExercise(name: "Cardio continuo Z2", detail: "30–40 min a ritmo conversacional (correr, bici o elíptica)"),
                OptionalExercise(name: "Movilidad final", detail: "5 min de estiramientos suaves")
            ],
            strengthPattern: nil
        )
    }

    private static func hiit() -> OptionalSession {
        OptionalSession(
            kind: .hiit,
            title: "HIIT de bajo impacto",
            rationale: "Piernas frescas y buena disponibilidad: si te apetece intensidad, un HIIT corto en bici o remo da mucho estímulo cardiovascular con poco impacto articular.",
            avoid: "Elígelo solo con las piernas frescas; si hay agujetas, mejor movilidad.",
            duration: "20–25 min",
            exercises: [
                OptionalExercise(name: "Calentamiento progresivo", detail: "8–10 min subiendo pulso"),
                OptionalExercise(name: "Intervalos (bici o remo)", detail: "8 × (20 s fuerte / 40 s suave)"),
                OptionalExercise(name: "Vuelta a la calma", detail: "5 min muy suave")
            ],
            strengthPattern: nil
        )
    }
}
