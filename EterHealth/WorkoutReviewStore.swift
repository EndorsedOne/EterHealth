import Foundation

enum WorkoutOutcome: String, Codable, CaseIterable, Identifiable {
    case worse = "Peor de lo previsto"
    case asPlanned = "Según lo previsto"
    case better = "Mejor de lo previsto"
    var id: String { rawValue }
}

enum WorkoutPurpose: String, Codable, CaseIterable, Identifiable {
    case easy = "Suave / recuperación"
    case training = "Entrenamiento normal"
    case quality = "Sesión de calidad"
    case test = "Test"
    case race = "Competición"
    var id: String { rawValue }
}

struct WorkoutReview: Codable, Identifiable {
    var id: String { workoutID }
    let workoutID: String
    let workoutDate: Date
    var effort: Int
    var outcome: WorkoutOutcome
    var muscleFeeling: Int
    var repsInReserve: Int
    var pain: Bool
    var note: String
    var purpose: WorkoutPurpose?
    let recordedAt: Date
}

@MainActor
final class WorkoutReviewStore: ObservableObject {
    static let shared = WorkoutReviewStore()
    @Published private(set) var reviews: [WorkoutReview] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workout-reviews.json")
    }

    private init() { load() }

    func review(for workoutID: String) -> WorkoutReview? { reviews.first { $0.workoutID == workoutID } }
    func save(_ review: WorkoutReview) {
        reviews.removeAll { $0.workoutID == review.workoutID }
        reviews.append(review); reviews.sort { $0.workoutDate > $1.workoutDate }; persist()
    }
    func delete(workoutID: String) { reviews.removeAll { $0.workoutID == workoutID }; persist() }
    func restore(_ restored: [WorkoutReview]) { for review in restored { save(review) } }

    private func persist() { try? JSONEncoder().encode(reviews).write(to: storageURL, options: .atomic) }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([WorkoutReview].self, from: data) else { return }
        reviews = decoded
    }
}
