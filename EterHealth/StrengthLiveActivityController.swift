import Foundation
import ActivityKit

struct StrengthLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exerciseName: String
        var setID: String
        var setNumber: Int
        var totalSets: Int
        var weight: Double
        var reps: Int
        var targetRIR: Double?
        var actualRIR: Int?
        var completedSets: Int
        var totalSetsInWorkout: Int
        var restSeconds: Int
        var restEndsAt: Date?
        var canCompleteSet: Bool
        var updatedAt: Date
    }

    let workoutID: String
    let routineName: String
    let startedAt: Date
}

struct StrengthLiveActivityCommand: Codable, Identifiable {
    enum Action: String, Codable { case completeSet, adjustRest, skipRest, adjustRIR }
    let id: UUID
    let issuedAt: Date
    let workoutID: String
    let setID: String?
    let action: Action
    let value: Int
}

enum StrengthLiveActivityCommandStore {
    static let suite = "group.com.angelmartinez.eterhealth"
    static let key = "eter.strength.live.commands.v1"

    static func pending(for workoutID: String) -> [StrengthLiveActivityCommand] {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key),
              let commands = try? JSONDecoder().decode([StrengthLiveActivityCommand].self, from: data) else { return [] }
        return commands.filter { $0.workoutID == workoutID }.sorted { $0.issuedAt < $1.issuedAt }
    }

    static func consume(_ ids: Set<UUID>) {
        guard !ids.isEmpty, let defaults = UserDefaults(suiteName: suite),
              let data = defaults.data(forKey: key),
              let commands = try? JSONDecoder().decode([StrengthLiveActivityCommand].self, from: data) else { return }
        let remaining = commands.filter { !ids.contains($0.id) }
        if let encoded = try? JSONEncoder().encode(remaining) { defaults.set(encoded, forKey: key) }
    }
}

@MainActor
final class StrengthLiveActivityController {
    static let shared = StrengthLiveActivityController()

    func start(workoutID: String, routineName: String, startedAt: Date,
               state: StrengthLiveActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Task.detached {
            if let existing = Activity<StrengthLiveActivityAttributes>.activities.first(where: { $0.attributes.workoutID == workoutID }) {
                await existing.update(ActivityContent(state: state, staleDate: state.restEndsAt))
                return
            }
            do {
                _ = try Activity.request(
                    attributes: StrengthLiveActivityAttributes(workoutID: workoutID, routineName: routineName, startedAt: startedAt),
                    content: ActivityContent(state: state, staleDate: state.restEndsAt),
                    pushType: nil
                )
            } catch {
                print("[éter/live] No se pudo iniciar la actividad: \(error.localizedDescription)")
            }
        }
    }

    func update(workoutID: String, state: StrengthLiveActivityAttributes.ContentState) {
        Task.detached {
            guard let activity = Activity<StrengthLiveActivityAttributes>.activities.first(where: { $0.attributes.workoutID == workoutID }) else { return }
            await activity.update(ActivityContent(state: state, staleDate: state.restEndsAt))
        }
    }

    func end(workoutID: String, finalState: StrengthLiveActivityAttributes.ContentState?, dismissedImmediately: Bool = true) {
        Task.detached {
            let activities = Activity<StrengthLiveActivityAttributes>.activities.filter { $0.attributes.workoutID == workoutID }
            for item in activities {
                let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
                await item.end(content, dismissalPolicy: dismissedImmediately ? .immediate : .default)
            }
        }
    }
}
