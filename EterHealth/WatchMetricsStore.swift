import Foundation
import WatchConnectivity

private struct WatchMetricsPayload: Sendable {
    let heartRate: Double?
    let activeEnergy: Double?
    let elapsed: Double?
    let isRunning: Bool?
    let isPaused: Bool?
    let terminalAction: String?
    let workoutCommand: String?
    let reviewEffort: Int?
    let reviewPain: Bool?
    let reviewWorkoutID: String?
    let reviewWorkoutDate: Date?

    nonisolated init(_ message: [String: Any]) {
        heartRate = message["heartRate"] as? Double
        activeEnergy = message["activeEnergy"] as? Double
        elapsed = message["elapsed"] as? Double
        isRunning = message["running"] as? Bool
        isPaused = message["paused"] as? Bool
        terminalAction = message["terminalAction"] as? String
        workoutCommand = message["workoutCommand"] as? String
        reviewEffort = message["reviewEffort"] as? Int
        reviewPain = message["reviewPain"] as? Bool
        reviewWorkoutID = message["reviewWorkoutID"] as? String
        reviewWorkoutDate = (message["reviewWorkoutDate"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

@MainActor
final class WatchMetricsStore: NSObject, ObservableObject {
    @Published var heartRate = 0.0
    @Published var activeEnergy = 0.0
    @Published var elapsed = 0.0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var lastReceived: Date?
    @Published var terminalAction: String?
    @Published var workoutCommand: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func receive(_ payload: WatchMetricsPayload) {
        heartRate = payload.heartRate ?? heartRate
        activeEnergy = payload.activeEnergy ?? activeEnergy
        elapsed = payload.elapsed ?? elapsed
        isRunning = payload.isRunning ?? isRunning
        isPaused = payload.isPaused ?? isPaused
        if let action = payload.terminalAction { terminalAction = action }
        if let command = payload.workoutCommand { workoutCommand = command }
        if let effort = payload.reviewEffort,
           let pain = payload.reviewPain,
           let workoutID = payload.reviewWorkoutID,
           let workoutDate = payload.reviewWorkoutDate {
            WorkoutReviewStore.shared.save(WorkoutReview(
                workoutID: workoutID, workoutDate: workoutDate, effort: effort,
                outcome: .asPlanned, muscleFeeling: max(1, 11 - effort),
                repsInReserve: max(0, 10 - effort), pain: pain, note: "Registrado desde Apple Watch",
                purpose: .training, recordedAt: Date()
            ))
        }
        lastReceived = Date()
    }

    func clearTerminalAction() { terminalAction = nil }
    func clearWorkoutCommand() { workoutCommand = nil }

    func pause() { send(command: "pause") }
    func resume() { send(command: "resume") }
    func finish() { send(command: "finish") }
    func discard() { send(command: "discard") }

    func updateTwinSummary(readiness: Int, state: String, recommendation: String, reason: String,
                           activity: String, confidence: Int, maximumHeartRate: Int?,
                           hrv: Int, restingHeartRate: Int, sleepHours: Double,
                           updatedAt: Date = Date()) {
        let payload: [String: Any] = [
            "payloadType": "twinSummary",
            "readiness": readiness,
            "readinessState": state,
            "recommendation": recommendation,
            "recommendationReason": reason,
            "recommendedActivity": activity,
            "baselineConfidence": confidence,
            "hrv": hrv,
            "restingHeartRate": restingHeartRate,
            "sleepHours": sleepHours,
            "summaryUpdatedAt": updatedAt.timeIntervalSince1970
        ]
        var completedPayload = payload
        if let maximumHeartRate { completedPayload["maximumHeartRate"] = maximumHeartRate }
        let session = WCSession.default
        try? session.updateApplicationContext(completedPayload)
        if session.isReachable { session.sendMessage(completedPayload, replyHandler: nil) }
    }

    func updateWorkoutContext(routine: String, workoutID: String, workoutDate: Date,
                              exercise: String?, setNumber: Int, totalSets: Int,
                              weight: Double?, reps: Int?, completedSets: Int,
                              totalVolume: Double, restEndsAt: Date?) {
        var payload: [String: Any] = [
            "payloadType": "workoutContext", "routineName": routine,
            "workoutID": workoutID, "workoutDate": workoutDate.timeIntervalSince1970,
            "setNumber": setNumber, "totalSets": totalSets, "completedSets": completedSets,
            "totalVolume": totalVolume
        ]
        if let exercise { payload["exerciseName"] = exercise }
        if let weight { payload["setWeight"] = weight }
        if let reps { payload["setReps"] = reps }
        if let restEndsAt { payload["restEndsAt"] = restEndsAt.timeIntervalSince1970 }
        let session = WCSession.default
        if session.isReachable { session.sendMessage(payload, replyHandler: nil) }
        else { session.transferUserInfo(payload) }
    }

    private func send(command: String) {
        let payload: [String: Any] = ["command": command, "commandID": UUID().uuidString]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil)
        } else {
            WCSession.default.transferUserInfo(payload)
        }
    }
}

extension WatchMetricsStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let payload = WatchMetricsPayload(message)
        Task { @MainActor in receive(payload) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = WatchMetricsPayload(applicationContext)
        Task { @MainActor in receive(payload) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let payload = WatchMetricsPayload(userInfo)
        Task { @MainActor in receive(payload) }
    }
}
