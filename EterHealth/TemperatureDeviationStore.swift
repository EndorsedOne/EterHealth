import Foundation

// The candidate causes named here aren't a fresh guess — they're exactly
// the ones PhysiologicalHealthView's own ExtendedSignal comment already
// lists as plausible drivers of a wrist-temperature swing (illness, a
// hard session, alcohol, room heat), plus two general catch-alls. A
// menstrual-cycle luteal-phase option was deliberately left out: this
// app's own lab regressions (testosterona, PSA) are the male reference
// panel, so offering a cycle-phase reason to this specific user would be
// inventing a cause that doesn't apply to him.
enum TemperatureDeviationReason: String, Codable, CaseIterable, Identifiable {
    case illness = "Enfermedad o malestar"
    case hardSession = "Sesión muy dura"
    case alcohol = "Alcohol"
    case heat = "Calor ambiental"
    case travel = "Viaje o cambio de horario"
    case stress = "Estrés o mal dormir"
    case unknown = "Otro / no lo sé"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .illness: return "cross.case.fill"
        case .hardSession: return "flame.fill"
        case .alcohol: return "wineglass"
        case .heat: return "thermometer.sun.fill"
        case .travel: return "airplane"
        case .stress: return "brain.head.profile"
        case .unknown: return "questionmark.circle"
        }
    }
}

// One entry per day a real wrist-temperature deviation was detected and
// (eventually) explained. `deviationC` is signed and stored at logging
// time even though the prompt fires only for a rise — kept general in
// case the significance test is ever loosened to flag a drop too.
struct TemperatureDeviationLog: Codable, Identifiable {
    let id: UUID
    var date: Date
    var deviationC: Double
    var reasons: Set<TemperatureDeviationReason>
    var note: String

    static func empty(date: Date, deviationC: Double) -> TemperatureDeviationLog {
        TemperatureDeviationLog(id: UUID(), date: date, deviationC: deviationC, reasons: [], note: "")
    }
}

@MainActor
final class TemperatureDeviationStore: ObservableObject {
    static let shared = TemperatureDeviationStore()
    @Published private(set) var logs: [TemperatureDeviationLog] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("temperature-deviation-logs.json")
    }

    private init() { load() }

    // Keyed by day, not by id, on purpose: only one explanation makes
    // sense per calendar day of wrist-temperature data, and re-answering
    // the same day's prompt should replace the earlier answer rather than
    // accumulate a second row for it.
    func existingLog(for date: Date) -> TemperatureDeviationLog? {
        let day = Calendar.current.startOfDay(for: date)
        return logs.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    func save(_ log: TemperatureDeviationLog) {
        let day = Calendar.current.startOfDay(for: log.date)
        var stored = log
        stored.date = day
        logs.removeAll { Calendar.current.isDate($0.date, inSameDayAs: day) }
        guard !stored.reasons.isEmpty || !stored.note.trimmingCharacters(in: .whitespaces).isEmpty else {
            persist(); return
        }
        logs.append(stored)
        logs.sort { $0.date > $1.date }
        persist()
    }

    func delete(for date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        logs.removeAll { Calendar.current.isDate($0.date, inSameDayAs: day) }
        persist()
    }

    func restore(_ restored: [TemperatureDeviationLog]) {
        let ids = Set(restored.map(\.id)); logs.removeAll { ids.contains($0.id) }; logs.append(contentsOf: restored)
        logs.sort { $0.date > $1.date }; persist()
    }

    private func persist() { try? JSONEncoder().encode(logs).write(to: storageURL, options: .atomic) }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TemperatureDeviationLog].self, from: data) else { return }
        logs = decoded.sorted { $0.date > $1.date }
    }
}
