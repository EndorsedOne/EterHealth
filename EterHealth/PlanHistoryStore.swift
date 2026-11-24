import Foundation

struct PlanSnapshot: Codable, Identifiable {
    let id: UUID
    let date: Date
    let recommendation: String
    let rationale: String
    var sessionKind: PlannedSessionKind? = nil
}

struct BlockAdherenceSummary {
    let observedDays: Int
    let matchedDays: Int
    let plannedStrengthDays: Int
    let completedStrengthDays: Int
    var restDaysWithTraining: Int = 0
    var days: [BlockAdherenceDay] = []
}

struct BlockAdherenceDay: Identifiable {
    enum State { case matched, mismatch, unknown }
    let date: Date
    let state: State
    var id: Date { date }
}

enum BlockAdherenceEngine {
    /// Compare only observed prescriptions preceding work. Missing snapshots
    /// are unknown, never missed workouts. Categories deliberately do not claim
    /// to measure quality, volume, RIR or compliance with an entire session.
    static func summarize(snapshots: [PlanSnapshot], strengthDates: [Date],
                          aerobicDates: [Date], days: Int = 28,
                          now: Date = Date(), calendar: Calendar = .current) -> BlockAdherenceSummary {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        var matched = 0, strengthPlanned = 0, strengthDone = 0, observed = 0
        var restDaysWithTraining = 0
        var seen: Set<Date> = []
        var dayStates: [Date: BlockAdherenceDay.State] = [:]
        for snapshot in snapshots.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: snapshot.date)
            guard day >= start, day < today, seen.insert(day).inserted,
                  let kind = snapshot.sessionKind else { continue }
            let lifts = strengthDates.filter { calendar.isDate($0, inSameDayAs: day) }
            let cardio = aerobicDates.filter { calendar.isDate($0, inSameDayAs: day) }
            guard !(lifts + cardio).contains(where: { $0 < snapshot.date }) else { continue }
            let didLift = !lifts.isEmpty, didCardio = !cardio.isEmpty
            let matchedBefore = matched
            let observedBefore = observed
            switch kind {
            case .strength:
                observed += 1; strengthPlanned += 1
                if didLift { matched += 1; strengthDone += 1 }
            case .easyRun, .qualityRun, .longRun, .swim, .bike:
                observed += 1
                if didCardio { matched += 1 }
            case .recovery:
                observed += 1
                if !didLift && !didCardio { matched += 1 }
                else { restDaysWithTraining += 1 }
            default: break // No invented equivalence for hybrid/race/brick.
            }
            if observed > observedBefore { dayStates[day] = matched > matchedBefore ? .matched : .mismatch }
        }
        let timeline = (0..<max(0, days)).compactMap { offset -> BlockAdherenceDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return BlockAdherenceDay(date: date, state: dayStates[date] ?? .unknown)
        }
        return BlockAdherenceSummary(observedDays: observed, matchedDays: matched,
            plannedStrengthDays: strengthPlanned, completedStrengthDays: strengthDone,
            restDaysWithTraining: restDaysWithTraining, days: timeline)
    }
}

@MainActor
final class PlanHistoryStore: ObservableObject {
    static let shared = PlanHistoryStore()
    @Published private(set) var snapshots: [PlanSnapshot] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("plan-history.json")
    }
    private init() { load() }

    func captureIfNeeded(_ plan: WeeklyPlanStatus, health: HealthStore, now: Date = Date()) {
        let calendar = Calendar.current
        guard !snapshots.contains(where: { calendar.isDate($0.date, inSameDayAs: now) }) else { return }
        // If Éter is first opened after training, don't pretend the adapted recovery plan was the pre-session plan.
        let alreadyTrained = health.recentWorkouts.contains {
            calendar.isDate($0.date, inSameDayAs: now) && $0.date.addingTimeInterval($0.durationMinutes * 60) <= now
        }
        guard !alreadyTrained else { return }
        snapshots.append(PlanSnapshot(id: UUID(), date: now, recommendation: plan.nextSession.rawValue,
                                      rationale: plan.rationale, sessionKind: plan.nextSession))
        snapshots.sort { $0.date > $1.date }; persist()
    }

    func snapshot(for workoutDate: Date) -> PlanSnapshot? {
        snapshots.first { Calendar.current.isDate($0.date, inSameDayAs: workoutDate) && $0.date <= workoutDate }
    }

    func restore(_ restored: [PlanSnapshot]) {
        // Dedupe by calendar day, not just by id: a restored snapshot has its own
        // random UUID, so an id-only dedupe could leave two entries for the same
        // day (one captured live on-device, one from the backup) instead of
        // replacing it — captureIfNeeded's own dedupe assumes at most one per day.
        let calendar = Calendar.current
        let restoredDays = Set(restored.map { calendar.startOfDay(for: $0.date) })
        snapshots.removeAll { restoredDays.contains(calendar.startOfDay(for: $0.date)) }
        snapshots.append(contentsOf: restored)
        snapshots.sort { $0.date > $1.date }; persist()
    }

    func alignment(sessionTitle: String, snapshot: PlanSnapshot) -> String {
        let title = sessionTitle.lowercased()
        let actual: String
        if title.contains("carrera") || title.contains("running") { actual = "Carrera" }
        else if title.contains("fuerza") || title.contains("push") || title.contains("pull") || title.contains("pierna") { actual = "Fuerza" }
        else if title.contains("hiit") || title.contains("interval") { actual = "Calidad" }
        else { actual = sessionTitle }
        let planned = snapshot.recommendation
        let matches = (planned.contains("Carrera") && actual == "Carrera") ||
                      (planned.contains("Fuerza") && actual == "Fuerza") ||
                      (planned.contains("Calidad") && (actual == "Calidad" || actual == "Carrera"))
        if planned == PlannedSessionKind.recovery.rawValue { return "El plan proponía recuperación y realizaste \(actual.lowercased())." }
        return matches ? "La sesión coincide con el plan: \(planned)." : "El plan proponía \(planned.lowercased()) y realizaste \(actual.lowercased())."
    }

    private func persist() { try? JSONEncoder().encode(snapshots).write(to: storageURL, options: .atomic) }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL), let decoded = try? JSONDecoder().decode([PlanSnapshot].self, from: data) else { return }
        snapshots = decoded
    }
}
