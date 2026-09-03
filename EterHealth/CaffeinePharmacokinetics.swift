import Foundation

// The gap this closes: HabitAssociationEngine's .lateCaffeine has only
// ever been a binary flag (caffeine consumed at/after 14:00, see
// HabitAssociationEngine.occurrences) — an espresso at 14:01 and one at
// 21:00 read identically. Caffeine elimination is real, textbook first-
// order pharmacokinetics (a single population-average half-life, not a
// personally-fit one — individual half-life genuinely varies 3-7h with
// genetics/pregnancy/liver function/smoking, so this stays a disclosed
// average, never presented as measured for this specific person).
enum CaffeinePharmacokinetics {
    // Commonly cited average for a healthy adult (e.g. FDA consumer
    // guidance, pharmacology references) — the literature range is
    // roughly 3-7h; this is the population midpoint, not a personal
    // measurement.
    static let averageHalfLifeHours = 5.0

    // Fraction of a dose still active after `hoursElapsed`, plain
    // first-order elimination: remaining = 0.5^(t / half-life).
    nonisolated static func residualFraction(hoursElapsed: Double) -> Double {
        guard hoursElapsed >= 0 else { return 1.0 }
        return pow(0.5, hoursElapsed / averageHalfLifeHours)
    }

    // Hours between an intake hour-of-day and a bedtime hour-of-day,
    // both in 0..<24 — handles the intake being "yesterday evening" as
    // seen from an after-midnight bedtime by wrapping forward, never
    // negative.
    nonisolated static func hoursUntilBedtime(intakeHour: Double, bedtimeHour: Double) -> Double {
        let raw = bedtimeHour - intakeHour
        return raw >= 0 ? raw : raw + 24
    }

    nonisolated static func typicalBedtimeHour(_ schedule: [NightlySleepSchedule]) -> Double {
        let values = schedule.map { item -> Double in
            let components = Calendar.current.dateComponents([.hour, .minute], from: item.bedtime)
            let raw = Double(components.hour ?? 23) + Double(components.minute ?? 0) / 60
            return raw < 12 ? raw + 24 : raw
        }.sorted()
        guard !values.isEmpty else { return 23 }
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return median.truncatingRemainder(dividingBy: 24)
    }

    nonisolated static func estimatedRemainingAtBedtime(
        doseMg: Double, consumed: Date, schedule: [NightlySleepSchedule]
    ) -> Double {
        let components = Calendar.current.dateComponents([.hour, .minute], from: consumed)
        let intakeHour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
        let elapsed = hoursUntilBedtime(intakeHour: intakeHour, bedtimeHour: typicalBedtimeHour(schedule))
        return doseMg * residualFraction(hoursElapsed: elapsed)
    }
}
