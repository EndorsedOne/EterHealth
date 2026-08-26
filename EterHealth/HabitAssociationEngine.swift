import Foundation

enum HabitKind: String, CaseIterable, Hashable, Identifiable {
    case alcohol, lateCaffeine, sauna, cold, travel, indulgentFood, healthyFood
    case fasting, lateOrHeavyDinner, lowHydration
    // Each supplement gets its own kind rather than one generic
    // "suplementos" bucket — mixing magnesium and creatine into a single
    // learned association would average away two effects that have
    // nothing to do with each other, exactly the mistake this same file's
    // headline(...) logic already goes out of its way to avoid.
    // .creatine removed — see SupplementKind's own comment: no plausible
    // mechanistic path from creatine to HRV/pulso/sueño, the three
    // signals this learned-association mechanism actually observes.
    case magnesiumGlycinate, melatonin, ashwagandha, lTheanine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .alcohol: return "Alcohol"
        case .lateCaffeine: return "Cafeína tardía"
        case .sauna: return "Sauna"
        case .cold: return "Agua fría"
        case .travel: return "Viaje y cambio horario"
        case .indulgentFood: return "Comida libre"
        case .healthyFood: return "Comida saludable"
        case .fasting: return "Ayuno"
        case .lateOrHeavyDinner: return "Cena tardía o copiosa"
        case .lowHydration: return "Hidratación baja"
        case .magnesiumGlycinate: return SupplementKind.magnesiumGlycinate.rawValue
        case .melatonin: return SupplementKind.melatonin.rawValue
        case .ashwagandha: return SupplementKind.ashwagandha.rawValue
        case .lTheanine: return SupplementKind.lTheanine.rawValue
        }
    }
    var icon: String {
        switch self {
        case .alcohol: return "wineglass"
        case .lateCaffeine: return "cup.and.saucer.fill"
        case .sauna: return "heat.waves"
        case .cold: return "snowflake"
        case .travel: return "airplane"
        case .indulgentFood, .healthyFood, .lateOrHeavyDinner: return "fork.knife"
        case .fasting: return "clock"
        case .lowHydration: return "drop"
        case .magnesiumGlycinate, .melatonin, .ashwagandha, .lTheanine:
            return SupplementKind(rawValue: title)?.icon ?? "pills.fill"
        }
    }
}

extension HabitKind {
    static func forSupplement(_ supplement: SupplementKind) -> HabitKind {
        switch supplement {
        case .magnesiumGlycinate: return .magnesiumGlycinate
        case .melatonin: return .melatonin
        case .ashwagandha: return .ashwagandha
        case .lTheanine: return .lTheanine
        }
    }
}

struct HabitOccurrence {
    let kind: HabitKind
    let date: Date
    let overlapsOtherFactors: Bool
}

struct HabitMetricEffect: Identifiable, Equatable {
    var id: String { name }
    let name: String
    /// Favorable percentage change against the personal rolling reference.
    let changePercent: Double
}

enum HabitAssociationDirection: Equatable {
    case favorable, adverse, neutral
}

struct HabitAssociation: Identifiable {
    var id: HabitKind { kind }
    let kind: HabitKind
    let samples: Int
    let effects: [HabitMetricEffect]
    let compositeChange: Double
    let direction: HabitAssociationDirection
    let confidence: ConfidenceAssessment
    let headline: String
}

enum HabitAssociationEngine {
    nonisolated static func readinessImpact(_ association: HabitAssociation) -> Int {
        guard association.confidence.level != .low,
              association.direction != .neutral else { return 0 }
        let limit = association.confidence.level == .high ? 5 : 3
        let scaled = Int((association.compositeChange / 4).rounded())
        return max(-limit, min(limit, scaled))
    }

    /// Electrolytes are treated as mitigation, never as an independent recovery bonus.
    /// The modifier only exists when a compatible stressor was also recorded.
    nonisolated static func electrolyteMitigation(
        hydrationLow: Bool, saunaMinutes: Int, prolongedExerciseMinutes: Double
    ) -> Int {
        var points = 0
        if hydrationLow { points += 1 }
        if saunaMinutes >= 15 { points += 1 }
        if prolongedExerciseMinutes >= 60 { points += prolongedExerciseMinutes >= 90 ? 2 : 1 }
        return min(3, points)
    }

    @MainActor static func analyze(
        events: [LifestyleEvent], alcohol: [AlcoholSample],
        hrv: [TrendPoint], restingHeartRate: [TrendPoint], sleep: [TrendPoint],
        respiratoryRate: [TrendPoint] = [], wristTemperature: [TrendPoint] = [],
        now: Date = Date()
    ) -> [HabitAssociation] {
        analyze(
            occurrences: occurrences(events: events, alcohol: alcohol),
            hrv: hrv, restingHeartRate: restingHeartRate, sleep: sleep,
            respiratoryRate: respiratoryRate, wristTemperature: wristTemperature, now: now
        )
    }

    // Respiratory rate and wrist temperature added alongside HRV/pulse/sleep:
    // not because science says exactly these 5 and no others, but because
    // these two are already collected (HealthStore.respiratoryRateHistory/
    // wristTemperatureHistory) and already used as illness/overreaching
    // signals in PhysiologicalAlertEngine — the same validated wearable-
    // recovery markers Oura/Whoop track, just never wired into this
    // person's own habit learning before. Both default to favorableHigh:
    // false, same convention PhysiologicalAlertEngine already uses (a rise
    // in either is the adverse direction). Oxygen saturation was
    // deliberately left out: in a healthy person it sits near-ceiling
    // (95-100%) with too little day-to-day variance to learn anything real
    // from — adding it would mostly add noise, not signal.
    nonisolated static func analyze(
        occurrences: [HabitOccurrence], hrv: [TrendPoint],
        restingHeartRate: [TrendPoint], sleep: [TrendPoint],
        respiratoryRate: [TrendPoint] = [], wristTemperature: [TrendPoint] = [], now: Date = Date()
    ) -> [HabitAssociation] {
        let completed = occurrences.filter { $0.date < now.addingTimeInterval(-6 * 3_600) }
        return HabitKind.allCases.compactMap { kind in
            let exposures = uniqueDays(completed.filter { $0.kind == kind })
            var rows: [[String: Double]] = []
            var overlapCount = 0
            for exposure in exposures {
                var row: [String: Double] = [:]
                if let value = relativeOutcome(after: exposure.date, points: hrv, favorableHigh: true) { row["HRV"] = value }
                if let value = relativeOutcome(after: exposure.date, points: restingHeartRate, favorableHigh: false) { row["Pulso"] = value }
                if let value = relativeOutcome(after: exposure.date, points: sleep, favorableHigh: true) { row["Sueño"] = value }
                if let value = relativeOutcome(after: exposure.date, points: respiratoryRate, favorableHigh: false) { row["Respiración"] = value }
                if let value = relativeOutcome(after: exposure.date, points: wristTemperature, favorableHigh: false) { row["Temperatura de muñeca"] = value }
                guard !row.isEmpty else { continue }
                rows.append(row)
                if exposure.overlapsOtherFactors { overlapCount += 1 }
            }
            guard rows.count >= 2 else { return nil }

            let names = ["HRV", "Pulso", "Sueño", "Respiración", "Temperatura de muñeca"]
            let effects = names.compactMap { name -> HabitMetricEffect? in
                let values = rows.compactMap { $0[name] }
                guard values.count >= 2 else { return nil }
                return HabitMetricEffect(name: name, changePercent: average(values))
            }
            guard !effects.isEmpty else { return nil }
            let rowComposites = rows.map { average(Array($0.values)) }
            let composite = average(rowComposites)
            let direction: HabitAssociationDirection = composite <= -2 ? .adverse : composite >= 2 ? .favorable : .neutral
            let consistent = rowComposites.filter {
                direction == .neutral ? abs($0) < 3 : (direction == .favorable ? $0 > 0 : $0 < 0)
            }.count
            let consistency = Double(consistent) / Double(max(1, rowComposites.count))
            let overlapRatio = Double(overlapCount) / Double(max(1, rows.count))
            let confidence = ConfidenceEngine.habitAssociation(
                samples: rows.count, metrics: effects.count,
                overlapRatio: overlapRatio, consistency: consistency
            )
            return HabitAssociation(
                kind: kind, samples: rows.count, effects: effects,
                compositeChange: composite, direction: direction, confidence: confidence,
                headline: headline(kind: kind, direction: direction, composite: composite, samples: rows.count, effects: effects)
            )
        }
        .sorted {
            if $0.confidence.score != $1.confidence.score { return $0.confidence.score > $1.confidence.score }
            return abs($0.compositeChange) > abs($1.compositeChange)
        }
    }

    @MainActor private static func occurrences(events: [LifestyleEvent], alcohol: [AlcoholSample]) -> [HabitOccurrence] {
        let calendar = Calendar.current
        var result: [HabitOccurrence] = []
        var localAlcoholDays: Set<Date> = []
        for event in events {
            var kinds: [HabitKind] = []
            if event.alcoholDrinks > 0 { kinds.append(.alcohol); localAlcoholDays.insert(calendar.startOfDay(for: event.date)) }
            // Falls back to `event.date`, same as everywhere else
            // caffeineDate is read — an unfilled "Hora de consumo" must not
            // silently drop the late-caffeine signal entirely.
            let caffeineDate = event.caffeineDate ?? event.date
            if event.caffeineMg > 0, calendar.component(.hour, from: caffeineDate) >= 14 { kinds.append(.lateCaffeine) }
            if event.saunaMinutes > 0 { kinds.append(.sauna) }
            if event.coldMinutes > 0 { kinds.append(.cold) }
            if event.timeZoneDifference > 0 { kinds.append(.travel) }
            if event.foodQuality == .indulgent { kinds.append(.indulgentFood) }
            if event.foodQuality == .healthy { kinds.append(.healthyFood) }
            if event.fastingHours >= 12 { kinds.append(.fasting) }
            if event.lateDinner || event.heavyDinner { kinds.append(.lateOrHeavyDinner) }
            if event.hydration == .low { kinds.append(.lowHydration) }
            let overlap = kinds.count + event.supplements.count > 1
            result += kinds.map { HabitOccurrence(kind: $0, date: event.date, overlapsOtherFactors: overlap) }
            // Supplements get their own timestamp (supplementsDate, falling
            // back to event.date) instead of inheriting the day-level
            // `date` every other factor above shares — a dose taken right
            // before bed vs. after breakfast is a different exposure for
            // the "day after" HRV/sleep comparison relativeOutcome makes.
            let supplementsDate = event.supplementsDate ?? event.date
            result += event.supplements.map { HabitOccurrence(kind: HabitKind.forSupplement($0), date: supplementsDate, overlapsOtherFactors: overlap) }
        }
        for sample in alcohol {
            let day = calendar.startOfDay(for: sample.date)
            guard sample.drinks > 0, !localAlcoholDays.contains(day) else { continue }
            result.append(HabitOccurrence(kind: .alcohol, date: sample.date, overlapsOtherFactors: false))
        }
        return result
    }

    private nonisolated static func uniqueDays(_ values: [HabitOccurrence]) -> [HabitOccurrence] {
        var days: Set<Date> = []
        return values.sorted { $0.date < $1.date }.filter {
            let day = Calendar.current.startOfDay(for: $0.date)
            return days.insert(day).inserted
        }
    }

    private nonisolated static func relativeOutcome(
        after exposure: Date, points: [TrendPoint], favorableHigh: Bool
    ) -> Double? {
        let calendar = Calendar.current
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: exposure)) else { return nil }
        guard let outcome = points.first(where: { calendar.isDate($0.date, inSameDayAs: nextDay) }) else { return nil }
        let prior = points.filter { $0.date < nextDay }.suffix(42).map(\.value)
        guard prior.count >= 7, let baseline = median(Array(prior)), baseline != 0 else { return nil }
        let raw = (outcome.value - baseline) / abs(baseline) * 100
        return max(-50, min(50, favorableHigh ? raw : -raw))
    }

    // A bare "-8% en promedio" hides the actual finding: averaging 5 metrics
    // together can't tell you whether a habit hits everything at once or
    // just one signal, and a promedio doesn't say which one to actually pay
    // attention to. This names the metric that moves the most, and whether
    // the rest move with it (a systemic, whole-body pattern) or stay put (an
    // isolated one) — the second-degree read a raw percentage can't give.
    private nonisolated static func headline(
        kind: HabitKind, direction: HabitAssociationDirection, composite: Double, samples: Int, effects: [HabitMetricEffect]
    ) -> String {
        let magnitude = abs(composite)
        // Even at low sample counts, naming the actual metric that moved
        // beats a composite percentage nobody asked for — "hidden" here only
        // in confidence (explicitly hedged), never in which signal it's about.
        if samples < 4 {
            guard let dominant = effects.max(by: { abs($0.changePercent) < abs($1.changePercent) }) else {
                return "Primer patrón: después coincide con un cambio \(direction == .favorable ? "favorable" : direction == .adverse ? "desfavorable" : "pequeño") del \(Int(magnitude.rounded()))%."
            }
            return "Primer patrón (\(samples) episodio\(samples == 1 ? "" : "s")): lo que más se mueve es tu \(dominant.name.lowercased()) (\(dominant.changePercent >= 0 ? "+" : "")\(Int(dominant.changePercent.rounded()))%). Hacen falta más registros para confirmarlo."
        }
        guard direction != .neutral, let dominant = effects.max(by: { abs($0.changePercent) < abs($1.changePercent) }) else {
            return "Por ahora no aparece un cambio consistente en tus señales posteriores."
        }
        let sign = direction == .favorable ? 1.0 : -1.0
        let others = effects.filter { $0.name != dominant.name }
        let concordant = others.filter { $0.changePercent * sign > 0 }
        let silent = others.filter { abs($0.changePercent) < 3 }
        let verb = direction == .favorable ? "mejora" : "empeora"
        let dominantText = "\(dominant.name.lowercased()) (\(dominant.changePercent >= 0 ? "+" : "")\(Int(dominant.changePercent.rounded()))%)"
        if others.isEmpty {
            return "Lo que más se mueve después es tu \(dominantText); es la única señal con datos suficientes todavía."
        }
        if concordant.count == others.count {
            return "Reacciona en bloque: \(dominantText) \(verb) más que el resto, pero \(others.map { $0.name.lowercased() }.joined(separator: " y ")) van en la misma dirección — un patrón de cuerpo entero, no una señal aislada."
        }
        if silent.count == others.count {
            return "Un efecto concentrado: solo tu \(dominantText) se mueve de forma clara; \(others.map { $0.name.lowercased() }.joined(separator: " y ")) apenas cambian."
        }
        let discordant = others.filter { !concordant.contains($0) && !silent.contains($0) }
        return "Domina tu \(dominantText), pero no es uniforme: \(discordant.map { $0.name.lowercased() }.joined(separator: " y ")) se mueve en dirección contraria — vale la pena confirmarlo con más registros antes de sacar una conclusión firme."
    }

    private nonisolated static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
