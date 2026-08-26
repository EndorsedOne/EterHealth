import Foundation

struct PlanSnapshot: Codable, Identifiable {
    let id: UUID
    let date: Date
    let recommendation: String
    let rationale: String
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
        snapshots.append(PlanSnapshot(id: UUID(), date: now, recommendation: plan.nextSession.rawValue, rationale: plan.rationale))
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
