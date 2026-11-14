import Foundation

/// Modelo de la curva de energía del día ("tu batería", estilo Bevel) y de los
/// eventos que la mueven. Extraído de WidgetSnapshotStore para que la app y el
/// widget dibujen EXACTAMENTE la misma curva a partir de la misma lógica, en
/// vez de mantener dos modelos que se desincronizan (justo el error que el
/// comentario de PR15 dentro de energyModel documenta haber sufrido ya con la
/// penalización de viaje). El widget la serializa en el snapshot; la app la
/// calcula en vivo. Ambos comparten esta fuente.
enum EnergyTimelineEngine {
    struct Result {
        let energy: Int
        let curve: [Double]
        let basis: String
        let events: [EterWidgetEnergyEvent]
        let inputMarkers: [EterWidgetInputMarker]
        let currentHour: Double
        let sleepStartHour: Double?
        let sleepEndHour: Double?
        let hrv: DailyMetricContext
        let restingHeartRate: DailyMetricContext
        let caffeine: CaffeineTimelineResult
        let restWindows: [RestorativeWindow]
        let autonomicStrainWindows: [AutonomicStrainWindow]
        let heartRatePoints: [HeartRatePoint]
        let calorieBins: [CalorieBin]
        let calorieSource: String
    }

    struct HeartRatePoint: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let hour: Double
        let bpm: Double
        /// Un tramo nuevo comienza cuando HealthKit deja un hueco largo. Así
        /// la gráfica no inventa una diagonal entre dos lecturas aisladas.
        let segment: Int
    }

    struct CalorieBin: Identifiable, Equatable {
        var id: Double { startHour }
        let startHour: Double
        let active: Double
        let basal: Double
        let cumulativeActive: Double
        let cumulativeTotal: Double
    }

    /// Compatibilidad del helper probado que agrupa sólo energía activa. La
    /// tarjeta nueva consume `CalorieBin`, pero otros consumidores todavía
    /// pueden necesitar distinguir actividad dentro/fuera de entrenamientos.
    struct ActiveEnergyBin: Identifiable, Equatable {
        var id: Double { startHour }
        let startHour: Double
        let calories: Double
        let duringWorkout: Bool
    }

    struct DailyMetricContext {
        let value: Double?
        let expected: Double?
    }

    /// Punto de entrada para la app: calcula curva, eventos y marcadores de
    /// input en una sola pasada. El widget usa las piezas por separado desde
    /// WidgetSnapshotStore (necesita también confianza y carga), así que las
    /// funciones de abajo quedan accesibles individualmente.
    @MainActor
    static func build(assessment: TwinAssessment, health: HealthStore, imports: ImportStore,
                      checkIn: DailyCheckIn?, lifestyle: [LifestyleEvent], travel: TravelEpisode? = nil,
                      basalMetabolicRateKcal: Double? = nil,
                      now: Date = Date()) -> Result {
        let currentHour = hour(of: now, on: now)
        let sleepStart = health.sleepStages.startDate.map { max(0, hour(of: $0, on: now)) }
        let sleepEnd = health.sleepStages.endDate.map { min(currentHour, hour(of: $0, on: now)) }
        let events = energyEvents(health: health, imports: imports, now: now)
        let baseline = PersonalBaselineEngine.profile(health: health, imports: imports, now: now)
        let model = energyModel(
            assessment: assessment, health: health, baseline: baseline, checkIn: checkIn,
            lifestyle: lifestyle, now: now, currentHour: currentHour,
            sleepStartHour: sleepStart, sleepEndHour: sleepEnd, events: events
        )
        let caffeine = caffeineTimeline(
            lifestyle: lifestyle, sleepSchedule: health.sleepScheduleHistory,
            now: now, currentHour: currentHour
        )
        let calories = calorieTimeline(
            activeSamples: health.todayActiveEnergySamples,
            basalSamples: health.todayBasalEnergySamples,
            fallbackDailyBasal: basalMetabolicRateKcal,
            day: now, through: currentHour
        )
        return Result(
            energy: model.energy, curve: model.curve, basis: model.basis, events: events,
            inputMarkers: inputMarkers(
                from: lifestyle, checkIn: checkIn, travel: travel,
                sleepHours: health.snapshot.sleepHours, sleepEndHour: sleepEnd, now: now
            ),
            currentHour: currentHour, sleepStartHour: sleepStart, sleepEndHour: sleepEnd,
            hrv: DailyMetricContext(value: baseline.hrv.current, expected: baseline.hrv.expected),
            restingHeartRate: DailyMetricContext(
                value: baseline.restingHeartRate.current, expected: baseline.restingHeartRate.expected
            ), caffeine: caffeine, restWindows: model.restWindows,
            autonomicStrainWindows: model.autonomicStrainWindows,
            heartRatePoints: heartRatePoints(samples: health.todayHeartRateSamples, day: now, through: currentHour),
            calorieBins: calories.bins, calorieSource: calories.source
        )
    }

    static func heartRatePoints(samples: [TrendPoint], day: Date, through currentHour: Double) -> [HeartRatePoint] {
        let valid = samples.filter {
            Calendar.current.isDate($0.date, inSameDayAs: day)
                && hour(of: $0.date, on: day) <= currentHour + 0.001
                && $0.value >= 30 && $0.value <= 240
        }.sorted { $0.date < $1.date }
        var segment = 0
        var previousDate: Date?
        return valid.map { sample in
            // El Watch suele entregar pulso cada pocos minutos. Un hueco de
            // más de 30 min es ausencia de señal, no una transición lineal.
            if let previousDate, sample.date.timeIntervalSince(previousDate) > 30 * 60 { segment += 1 }
            previousDate = sample.date
            return HeartRatePoint(date: sample.date, hour: hour(of: sample.date, on: day),
                                  bpm: sample.value, segment: segment)
        }
    }

    /// Tendencia visual, no dato clínico nuevo. Mantiene la hora y los cortes
    /// reales de HealthKit y aplica una media triangular de hasta cinco
    /// lecturas dentro de cada tramo. Un pico sigue siendo visible, pero una
    /// sucesión ruidosa deja de parecer una señal de ECG.
    nonisolated static func smoothedHeartRatePoints(_ points: [HeartRatePoint], radius: Int = 2) -> [HeartRatePoint] {
        let ordered = points.sorted { $0.date < $1.date }
        guard radius > 0, ordered.count >= 3 else { return ordered }
        return ordered.indices.map { index in
            let point = ordered[index]
            let lower = max(0, index - radius)
            let upper = min(ordered.count - 1, index + radius)
            var weighted = 0.0
            var weights = 0.0
            for neighbor in lower...upper where ordered[neighbor].segment == point.segment {
                let weight = Double(radius + 1 - abs(neighbor - index))
                weighted += ordered[neighbor].bpm * weight
                weights += weight
            }
            return HeartRatePoint(
                date: point.date, hour: point.hour,
                bpm: weights > 0 ? weighted / weights : point.bpm,
                segment: point.segment
            )
        }
    }

    struct CalorieTimelineResult {
        let bins: [CalorieBin]
        let source: String
    }

    /// Barras acumuladas de gasto real. Apple Salud gana siempre que entregue
    /// energía basal intradía; el BMR de InBody sólo completa la base cuando
    /// Apple no la proporciona, distribuyéndolo uniformemente y declarándolo.
    static func calorieTimeline(activeSamples: [TrendPoint], basalSamples: [TrendPoint],
                                fallbackDailyBasal: Double?, day: Date,
                                through currentHour: Double) -> CalorieTimelineResult {
        var activeByBin: [Int: Double] = [:]
        var basalByBin: [Int: Double] = [:]
        func collect(_ samples: [TrendPoint], into target: inout [Int: Double]) {
            for sample in samples where Calendar.current.isDate(sample.date, inSameDayAs: day) && sample.value > 0 {
                let sampleHour = hour(of: sample.date, on: day)
                guard sampleHour <= currentHour + 0.001 else { continue }
                target[max(0, min(47, Int(floor(sampleHour * 2)))), default: 0] += sample.value
            }
        }
        collect(activeSamples, into: &activeByBin)
        collect(basalSamples, into: &basalByBin)

        let usesAppleBasal = !basalByBin.isEmpty
        if !usesAppleBasal, let daily = fallbackDailyBasal, daily > 0 {
            let completedBins = max(1, min(48, Int(ceil(currentHour * 2))))
            for index in 0..<completedBins { basalByBin[index] = daily / 48 }
        }
        let indices = Set(activeByBin.keys).union(basalByBin.keys).sorted()
        var cumulativeActive = 0.0
        var cumulativeTotal = 0.0
        let bins = indices.map { index -> CalorieBin in
            let active = activeByBin[index, default: 0]
            let basal = basalByBin[index, default: 0]
            cumulativeActive += active
            cumulativeTotal += active + basal
            return CalorieBin(startHour: Double(index) / 2, active: active, basal: basal,
                              cumulativeActive: cumulativeActive, cumulativeTotal: cumulativeTotal)
        }
        let source = usesAppleBasal ? "Total y basal de Apple Salud"
            : (fallbackDailyBasal != nil ? "Activas de Apple Salud · basal estimada con tu último InBody" : "Solo activas de Apple Salud")
        return CalorieTimelineResult(bins: bins, source: source)
    }

    /// Agrupa únicamente muestras reales de Energía activa de HealthKit. No
    /// distribuye el total diario cuando falta la serie intradía: hacerlo
    /// dibujaría una precisión temporal que Apple Salud no ha proporcionado.
    static func activeEnergyBins(
        samples: [TrendPoint], events: [EterWidgetEnergyEvent], day: Date,
        through currentHour: Double
    ) -> [ActiveEnergyBin] {
        guard !samples.isEmpty else { return [] }
        var totals: [Int: Double] = [:]
        for sample in samples where Calendar.current.isDate(sample.date, inSameDayAs: day) && sample.value > 0 {
            let sampleHour = hour(of: sample.date, on: day)
            guard sampleHour <= currentHour + 0.001 else { continue }
            let index = max(0, min(47, Int(floor(sampleHour * 2))))
            totals[index, default: 0] += sample.value
        }
        return totals.keys.sorted().compactMap { index in
            guard let calories = totals[index], calories > 0 else { return nil }
            let start = Double(index) / 2
            let end = start + 0.5
            let overlapsWorkout = events.contains { $0.startHour < end && $0.endHour > start }
            return ActiveEnergyBin(
                startHour: start, calories: calories, duringWorkout: overlapsWorkout
            )
        }
    }

    struct CaffeineTimelineResult {
        let points: [EterWidgetCaffeinePoint]
        let currentMg: Double
        let bedtimeMg: Double
        let bedtimeHour: Double
    }

    /// Estimated caffeine still in the body across the whole day. Doses are
    /// additive and decay independently using the disclosed population-average
    /// half-life. Workouts are deliberately not used to alter clearance: they
    /// are aligned on the chart as context, without inventing a causal effect.
    static func caffeineTimeline(lifestyle: [LifestyleEvent], sleepSchedule: [NightlySleepSchedule],
                                 now: Date, currentHour: Double) -> CaffeineTimelineResult {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let doses = lifestyle.compactMap { event -> (date: Date, mg: Double)? in
            let date = event.caffeineDate ?? event.date
            guard event.caffeineMg > 0, date <= now,
                  date >= startOfDay.addingTimeInterval(-30 * 3_600) else { return nil }
            return (date, Double(event.caffeineMg))
        }
        let bedtimeHour = habitualBedtimeHour(sleepSchedule) ?? 23
        func remaining(at date: Date) -> Double {
            doses.reduce(0) { total, dose in
                guard date >= dose.date else { return total }
                let hours = date.timeIntervalSince(dose.date) / 3_600
                return total + dose.mg * CaffeinePharmacokinetics.residualFraction(hoursElapsed: hours)
            }
        }
        let points = stride(from: 0.0, through: 24.0, by: 0.5).map { hour in
            EterWidgetCaffeinePoint(
                hour: hour,
                remainingMg: remaining(at: startOfDay.addingTimeInterval(hour * 3_600))
            )
        }
        return CaffeineTimelineResult(
            points: points,
            currentMg: remaining(at: now),
            bedtimeMg: remaining(at: startOfDay.addingTimeInterval(bedtimeHour * 3_600)),
            bedtimeHour: bedtimeHour
        )
    }

    private static func habitualBedtimeHour(_ schedule: [NightlySleepSchedule]) -> Double? {
        guard schedule.count >= 5 else { return nil }
        let calendar = Calendar.current
        let values = schedule.suffix(30).map { night -> Double in
            let hour = Double(calendar.component(.hour, from: night.bedtime))
            let minute = Double(calendar.component(.minute, from: night.bedtime)) / 60
            let value = hour + minute
            return value < 12 ? value + 24 : value
        }.sorted()
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        // Keep post-midnight bedtimes on the following-day axis (e.g. 00:30
        // becomes 24.5). Otherwise the bedtime estimate would accidentally
        // evaluate 00:30 from the start of today — already in the past.
        return median
    }

    struct EnergyModelResult {
        let energy: Int
        let curve: [Double]
        let basis: String
        let restWindows: [RestorativeWindow]
        let autonomicStrainWindows: [AutonomicStrainWindow]
    }

    struct RestorativeWindow: Equatable {
        let startHour: Double
        let endHour: Double
        /// Puntos que compensan el consumo basal de esta ventana. Una pausa
        /// normal aplana la curva; sólo una calma fisiológica bien observada
        /// permite una subida pequeña.
        let credit: Double
    }

    struct AutonomicStrainWindow: Equatable {
        let startHour: Double
        let endHour: Double
        /// Coste acumulado de pulso anormalmente elevado y sostenido estando
        /// quieto. HRV baja sólo refuerza; una lectura aislada nunca lo crea.
        let penalty: Double
    }

    /// Coste agudo temporal de alcohol ya registrado. No estima alcoholemia:
    /// traduce una exposición conocida a la reserva subjetiva del modelo. El
    /// efecto sube durante 90 min, se mantiene hasta 4 h y se desvanece hasta
    /// las 18 h. Antes de la toma siempre es cero, evitando reescribir el día.
    static func acuteAlcoholPenalty(lifestyle: [LifestyleEvent], at date: Date,
                                    after wakeDate: Date) -> Double {
        let penalty = lifestyle.reduce(0.0) { total, event in
            guard event.alcoholDrinks > 0, event.date > wakeDate, date >= event.date else { return total }
            let age = date.timeIntervalSince(event.date) / 3_600
            guard age <= 18 else { return total }
            let onset = min(1, age / 1.5)
            let recovery = age <= 4 ? 1 : max(0, 1 - (age - 4) / 14)
            return total + min(30, Double(event.alcoholDrinks) * 5) * onset * recovery
        }
        return min(35, penalty)
    }

    /// Consumo inevitable de reserva por permanecer despierto. No depende de
    /// llevar el Watch ni de que Apple entregue calorías: esas señales añaden
    /// coste, pero su ausencia no puede dejar la batería en 90 al acabar el
    /// día. Tras diez horas despierto aumenta suavemente por presión circadiana.
    nonisolated static func diurnalDrain(awakeHours: Double) -> Double {
        let hours = max(0, awakeHours)
        return min(hours, 10) * 0.90 + max(0, hours - 10) * 1.60
    }

    @MainActor
    static func energyModel(
        assessment: TwinAssessment, health: HealthStore, baseline: PersonalBaselineProfile,
        checkIn: DailyCheckIn?, lifestyle: [LifestyleEvent], now: Date,
        currentHour: Double, sleepStartHour: Double?, sleepEndHour: Double?,
        events: [EterWidgetEnergyEvent]
    ) -> EnergyModelResult {
        let sleepNeed = max(6, baseline.sleep.expected ?? 7.5)
        let durationFactor = clamp(health.snapshot.sleepHours / sleepNeed, 0.20, 1.08)
        let restorative = health.sleepStages.deepHours + health.sleepStages.remHours
        let restorativeShare = restorative / max(health.snapshot.sleepHours, 0.1)
        let stageFactor = health.snapshot.sleepHours > 0 && restorative > 0
            ? clamp(0.82 + restorativeShare * 0.65, 0.78, 1.10) : 0.94
        let hrvAdjustment = clamp((baseline.hrv.deviation ?? 0) * 4, -8, 8)
        let restingAdjustment = clamp((baseline.restingHeartRate.deviation ?? 0) * 3, -6, 6)
        let subjectiveSleep = Double((checkIn?.sleepFeeling ?? 3) - 3) * 3
        let endOfSleep = min(currentHour, max(0.5, sleepEndHour ?? min(8, currentHour)))
        let startOfSleep = min(endOfSleep, max(0, sleepStartHour ?? 0))
        let startOfDay = Calendar.current.startOfDay(for: now)
        let wakeDate = startOfDay.addingTimeInterval(endOfSleep * 3_600)
        let overnightAlcohol = lifestyle.filter {
            $0.alcoholDrinks > 0 && $0.date <= wakeDate
                && wakeDate.timeIntervalSince($0.date) <= 18 * 3_600
        }.reduce(0.0) { $0 + Double($1.alcoholDrinks) * 2.5 }
        let illnessPenalty = checkIn?.illness == true ? 10.0 : 0
        // El coste del viaje entra por assessment.score (vía TravelImpact), no
        // con una penalización propia aquí — ver PR15 en el historial.
        let sleepQuality = clamp(durationFactor * stageFactor, 0.16, 1.08)
        // La mañana es una RESERVA absoluta, no "lo que quedaba ayer + unos
        // puntos". El sueño domina; la disponibilidad integra el resto de la
        // fisiología sin reemplazarlo. Así una noche normal puede reconstruir
        // una reserva útil y una mala noche no queda maquillada por el score.
        let wakeEnergy = clamp(
            18 + 48 * sleepQuality + 0.32 * Double(assessment.score) +
            hrvAdjustment + restingAdjustment + subjectiveSleep -
            overnightAlcohol - illnessPenalty,
            20, 98
        )
        // El inicio visible de la noche se infiere porque no almacenamos una
        // batería interdiaria. Se usa sólo para dibujar la recarga; el valor
        // fisiológicamente relevante es la reserva al despertar de arriba.
        let rechargePotential = clamp(18 + 42 * sleepQuality, 18, 64)
        let midnightEnergy = clamp(wakeEnergy - rechargePotential, 5, 65)
        let recharge = wakeEnergy - midnightEnergy

        let awakeHours = max(0, currentHour - endOfSleep)
        let restWindows = restorativeWindows(
            heartRate: health.todayHeartRateSamples,
            hrv: health.todayHRVSamples,
            steps: health.todayStepSamples,
            workouts: health.recentWorkouts,
            restingBaseline: baseline.restingHeartRate.expected,
            hrvBaseline: baseline.hrv.expected,
            day: now, fromHour: endOfSleep, toHour: currentHour
        )
        let autonomicStrainWindows = autonomicStrainWindows(
            heartRate: health.todayHeartRateSamples,
            hrv: health.todayHRVSamples,
            steps: health.todayStepSamples,
            workouts: health.recentWorkouts,
            restingBaseline: baseline.restingHeartRate.expected,
            hrvBaseline: baseline.hrv.expected,
            day: now, fromHour: endOfSleep, toHour: currentHour
        )
        var contextualPenalty = 0.0
        if let checkIn {
            contextualPenalty += Double(max(0, checkIn.stress - 3)) * 2.0
            contextualPenalty += Double(max(0, checkIn.fatigue - 3)) * 2.2
            contextualPenalty += Double(max(0, 3 - checkIn.energy)) * 1.8
        }
        for event in lifestyle where Calendar.current.isDate(event.date, inSameDayAs: now) {
            if event.hydration == .low { contextualPenalty += 4 }
            if event.saunaMinutes > 0 { contextualPenalty += min(4, Double(event.saunaMinutes) / 10) }
            if event.digestiveSymptoms.count > 0 { contextualPenalty += 2 }
        }
        contextualPenalty = clamp(contextualPenalty, 0, 18)

        let pointCount = max(2, Int((currentHour * 2).rounded(.up)) + 1)
        let curve = (0..<pointCount).map { index -> Double in
            let representedHour = min(currentHour, Double(index) / 2)
            if representedHour <= startOfSleep { return midnightEnergy }
            if representedHour <= endOfSleep {
                let progress = (representedHour - startOfSleep) / max(0.25, endOfSleep - startOfSleep)
                return min(100, midnightEnergy + recharge * progress)
            }
            let awakeProgress = (representedHour - endOfSleep) / max(0.5, awakeHours)
            let timeAwake = max(0, representedHour - endOfSleep)
            let basalDrain = diurnalDrain(awakeHours: timeAwake)
            let activeEnergy = cumulativeValue(
                health.todayActiveEnergySamples, through: representedHour, on: now,
                fallbackTotal: Double(health.snapshot.activeEnergy), currentHour: currentHour
            )
            let completedWorkoutCalories = health.recentWorkouts.filter { workout in
                Calendar.current.isDate(workout.date, inSameDayAs: now) &&
                    hour(of: workout.date, on: now) <= representedHour
            }.reduce(0.0) { total, workout in
                let start = hour(of: workout.date, on: now)
                let duration = max(0.05, workout.durationMinutes / 60)
                let completion = clamp((representedHour - start) / duration, 0, 1)
                return total + (workout.calories ?? 0) * completion
            }
            // Active Energy ya incluye pasos: sumarlos otra vez era doble
            // contabilización y explicaba buena parte del vaciado excesivo.
            let nonWorkoutDrain = max(0, activeEnergy - completedWorkoutCalories) / 60
            let restCredit = restWindows.reduce(0.0) { total, window in
                let duration = max(0.01, window.endHour - window.startHour)
                let completion = clamp((representedHour - window.startHour) / duration, 0, 1)
                return total + window.credit * completion
            }
            let autonomicDrain = autonomicStrainWindows.reduce(0.0) { total, window in
                let duration = max(0.01, window.endHour - window.startHour)
                let completion = clamp((representedHour - window.startHour) / duration, 0, 1)
                return total + window.penalty * completion
            }
            let exerciseDrain = events.reduce(0.0) { total, event in
                let duration = max(0.05, event.endHour - event.startHour)
                let completed = clamp((representedHour - event.startHour) / duration, 0, 1)
                return total + event.drain * completed
            }
            let representedDate = startOfDay.addingTimeInterval(representedHour * 3_600)
            let acuteAlcoholDrain = acuteAlcoholPenalty(
                lifestyle: lifestyle, at: representedDate, after: wakeDate
            )
            return max(5, wakeEnergy - basalDrain - nonWorkoutDrain -
                       contextualPenalty * awakeProgress - exerciseDrain - autonomicDrain -
                       acuteAlcoholDrain + restCredit)
        }
        let exerciseDrain = events.reduce(0) { $0 + $1.drain }
        let restCredit = restWindows.reduce(0) { $0 + $1.credit }
        let autonomicDrain = autonomicStrainWindows.reduce(0) { $0 + $1.penalty }
        let grossDayDrain = max(0, wakeEnergy - (curve.last ?? wakeEnergy) - Double(exerciseDrain) + restCredit)
        var basis = "Noche +\(Int(recharge.rounded())) · día −\(Int(grossDayDrain.rounded())) · ejercicio −\(Int(exerciseDrain.rounded()))"
        if restCredit >= 0.5 { basis += " · descanso +\(Int(restCredit.rounded()))" }
        if autonomicDrain >= 0.5 { basis += " · tensión autonómica −\(Int(autonomicDrain.rounded()))" }
        let currentAlcoholDrain = acuteAlcoholPenalty(lifestyle: lifestyle, at: now, after: wakeDate)
        if currentAlcoholDrain >= 0.5 { basis += " · alcohol reciente −\(Int(currentAlcoholDrain.rounded()))" }
        return EnergyModelResult(
            energy: Int((curve.last ?? wakeEnergy).rounded()),
            curve: curve,
            basis: basis,
            restWindows: restWindows,
            autonomicStrainWindows: autonomicStrainWindows
        )
    }

    /// Ventanas de 30 min con movimiento casi nulo y pulso bajo respecto a la
    /// persona. HRV sólo refuerza una ventana cuando coincide temporalmente;
    /// nunca crea descanso por sí sola porque Apple Watch la mide de forma
    /// esporádica y un punto aislado no describe media hora.
    static func restorativeWindows(
        heartRate: [TrendPoint], hrv: [TrendPoint], steps: [TrendPoint],
        workouts: [HealthWorkout], restingBaseline: Double?, hrvBaseline: Double?,
        day: Date, fromHour: Double, toHour: Double
    ) -> [RestorativeWindow] {
        guard let restingBaseline, restingBaseline > 0, toHour - fromHour >= 0.5 else { return [] }
        var result: [RestorativeWindow] = []
        var start = (fromHour * 2).rounded(.up) / 2
        while start + 0.5 <= toHour + 0.001 {
            let end = start + 0.5
            let pulse = heartRate.filter {
                let sampleHour = hour(of: $0.date, on: day)
                return sampleHour >= start && sampleHour < end
            }.map(\.value).sorted()
            let stepCount = steps.filter {
                let sampleHour = hour(of: $0.date, on: day)
                return sampleHour >= start && sampleHour < end
            }.reduce(0.0) { $0 + $1.value }
            let overlapsWorkout = workouts.contains { workout in
                guard Calendar.current.isDate(workout.date, inSameDayAs: day) else { return false }
                let workoutStart = hour(of: workout.date, on: day)
                let workoutEnd = workoutStart + workout.durationMinutes / 60
                return workoutStart < end && workoutEnd > start
            }
            if !overlapsWorkout, stepCount <= 25, pulse.count >= 2 {
                let medianPulse = pulse[pulse.count / 2]
                let calm = medianPulse <= restingBaseline + max(7, restingBaseline * 0.14)
                if calm {
                    let matchingHRV = hrv.filter {
                        let sampleHour = hour(of: $0.date, on: day)
                        return sampleHour >= start && sampleHour < end
                    }.map(\.value)
                    let hrvSupports = hrvBaseline.map { baseline in
                        matchingHRV.contains { $0 >= baseline * 0.90 }
                    } ?? false
                    let deepCalm = medianPulse <= restingBaseline + 4 && (hrvSupports || pulse.count >= 4)
                    result.append(RestorativeWindow(
                        startHour: start, endHour: end,
                        // 30 min despierto consumen ~0,29 puntos basales. Una
                        // pausa normal los compensa; ni siquiera una calma muy
                        // sólida debe fabricar una recarga relevante por sí sola.
                        credit: deepCalm ? 0.35 : 0.29
                    ))
                }
            }
            start = end
        }
        // Una hora tranquila es una sola pausa, no dos eventos de 30 min.
        // Se conservan bins cortos para el cálculo y se fusionan sólo al
        // exponerlos a la gráfica.
        var merged: [RestorativeWindow] = []
        for window in result {
            if let last = merged.last, abs(last.endHour - window.startHour) < 0.001 {
                merged[merged.count - 1] = RestorativeWindow(
                    startHour: last.startHour, endHour: window.endHour,
                    credit: last.credit + window.credit
                )
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    /// Detecta tensión autonómica durante reposo aparente. El movimiento y el
    /// entrenamiento ya tienen sus propios costes, por lo que se excluyen para
    /// no contar doble. Se requieren al menos tres lecturas de pulso en 30 min;
    /// HRV sólo aumenta la confianza cuando hay dos muestras bajas recientes.
    static func autonomicStrainWindows(
        heartRate: [TrendPoint], hrv: [TrendPoint], steps: [TrendPoint],
        workouts: [HealthWorkout], restingBaseline: Double?, hrvBaseline: Double?,
        day: Date, fromHour: Double, toHour: Double
    ) -> [AutonomicStrainWindow] {
        guard let restingBaseline, restingBaseline > 0, toHour - fromHour >= 0.5 else { return [] }
        var result: [AutonomicStrainWindow] = []
        var start = (fromHour * 2).rounded(.up) / 2
        while start + 0.5 <= toHour + 0.001 {
            let end = start + 0.5
            let pulse = heartRate.filter {
                let sampleHour = hour(of: $0.date, on: day)
                return sampleHour >= start && sampleHour < end
            }.map(\.value).sorted()
            let stepCount = steps.filter {
                let sampleHour = hour(of: $0.date, on: day)
                return sampleHour >= start && sampleHour < end
            }.reduce(0.0) { $0 + $1.value }
            let overlapsWorkout = workouts.contains { workout in
                guard Calendar.current.isDate(workout.date, inSameDayAs: day) else { return false }
                let workoutStart = hour(of: workout.date, on: day)
                let workoutEnd = workoutStart + workout.durationMinutes / 60
                return workoutStart < end && workoutEnd > start
            }
            if !overlapsWorkout, stepCount <= 25, pulse.count >= 3 {
                let medianPulse = pulse[pulse.count / 2]
                let elevatedThreshold = restingBaseline + max(25, restingBaseline * 0.50)
                if medianPulse >= elevatedThreshold {
                    let recentHRV = hrv.filter {
                        let sampleHour = hour(of: $0.date, on: day)
                        return sampleHour >= max(fromHour, start - 3) && sampleHour < end
                    }.map(\.value).sorted()
                    let lowHRV = hrvBaseline.map { baseline in
                        recentHRV.count >= 2 && recentHRV[recentHRV.count / 2] <= baseline * 0.80
                    } ?? false
                    let veryElevated = medianPulse >= restingBaseline + max(35, restingBaseline * 0.70)
                    let basePenalty = veryElevated ? 0.90 : 0.55
                    result.append(AutonomicStrainWindow(
                        startHour: start, endHour: end,
                        penalty: basePenalty + (lowHRV ? 0.25 : 0)
                    ))
                }
            }
            start = end
        }
        var merged: [AutonomicStrainWindow] = []
        for window in result {
            if let last = merged.last, abs(last.endHour - window.startHour) < 0.001 {
                merged[merged.count - 1] = AutonomicStrainWindow(
                    startHour: last.startHour, endHour: window.endHour,
                    penalty: last.penalty + window.penalty
                )
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    private static func cumulativeValue(_ samples: [TrendPoint], through representedHour: Double,
                                        on day: Date, fallbackTotal: Double,
                                        currentHour: Double) -> Double {
        guard !samples.isEmpty else {
            return fallbackTotal * clamp(representedHour / max(0.5, currentHour), 0, 1)
        }
        return samples.reduce(0.0) { total, point in
            hour(of: point.date, on: day) <= representedHour ? total + point.value : total
        }
    }

    @MainActor
    static func energyEvents(health: HealthStore, imports: ImportStore, now: Date) -> [EterWidgetEnergyEvent] {
        let calendar = Calendar.current
        var result = health.recentWorkouts.filter {
            calendar.isDate($0.date, inSameDayAs: now) && $0.date <= now
        }.map { workout in
            let start = hour(of: workout.date, on: now)
            let end = min(hour(of: now, on: now), start + workout.durationMinutes / 60)
            let intensity = workout.averageHeartRate.map { clamp(($0 - 85) / 100, 0.2, 1) } ?? 0.45
            let drain = workout.calories.map { $0 / 24 } ?? workout.durationMinutes * (0.10 + intensity * 0.13)
            return EterWidgetEnergyEvent(
                startHour: max(0, start), endHour: max(start + 0.05, end),
                symbol: workoutSymbol(workout.activity), drain: clamp(drain, 2, 45)
            )
        }
        for workout in imports.workouts where calendar.isDate(workout.start, inSameDayAs: now) && workout.start <= now {
            let mirrored = health.recentWorkouts.contains { abs($0.date.timeIntervalSince(workout.start)) < 5 * 60 }
            guard !mirrored else { continue }
            let start = hour(of: workout.start, on: now)
            let end = min(hour(of: now, on: now), hour(of: workout.end, on: now))
            let duration = max(1, workout.end.timeIntervalSince(workout.start) / 60)
            result.append(EterWidgetEnergyEvent(
                startHour: max(0, start), endHour: max(start + 0.05, end),
                symbol: "dumbbell.fill", drain: clamp(duration * 0.18, 2, 28)
            ))
        }
        return result.sorted { $0.startHour < $1.startHour }
    }

    /// Eventos de estilo de vida de HOY convertidos en marcadores con hora, para
    /// superponerlos sobre la curva. No modelan un valor (la curva ya absorbe su
    /// efecto donde lo tiene): son anotaciones de "aquí pasó esto", que es lo que
    /// el reto pedía — ver el input y la respuesta fisiológica en el mismo sitio.
    static func inputMarkers(from lifestyle: [LifestyleEvent], checkIn: DailyCheckIn? = nil,
                             travel: TravelEpisode? = nil, sleepHours: Double = 0,
                             sleepEndHour: Double? = nil, now: Date) -> [EterWidgetInputMarker] {
        let calendar = Calendar.current
        let nowHour = hour(of: now, on: now)
        var markers: [EterWidgetInputMarker] = []
        func add(_ date: Date, _ symbol: String, _ kind: String, _ label: String) {
            guard calendar.isDate(date, inSameDayAs: now) else { return }
            markers.append(EterWidgetInputMarker(hour: hour(of: date, on: now), symbol: symbol, kind: kind, label: label))
        }
        for event in lifestyle {
            if event.saunaMinutes > 0 { add(event.date, "flame.fill", "sauna", "Sauna \(event.saunaMinutes) min") }
            if event.coldMinutes > 0 { add(event.date, "snowflake", "cold", "Frío \(event.coldMinutes) min") }
            if event.caffeineMg > 0 { add(event.caffeineDate ?? event.date, "cup.and.saucer.fill", "coffee", "Cafeína \(event.caffeineMg) mg") }
            if event.alcoholDrinks > 0 { add(event.date, "wineglass.fill", "alcohol", "\(event.alcoholDrinks) bebida\(event.alcoholDrinks == 1 ? "" : "s")") }
            if event.trainedFasted {
                add(event.date, "figure.run", "fastedTraining", "Entrenamiento en ayunas")
            }
            if event.foodQuality != .notRecorded || event.fastingHours > 0 || event.lateDinner || event.heavyDinner {
                var details: [String] = []
                if event.foodQuality != .notRecorded { details.append(event.foodQuality.rawValue) }
                if event.fastingHours > 0 { details.append("ayuno \(event.fastingHours) h") }
                if event.lateDinner { details.append("cena tardía") }
                if event.heavyDinner { details.append("cena copiosa") }
                add(event.date, "fork.knife", "food", details.joined(separator: " · "))
            }
            if !event.supplements.isEmpty {
                add(event.supplementsDate ?? event.date, "pills.fill", "supplement",
                    event.supplements.map(\.rawValue).sorted().joined(separator: ", "))
            }
        }
        if let checkIn, calendar.isDate(checkIn.createdAt, inSameDayAs: now) {
            if checkIn.stress >= 4 {
                add(checkIn.createdAt, "brain.head.profile", "stress", "Estrés declarado \(checkIn.stress)/5")
            } else if checkIn.stress <= 2 && checkIn.fatigue <= 2 {
                add(checkIn.createdAt, "figure.mind.and.body", "rest", "Descanso declarado")
            }
        }
        if sleepHours > 0, let sleepEndHour {
            let markerDate = calendar.startOfDay(for: now).addingTimeInterval(sleepEndHour * 3_600)
            add(markerDate, "moon.zzz.fill", "sleep", String(format: "Sueño %.1f h", sleepHours))
        }
        if let travel, !travel.isCancelled {
            let boundaries = [travel.outboundDeparture, travel.destinationArrival,
                              travel.returnDeparture, travel.homeArrival].compactMap { $0 }
            if let boundary = boundaries.first(where: { calendar.isDate($0, inSameDayAs: now) }) {
                add(boundary, "airplane", "travel", travel.title)
            } else if travel.outboundDeparture.map({ $0 <= now }) == true {
                let start = calendar.startOfDay(for: now).addingTimeInterval(15 * 60)
                add(start, "airplane", "travel", "Viaje activo · \(travel.title)")
            }
        }
        return markers.filter { $0.hour <= nowHour + 0.001 }.sorted { $0.hour < $1.hour }
    }

    static func workoutSymbol(_ activity: String) -> String {
        switch activity {
        case "Carrera": return "figure.run"
        case "Ciclismo": return "figure.outdoor.cycle"
        case "Fuerza", "Fuerza funcional": return "dumbbell.fill"
        case "Natación": return "figure.pool.swim"
        default: return "figure.mixed.cardio"
        }
    }

    static func hour(of date: Date, on day: Date) -> Double {
        let start = Calendar.current.startOfDay(for: day)
        return date.timeIntervalSince(start) / 3600
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
