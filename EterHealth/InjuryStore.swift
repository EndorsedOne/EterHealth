import Foundation

enum TrainingRestriction: String, Codable, CaseIterable, Identifiable {
    case avoidRunning = "Evitar carrera"
    case avoidLowerBody = "Evitar tren inferior"
    case avoidUpperBody = "Evitar tren superior"
    case avoidStrength = "Evitar fuerza"
    var id: String { rawValue }
}

struct InjuryRecord: Codable, Identifiable {
    var id: UUID
    var area: String
    var startedAt: Date
    var resolvedAt: Date?
    var severity: Int
    var restrictions: Set<TrainingRestriction>
    var note: String

    var isActive: Bool { resolvedAt == nil }
}

@MainActor
final class InjuryStore: ObservableObject {
    static let shared = InjuryStore()
    @Published private(set) var records: [InjuryRecord] = []

    var active: [InjuryRecord] { records.filter(\.isActive).sorted { $0.startedAt > $1.startedAt } }

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("injury-history.json")
    }

    private init() { load() }

    func save(_ record: InjuryRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        records.sort { $0.startedAt > $1.startedAt }
        persist()
    }

    func delete(_ id: UUID) { records.removeAll { $0.id == id }; persist() }
    func restore(_ restored: [InjuryRecord]) { restored.forEach(save) }

    private func persist() { try? JSONEncoder().encode(records).write(to: storageURL, options: .atomic) }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([InjuryRecord].self, from: data) else { return }
        records = decoded
    }
}
