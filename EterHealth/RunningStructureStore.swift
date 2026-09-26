import Foundation

/// Conocimiento derivado de las series originales de HealthKit. Éter conserva
/// la conclusión compacta, nunca duplica la traza cruda de pulso/velocidad.
struct RunningStructureKnowledge: Codable, Identifiable, Equatable {
    var id: UUID { workoutID }
    let workoutID: UUID
    let workoutEndDate: Date
    let analyzedAt: Date
    let detectorVersion: Int
    let structure: RunningSessionStructure?
}

@MainActor
final class RunningStructureStore {
    static let shared = RunningStructureStore()
    static let currentDetectorVersion = 1

    private(set) var records: [RunningStructureKnowledge] = []
    private let url: URL

    init(filename: String = "running-structure-knowledge.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        url = documents.appendingPathComponent(filename)
        load()
    }

    /// Positive knowledge is permanent for an immutable HKWorkout. A negative
    /// result is retried after one day because HealthKit can finish syncing its
    /// quantity series after the workout container itself first appears.
    func structure(for workoutID: UUID, endDate: Date, now: Date = Date()) -> RunningSessionStructure?? {
        guard let record = records.first(where: { $0.workoutID == workoutID }),
              record.workoutEndDate == endDate,
              record.detectorVersion == Self.currentDetectorVersion else { return nil }
        if record.structure == nil, now.timeIntervalSince(record.analyzedAt) >= 24 * 3_600 { return nil }
        return .some(record.structure)
    }

    func save(workoutID: UUID, endDate: Date, structure: RunningSessionStructure?, analyzedAt: Date = Date()) {
        let value = RunningStructureKnowledge(
            workoutID: workoutID, workoutEndDate: endDate, analyzedAt: analyzedAt,
            detectorVersion: Self.currentDetectorVersion, structure: structure
        )
        records.removeAll { $0.workoutID == workoutID }
        records.append(value)
        persist()
    }

    func restore(_ values: [RunningStructureKnowledge]) {
        for value in values {
            guard let existing = records.first(where: { $0.workoutID == value.workoutID }) else {
                records.append(value)
                continue
            }
            if value.detectorVersion > existing.detectorVersion
                || (value.detectorVersion == existing.detectorVersion && value.analyzedAt > existing.analyzedAt) {
                records.removeAll { $0.workoutID == value.workoutID }
                records.append(value)
            }
        }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([RunningStructureKnowledge].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
