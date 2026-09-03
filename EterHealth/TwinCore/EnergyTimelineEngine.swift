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
            ), caffeine: caffeine
        )
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
    }

    @MainActor
    static func energyModel(
        assessment: TwinAssessment, health: HealthStore, baseline: PersonalBaselineProfile,
        checkIn: DailyCheckIn?, lifestyle: [LifestyleEvent], now: Date,
        currentHour: Double, sleepStartHour: Double?, sleepEndHour: Double?,
        events: [EterWidgetEnergyEvent]
    ) -> EnergyModelResult {
        let sleepNeed = max(6, baseline.sleep.expected ?? 7.5)
        let durationFactor = clamp(health.snapshot.sleepHours / sleepNeed, 0.45, 1.15)
        let restorative = health.sleepStages.deepHours + health.sleepStages.remHours
        let restorativeShare = restorative / max(health.snapshot.sleepHours, 0.1)
        let stageFactor = health.snapshot.sleepHours > 0 && restorative > 0
            ? clamp(0.82 + restorativeShare * 0.65, 0.78, 1.10) : 0.94
        let hrvAdjustment = clamp((baseline.hrv.deviation ?? 0) * 4, -8, 8)
        let restingAdjustment = clamp((baseline.restingHeartRate.deviation ?? 0) * 3, -6, 6)
        let subjectiveSleep = Double((checkIn?.sleepFeeling ?? 3) - 3) * 3
        let overnightAlcohol = lifestyle.filter {
            $0.alcoholDrinks > 0 && now.timeIntervalSince($0.date) <= 18 * 3600
        }.reduce(0.0) { $0 + Double($1.alcoholDrinks) * 2.5 }
        let illnessPenalty = checkIn?.illness == true ? 10.0 : 0
        // El coste del viaje entra por assessment.score (vía TravelImpact), no
        // con una penalización propia aquí — ver PR15 en el historial.
        let recharge = clamp(
            48 * durationFactor * stageFactor + hrvAdjustment + restingAdjustment +
            subjectiveSleep - overnightAlcohol - illnessPenalty,
            12, 72
        )
        // Readiness acts as a bounded physiological anchor; the recharge calculation
        // determines how the night reached that morning reserve rather than replacing it.
        let wakeEnergy = clamp(0.58 * (20 + recharge) + 0.42 * Double(assessment.score), 22, 98)
        let midnightEnergy = max(5, wakeEnergy - recharge)

        let endOfSleep = min(currentHour, max(0.5, sleepEndHour ?? min(8, currentHour)))
        let startOfSleep = min(endOfSleep, max(0, sleepStartHour ?? 0))
        let awakeHours = max(0, currentHour - endOfSleep)
        let workoutCalories = health.recentWorkouts.filter {
            Calendar.current.isDate($0.date, inSameDayAs: now)
        }.compactMap(\.calories).reduce(0, +)
        let nonWorkoutEnergy = max(0, Double(health.snapshot.activeEnergy) - workoutCalories)
        var backgroundDrain = awakeHours * 0.72 + nonWorkoutEnergy / 42 + Double(health.snapshot.steps) / 3_500
        if let checkIn {
            backgroundDrain += Double(max(0, checkIn.stress - 3)) * 2.2
            backgroundDrain += Double(max(0, checkIn.fatigue - 3)) * 2.4
            backgroundDrain += Double(max(0, 3 - checkIn.energy)) * 2.0
        }
        for event in lifestyle where Calendar.current.isDate(event.date, inSameDayAs: now) {
            if event.hydration == .low { backgroundDrain += 4 }
            if event.saunaMinutes > 0 { backgroundDrain += min(4, Double(event.saunaMinutes) / 10) }
            if event.digestiveSymptoms.count > 0 { backgroundDrain += 2 }
        }
        backgroundDrain = clamp(backgroundDrain, 0, 42)

        let pointCount = max(2, Int((currentHour * 2).rounded(.up)) + 1)
        let curve = (0..<pointCount).map { index -> Double in
            let representedHour = min(currentHour, Double(index) / 2)
            if representedHour <= startOfSleep { return midnightEnergy }
            if representedHour <= endOfSleep {
                let progress = (representedHour - startOfSleep) / max(0.25, endOfSleep - startOfSleep)
                return min(100, midnightEnergy + recharge * progress)
            }
            let awakeProgress = (representedHour - endOfSleep) / max(0.5, currentHour - endOfSleep)
            let exerciseDrain = events.reduce(0.0) { total, event in
                let duration = max(0.05, event.endHour - event.startHour)
                let completed = clamp((representedHour - event.startHour) / duration, 0, 1)
                return total + event.drain * completed
            }
            return max(5, wakeEnergy - backgroundDrain * awakeProgress - exerciseDrain)
        }
        let exerciseDrain = events.reduce(0) { $0 + $1.drain }
        let basis = "Noche +\(Int(recharge.rounded())) · día −\(Int(backgroundDrain.rounded())) · ejercicio −\(Int(exerciseDrain.rounded()))"
        return EnergyModelResult(
            energy: Int((curve.last ?? wakeEnergy).rounded()),
            curve: curve,
            basis: basis
        )
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
