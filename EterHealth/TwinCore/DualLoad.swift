import Foundation

// PR3: una sola carga EWMA mezclaba sentadilla y tirada larga, así que no
// había forma de modelar interferencia concurrente — ni de responder a
// "¿esta sobrecarga es de fuerza o de fondo?". Dos canales con sus propias
// constantes de tiempo, y el número combinado de siempre pasa a ser una
// LECTURA derivada de los dos, no una tercera fuente que pueda divergir.
struct DualLoad: Equatable {
    var aerobic: Double
    var strength: Double
    static let none = DualLoad(aerobic: 0, strength: 0)
    // El combinado es exactamente la suma porque el EWMA es lineal: el
    // ewmaWeeklyEquivalent de (aeróbico + fuerza) día a día y la suma de los
    // dos EWMA por separado son el mismo número. Por eso partir el canal no
    // mueve ni un decimal de lo que ya se mostraba (hay un test que lo fija).
    var combined: Double { aerobic + strength }
}

// Un día de historial con los dos canales separados en el origen, en vez de
// sumados al entrar. `load` combinado se conserva para DailyTraining y para
// el ratio de siempre.
struct DailyDualTraining: Equatable {
    let date: Date
    let sessions: Int
    let aerobic: Double
    let strength: Double
    var load: Double { aerobic + strength }
}

struct DualLoadSummary: Equatable {
    var acuteAerobic: Double      // τ = 7
    var habitualAerobic: Double   // τ = 28
    var acuteStrength: Double
    var habitualStrength: Double
    var observedDays: Int
    // Por canal, no el combinado: una racha sostenida de fuerza no debe
    // contar como semanas sostenidas de fondo, que es justo lo que hacía
    // que loadGuidance leyera "sobrecarga" con la evidencia del otro canal.
    var sustainedAerobicWeeks: Int
    var sustainedStrengthWeeks: Int

    static let none = DualLoadSummary(acuteAerobic: 0, habitualAerobic: 0, acuteStrength: 0, habitualStrength: 0,
                                      observedDays: 0, sustainedAerobicWeeks: 0, sustainedStrengthWeeks: 0)

    var aerobicRatio: Double { habitualAerobic > 0 ? acuteAerobic / habitualAerobic : 0 }
    var strengthRatio: Double { habitualStrength > 0 ? acuteStrength / habitualStrength : 0 }

    var aerobicGuidance: LoadGuidance {
        PerformanceEngine.loadGuidance(ratio: aerobicRatio, sustainedWeeks: sustainedAerobicWeeks, observedDays: observedDays)
    }
    var strengthGuidance: LoadGuidance {
        PerformanceEngine.loadGuidance(ratio: strengthRatio, sustainedWeeks: sustainedStrengthWeeks, observedDays: observedDays)
    }

    // Regla explícita, no un promedio mudo: manda el canal que pide más
    // cautela. Promediar los dos ratios es exactamente el error que el
    // canal único ya cometía — una semana dura de fuerza y un fondo suave
    // se cancelaban y salía "productiva" cuando la fuerza estaba en
    // sobrecarga. `learning` (sin datos suficientes) es el rango más bajo
    // a propósito: no tener evidencia en un canal no puede tapar lo que el
    // otro sí mide.
    var guidance: LoadGuidance {
        aerobicGuidance.cautionRank >= strengthGuidance.cautionRank ? aerobicGuidance : strengthGuidance
    }

    // Mismo paso de un día que projectedAcuteLoad/projectedLoadRatio ya
    // usaban, aplicado por canal en vez de a la mezcla.
    func projectedAcute(adding session: DualLoad) -> DualLoad {
        DualLoad(aerobic: acuteAerobic + session.aerobic * (1 - exp(-1 / 7.0)) * 7,
                 strength: acuteStrength + session.strength * (1 - exp(-1 / 7.0)) * 7)
    }

    func projectedRatios(adding session: DualLoad) -> (aerobic: Double, strength: Double) {
        let projected = projectedAcute(adding: session)
        let chronicAerobic = habitualAerobic + session.aerobic * (1 - exp(-1 / 28.0)) * 7
        let chronicStrength = habitualStrength + session.strength * (1 - exp(-1 / 28.0)) * 7
        return (chronicAerobic > 0 ? projected.aerobic / chronicAerobic : 0,
                chronicStrength > 0 ? projected.strength / chronicStrength : 0)
    }
}

extension LoadGuidance {
    // Orden de cautela, no de severidad clínica: es lo único que necesita la
    // regla "manda el peor de los dos canales" de DualLoadSummary.guidance.
    var cautionRank: Int {
        switch self {
        case .learning: return 0
        case .low: return 1
        case .productive: return 2
        case .absorb: return 3
        case .deload: return 4
        case .overload: return 5
        }
    }
}

extension PerformanceEngine {
    // La ÚNICA separación aeróbico/fuerza del repo. TwinPhysiology.derive
    // tenía su propia copia de este bucle (mismo filtro de Hevy-espejado,
    // mismo isStrengthWorkout, mismas unidades) y ahora la consume desde
    // aquí: dos copias de "qué cuenta como fuerza" era precisamente lo que
    // el brief prohíbe.
    @MainActor static func dailyDualHistory(health: HealthStore, imports: ImportStore,
                                            days: Int = 84, now: Date = Date()) -> [DailyDualTraining] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        var sessions: [Date: Int] = [:]
        var aerobic: [Date: Double] = [:]
        var strength: [Date: Double] = [:]

        // Hevy es fuerza por definición: son series, no minutos.
        for workout in imports.workouts where workout.start >= start && workout.start <= now {
            let day = calendar.startOfDay(for: workout.start)
            sessions[day, default: 0] += 1
            strength[day, default: 0] += Double(workout.exercises.reduce(0) { $0 + $1.sets }) * 3
        }
        for workout in health.recentWorkouts where workout.date >= start && workout.date <= now &&
            !workout.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror(workout) {
            let day = calendar.startOfDay(for: workout.date)
            sessions[day, default: 0] += 1
            let load = workout.durationMinutes * cardioFactor(workout.activity)
            // cardioFactor se queda tal cual y no se mezclan unidades entre
            // canales: una sesión de fuerza registrada en HealthKit (sin
            // series que contar) sigue valorándose por minutos, pero cae en
            // el canal de fuerza, no en el aeróbico.
            if TrainingPlanEngine.isStrengthWorkout(workout) { strength[day, default: 0] += load }
            else { aerobic[day, default: 0] += load }
        }

        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -(days - 1) + offset, to: today) else { return nil }
            return DailyDualTraining(date: date, sessions: sessions[date] ?? 0,
                                     aerobic: aerobic[date] ?? 0, strength: strength[date] ?? 0)
        }
    }

    @MainActor static func dualSummary(history: [DailyDualTraining]) -> DualLoadSummary {
        let aerobicLoads = history.map(\.aerobic)
        let strengthLoads = history.map(\.strength)
        let habitualAerobic = ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 28)
        let habitualStrength = ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 28)
        return DualLoadSummary(
            acuteAerobic: ewmaWeeklyEquivalent(loads: aerobicLoads, timeConstant: 7),
            habitualAerobic: habitualAerobic,
            acuteStrength: ewmaWeeklyEquivalent(loads: strengthLoads, timeConstant: 7),
            habitualStrength: habitualStrength,
            observedDays: history.filter { $0.sessions > 0 }.count,
            sustainedAerobicWeeks: sustainedWeeks(loads: aerobicLoads, habitualWeekly: habitualAerobic),
            sustainedStrengthWeeks: sustainedWeeks(loads: strengthLoads, habitualWeekly: habitualStrength)
        )
    }

    // Extraído tal cual de summarize (mismas 4 semanas rodantes, mismo 0.85)
    // para poder aplicarlo por canal sin una segunda definición.
    nonisolated static func sustainedWeeks(loads: [Double], habitualWeekly: Double) -> Int {
        guard habitualWeekly > 0 else { return 0 }
        let rolling = stride(from: max(0, loads.count - 28), to: loads.count, by: 7).map { start in
            loads[start..<min(start + 7, loads.count)].reduce(0, +)
        }
        return rolling.suffix(3).filter { $0 >= habitualWeekly * 0.85 }.count
    }
}
