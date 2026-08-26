import Foundation

struct DailyCheckIn: Codable, Identifiable {
    var id: Date { day }
    let day: Date
    var energy: Int
    var fatigue: Int
    var stress: Int
    var motivation: Int
    var sleepFeeling: Int
    var soreness: [String: Int]
    var painAreas: [String]
    var illness: Bool
    var note: String
    let createdAt: Date

    static func empty(for date: Date = Date()) -> DailyCheckIn {
        DailyCheckIn(
            day: Calendar.current.startOfDay(for: date), energy: 3, fatigue: 3,
            stress: 3, motivation: 3, sleepFeeling: 3, soreness: [:],
            painAreas: [], illness: false, note: "", createdAt: Date()
        )
    }
}

@MainActor
final class DailyCheckInStore: ObservableObject {
    @Published private(set) var entries: [DailyCheckIn] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daily-check-ins.json")
    }

    init() { load() }

    func entry(for date: Date = Date()) -> DailyCheckIn? {
        let day = Calendar.current.startOfDay(for: date)
        return entries.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    func save(_ entry: DailyCheckIn) {
        entries.removeAll { Calendar.current.isDate($0.day, inSameDayAs: entry.day) }
        entries.append(entry)
        entries.sort { $0.day > $1.day }
        persist()
    }

    func delete(for date: Date) {
        entries.removeAll { Calendar.current.isDate($0.day, inSameDayAs: date) }
        persist()
    }

    func restore(_ restored: [DailyCheckIn]) { for entry in restored { save(entry) } }

    private func persist() {
        try? JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([DailyCheckIn].self, from: data) else { return }
        entries = decoded
    }
}
