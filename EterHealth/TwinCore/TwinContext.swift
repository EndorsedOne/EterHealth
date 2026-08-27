import Foundation

// PR1.5: TwinEngine.assess, TrainingPlanEngine.status/weekAhead and
// PerformanceEngine.balance all used to take the same six values
// (profile/events/reviews/activeInjuries/calibration/personalAnchor) as
// six separate parameters after PR1's injection — every UI call site had
// to repeat the same six labels for whichever of these four it happened
// to call. Bundling them into one value type means a call site builds
// ONE TwinContext from the real stores and reuses it for all four, and a
// function that doesn't need every field (status only reads profile and
// reviews) just ignores the rest instead of not being able to see them.
// Still a plain struct with zero singleton access — TwinCore itself never
// constructs one, only receives it, exactly like the six separate
// parameters it replaces.
struct TwinContext {
    var profile: AthletePlanProfile
    var events: [LifestyleEvent]
    var reviews: [WorkoutReview]
    var activeInjuries: [InjuryRecord]
    var calibration: TwinCalibration
    var personalAnchor: PersonalReadinessAnchor
    // PR15: el episodio de viaje activo, si hay uno. Va aquí por la misma
    // razón que los otros seis: es un dato que el gemelo necesita, que vive en
    // un store fuera de TwinCore, y que TODAS las funciones del pipeline
    // (assess, status, weekAhead, propose) tienen que ver para no discrepar.
    // Con default nil, así que los call sites que no lo tienen siguen
    // compilando — pero ojo: DecisionSimulatorEngine.simulate construye su
    // propio TwinContext desde seis parámetros sueltos, así que ESE sí ha
    // tenido que recibirlo explícitamente o el simulador diría que un HIIT
    // sale gratis mientras el plan lo limita.
    var travel: TravelEpisode? = nil
    // PR16: TODOS los episodios, para aprender. Es un campo distinto de
    // `travel` a propósito y no una lista de la que derivar el activo: cuál es
    // "el viaje actual" lo decide TravelEpisodeStore.currentEpisode, en un
    // solo sitio, y duplicar esa resolución dentro de TwinCore es exactamente
    // cómo la tarjeta y el plan acabarían eligiendo episodios distintos.
    //
    // Vacío por default: sin historial, TravelLearningEngine devuelve el prior
    // y el comportamiento es el de PR15 sin cambiar nada.
    var travelHistory: [TravelEpisode] = []
}
