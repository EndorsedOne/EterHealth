import Foundation

// PR6. MuscleVolumeLandmarkTable se queda como PRIORS. Esto estima el MRV
// real por músculo cuando hay historial suficiente, y se calla cuando no.
//
// El brief daba dos criterios para el MRV, en OR:
//  1. el volumen semanal por encima del cual el e1RM se estanca o baja
//  2. el volumen por encima del cual el soreness/readiness de ese músculo
//     no recupera en 72 h
// Aquí sólo está implementado el (1). El (2) no tiene datos: la readiness
// por músculo se calcula en vivo (TwinEngine.calculateMuscles) y NO se
// persiste como serie temporal en ningún sitio, así que no hay historial que
// mirar. Preferimos dejarlo escrito antes que aproximarlo con otra cosa y
// presentarlo como si fuera ese criterio.
// PR9: los dos ajustes personales que salen de datos reales de
// entrenamiento, juntos porque viajan juntos a TODOS los sitios que
// preguntan por un landmark (volumeUrgency, bestStrengthPattern,
// strengthPattern, balancedDecision, la simulación de weekAhead). Antes
// esas seis firmas arrastraban un `learnedLandmarks: [String:
// LearnedVolumeLandmark]`; añadir el volumen sostenido como SÉPTIMO
// parámetro suelto en cada una es justo el patrón que TwinContext ya
// resolvió agrupando. Mismo criterio, mismo tipo de valor: struct plano,
// cero acceso a stores, construido fuera y sólo recibido dentro.
//
// No se fusionan en un solo diccionario porque son dos claims distintos con
// dos barras de evidencia distintas: el MRV aprendido exige 8 semanas con
// volumen, 5 juzgables, 3 de cada clase Y una frontera real; el volumen
// sostenido sólo exige unas semanas de historial, porque lo único que
// afirma es "esto es lo que este atleta hace de verdad". Meterlos en la
// misma estructura poblada a la vez ataría el empujón del prior a que el
// aprendizaje del MRV haya convergido, y entonces nunca serviría de nada.
struct VolumeLandmarkContext: Equatable {
    var learnedMRV: [String: LearnedVolumeLandmark] = [:]
    var sustainedWeeklySets: [String: Double] = [:]
    static let none = VolumeLandmarkContext()
}

struct LearnedVolumeLandmark: Equatable {
    let muscle: String
    let mrv: Double
    let weeksObserved: Int
    let stalledWeeks: Int
    let progressedWeeks: Int
}

enum VolumeLandmarkLearning {
    // Mismos mínimos de evidencia que learnedRecovery: 8 semanas con volumen
    // real y al menos 5 semanas juzgables. Y además 3 de cada clase, porque
    // un MRV es una FRONTERA: con sólo semanas que progresan, o sólo semanas
    // que se estancan, no hay frontera que estimar, hay una sola muestra.
    static let minimumWeeksWithVolume = 8
    static let minimumJudgeableWeeks = 5
    static let minimumWeeksPerClass = 3
    // Un e1RM que se mantiene cuenta como progreso: mantener carga con el
    // mismo volumen no es estancarse. Mismo 0.98 que learnedRecovery usa
    // para decidir si un hueco de recuperación fue suficiente.
    static let maintainedRatio = 0.98
    // El aprendizaje no puede alejarse arbitrariamente del prior: con pocas
    // semanas, ruido en una sola puede mover la mediana. Estos topes son
    // deliberadamente amplios (el aprendizaje manda de verdad) pero impiden
    // un número absurdo.
    static let minimumPriorMultiple = 0.6
    static let maximumPriorMultiple = 2.0

    private static let muscles = ["Cuádriceps", "Glúteos", "Isquios", "Pecho", "Espalda",
                                  "Hombros", "Bíceps", "Tríceps", "Core", "Gemelos"]

    static func learnedMRV(workouts: [ImportedWorkout], now: Date = Date(),
                           weeks lookbackWeeks: Int = 26) -> [String: LearnedVolumeLandmark] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        guard let start = calendar.date(byAdding: .weekOfYear, value: -lookbackWeeks, to: now) else { return [:] }
        let recent = workouts.filter { $0.start >= start && $0.start <= now }.sorted { $0.start < $1.start }

        // Volumen semanal por músculo, desde effectiveMuscleSets — la fuente
        // canónica, nunca el muscleSets guardado.
        var weeklyVolume: [String: [Date: Double]] = [:]
        // Mejor e1RM por músculo y semana, para juzgar si esa semana progresó.
        var weeklyBest: [String: [Date: Double]] = [:]
        for workout in recent {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: workout.start)?.start else { continue }
            for (muscle, sets) in workout.effectiveMuscleSets where sets > 0 && muscles.contains(muscle) {
                weeklyVolume[muscle, default: [:]][week, default: 0] += sets
            }
            for exercise in workout.exercises {
                guard let best = estimatedOneRepMax(exercise), best > 0 else { continue }
                for muscle in MuscleMap.groups(for: exercise.name) where muscles.contains(muscle) {
                    let current = weeklyBest[muscle, default: [:]][week] ?? 0
                    weeklyBest[muscle, default: [:]][week] = max(current, best)
                }
            }
        }

        var result: [String: LearnedVolumeLandmark] = [:]
        for muscle in muscles {
            let volumes = weeklyVolume[muscle] ?? [:]
            guard volumes.count >= minimumWeeksWithVolume else { continue }
            let bests = weeklyBest[muscle] ?? [:]
            let orderedWeeks = volumes.keys.sorted()

            // Una semana "progresó" si su mejor e1RM iguala o supera el mejor
            // de TODAS las semanas anteriores. Comparar contra el récord
            // previo y no contra la semana anterior evita leer como progreso
            // un rebote tras una semana mala.
            var runningBest = 0.0
            var progressed: [Double] = []
            var stalled: [Double] = []
            for week in orderedWeeks {
                guard let volume = volumes[week] else { continue }
                guard let best = bests[week], best > 0 else { continue }
                if runningBest > 0 {
                    if best / runningBest >= maintainedRatio { progressed.append(volume) } else { stalled.append(volume) }
                }
                runningBest = max(runningBest, best)
            }
            guard progressed.count + stalled.count >= minimumJudgeableWeeks,
                  progressed.count >= minimumWeeksPerClass, stalled.count >= minimumWeeksPerClass else { continue }

            // La frontera sólo existe si las semanas que se estancaron
            // llevaban MÁS volumen que las que progresaron. Si no, el volumen
            // no es lo que separa una cosa de la otra en este músculo — y
            // entonces no se afirma nada, que es el punto de todo esto.
            guard let stalledCenter = median(stalled), let progressedCeiling = percentile(progressed, 0.75),
                  stalledCenter > progressedCeiling else { continue }

            // El prior PURO de tabla, no el MAV ya ajustado por tolerancia:
            // acotar contra el ajustado dejaría que el empujón del prior y
            // el MRV aprendido se amplificaran mutuamente (más volumen
            // sostenido → MAV más alto → tope del MRV aprendido más alto →
            // más volumen tolerado), que es el bucle que un tope existe
            // para impedir. Ver MuscleVolumeLandmarkTable.priorMAV.
            let prior = (MuscleVolumeLandmarkTable.priorMAV(for: muscle) * 1.5).rounded()
            let estimate = (progressedCeiling + stalledCenter) / 2
            let bounded = min(prior * maximumPriorMultiple, max(prior * minimumPriorMultiple, estimate))
            result[muscle] = LearnedVolumeLandmark(muscle: muscle, mrv: bounded, weeksObserved: volumes.count,
                                                   stalledWeeks: stalled.count, progressedWeeks: progressed.count)
        }
        return result
    }

    // Semanas mínimas con volumen real para afirmar "esto es lo que este
    // atleta sostiene". Más bajo que minimumWeeksWithVolume (8) a propósito,
    // y no por descuido: el claim es mucho más pequeño. El MRV aprendido
    // afirma dónde está una FRONTERA fisiológica y sustituye el prior; esto
    // sólo afirma cuánto volumen hay de verdad en el historial y mueve el
    // prior un ±25% como máximo. Exigirle las mismas 8 semanas que al MRV
    // significaría que nunca aporta nada antes de que el aprendizaje del
    // MRV ya haya convergido, y entonces sobra.
    static let minimumWeeksForTolerance = 6

    /// El volumen semanal que este atleta SOSTIENE en cada músculo: la
    /// mediana de las semanas con volumen real, no la media (una semana de
    /// descarga o una de pico no deben mover el número) ni el máximo (que
    /// mediría su mejor semana, no su costumbre). Ventana más corta que la
    /// del MRV aprendido —12 semanas frente a 26— porque lo que se busca es
    /// el hábito ACTUAL: un bloque de hipertrofia de hace cinco meses no
    /// dice cuánto volumen tolera hoy.
    ///
    /// Sólo devuelve entrada para los músculos con evidencia suficiente. Un
    /// músculo ausente significa "sin datos", que es distinto de "cero", y
    /// hace que el prior se use tal cual.
    static func sustainedWeeklySets(workouts: [ImportedWorkout], now: Date = Date(),
                                    weeks lookbackWeeks: Int = 12) -> [String: Double] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        guard let start = calendar.date(byAdding: .weekOfYear, value: -lookbackWeeks, to: now) else { return [:] }
        var weeklyVolume: [String: [Date: Double]] = [:]
        for workout in workouts where workout.start >= start && workout.start <= now {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: workout.start)?.start else { continue }
            // effectiveMuscleSets, la fuente canónica — nunca el muscleSets
            // guardado, por la misma razón que el resto del archivo.
            for (muscle, sets) in workout.effectiveMuscleSets where sets > 0 && muscles.contains(muscle) {
                weeklyVolume[muscle, default: [:]][week, default: 0] += sets
            }
        }
        var result: [String: Double] = [:]
        for (muscle, weeks) in weeklyVolume where weeks.count >= minimumWeeksForTolerance {
            if let value = median(Array(weeks.values)) { result[muscle] = value }
        }
        return result
    }

    /// Los dos ajustes de una vez, que es como los consume el plan. Se
    /// calcula UNA vez por llamada a status()/weekAhead y se reparte, igual
    /// que el clasificador de calidad del PR4 y que el MRV aprendido del PR6
    /// — no cada consumidor por su cuenta.
    static func context(workouts: [ImportedWorkout], now: Date = Date()) -> VolumeLandmarkContext {
        VolumeLandmarkContext(learnedMRV: learnedMRV(workouts: workouts, now: now),
                              sustainedWeeklySets: sustainedWeeklySets(workouts: workouts, now: now))
    }

    // Mismo estimador de e1RM que PersonalBaselineEngine.learnedRecovery ya
    // usa (Epley), para que "progresar" signifique lo mismo en los dos sitios.
    private static func estimatedOneRepMax(_ exercise: ImportedExercise) -> Double? {
        let sets = exercise.setDetails ?? []
        let estimates = sets.filter { $0.weight > 0 && $0.reps > 0 && $0.reps <= 15 }
            .map { $0.weight * (1 + Double($0.reps) / 30) }
        return estimates.max()
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
