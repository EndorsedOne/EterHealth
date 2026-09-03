import Foundation

enum WorkoutMachine: String, Codable, CaseIterable, Identifiable {
    case technogymSkillrow = "Technogym Skillrow"
    case concept2 = "Concept2"
    case other = "Otra máquina"

    var id: String { rawValue }
}

enum RowingResistanceMode: String, Codable, CaseIterable, Identifiable {
    case aquaFeel = "AquaFeel"
    case power = "Power"
    case notRecorded = "Sin registrar"

    var id: String { rawValue }
}

/// Datos que Apple Salud no guarda en un HKWorkout. Permanecen enlazados al
/// UUID original: completan la sesión, pero nunca crean ni duplican otra.
struct WorkoutEnrichment: Codable, Identifiable, Equatable {
    var id: String { workoutID }
    let workoutID: String
    var workoutDate: Date
    var machine: WorkoutMachine
    var resistanceMode: RowingResistanceMode
    var resistanceLevel: Double?
    var distanceMeters: Double?
    var effectiveDurationSeconds: Double?
    var averagePowerWatts: Double?
    var cadenceSPM: Double?
    var perceivedEffort: Int?
    var useForHyrox: Bool
    var note: String
    var updatedAt: Date
}

@MainActor
final class WorkoutEnrichmentStore: ObservableObject {
    @Published private(set) var enrichments: [WorkoutEnrichment] = []
    private let url: URL

    init(filename: String = "workout-enrichments.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        url = documents.appendingPathComponent(filename)
        load()
    }

    func enrichment(for workoutID: UUID) -> WorkoutEnrichment? {
        enrichments.first { $0.workoutID == workoutID.uuidString }
    }

    func save(_ enrichment: WorkoutEnrichment) {
        if let index = enrichments.firstIndex(where: { $0.workoutID == enrichment.workoutID }) {
            enrichments[index] = enrichment
        } else {
            enrichments.append(enrichment)
        }
        persist()
    }

    func delete(workoutID: UUID) {
        enrichments.removeAll { $0.workoutID == workoutID.uuidString }
        persist()
    }

    func restore(_ values: [WorkoutEnrichment]) {
        for value in values { save(value) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.eter.decode([WorkoutEnrichment].self, from: data) else { return }
        enrichments = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.eter.encode(enrichments) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var eter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var eter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
