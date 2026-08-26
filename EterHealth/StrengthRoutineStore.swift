import Foundation

@MainActor
final class StrengthRoutineStore: ObservableObject {
    @Published private(set) var saved: [String: StrengthRoutine] = [:]

    private var storageURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("eter-strength-routines.json")
    }

    init() { load() }

    func routine(named name: String) -> StrengthRoutine? { saved[name] }

    func save(_ routine: StrengthRoutine) {
        saved[routine.name] = routine
        persist()
    }

    func restoreAutomatic(_ name: String) {
        saved.removeValue(forKey: name)
        persist()
    }

    func restore(_ restored: [String: StrengthRoutine]) { for (name, routine) in restored { saved[name] = routine }; persist() }

    private func persist() {
        try? JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: StrengthRoutine].self, from: data) else { return }
        saved = decoded
    }
}
