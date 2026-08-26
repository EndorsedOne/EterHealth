import Foundation
import Combine
import HealthKit
import WatchConnectivity

private struct WatchTwinPayload: Sendable {
    let readiness: Int?
    let state: String?
    let recommendation: String?
    let reason: String?
    let activity: String?
    let confidence: Int?
    let updatedAt: Date?
    let maximumHeartRate: Int?
    let hrv: Int?
    let restingHeartRate: Int?
    let sleepHours: Double?

    nonisolated init(_ message: [String: Any]) {
        readiness = message["readiness"] as? Int
        state = message["readinessState"] as? String
        recommendation = message["recommendation"] as? String
        reason = message["recommendationReason"] as? String
        activity = message["recommendedActivity"] as? String
        confidence = message["baselineConfidence"] as? Int
        updatedAt = (message["summaryUpdatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        maximumHeartRate = message["maximumHeartRate"] as? Int
        hrv = message["hrv"] as? Int
        restingHeartRate = message["restingHeartRate"] as? Int
        sleepHours = message["sleepHours"] as? Double
    }
}

private struct WatchActivePayload: Sendable {
    let routine: String?
    let exercise: String?
    let setNumber: Int?
    let totalSets: Int?
    let weight: Double?
    let reps: Int?
    let completedSets: Int?
    let restEndsAt: Date?
    let workoutID: String?
    let workoutDate: Date?
    let totalVolume: Double?

    nonisolated init(_ message: [String: Any]) {
        routine = message["routineName"] as? String
        exercise = message["exerciseName"] as? String
        setNumber = message["setNumber"] as? Int
        totalSets = message["totalSets"] as? Int
        weight = message["setWeight"] as? Double
        reps = message["setReps"] as? Int
        completedSets = message["completedSets"] as? Int
        restEndsAt = (message["restEndsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        workoutID = message["workoutID"] as? String
        workoutDate = (message["workoutDate"] as? Double).map(Date.init(timeIntervalSince1970:))
        totalVolume = message["totalVolume"] as? Double
    }
}

struct WatchWorkoutSummary: Sendable {
    let workoutID: String?
    let workoutDate: Date
    let routine: String
    let duration: TimeInterval
    let energy: Double
    let averageHeartRate: Double
    let maximumHeartRate: Double
    let zoneSeconds: [Int]
    let completedSets: Int
    let totalVolume: Double
}

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    static let shared = WatchWorkoutManager()
    @Published var heartRate = 0.0
    @Published var activeEnergy = 0.0
    @Published var elapsed = 0.0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var errorMessage: String?
    @Published var readiness: Int?
    @Published var readinessState = "Esperando datos"
    @Published var recommendation = "Entrenamiento de fuerza"
    @Published var recommendationReason = "Abre Éter en el iPhone para sincronizar el estado del gemelo."
    @Published var recommendedActivity = "strength"
    @Published var baselineConfidence = 0
    @Published var summaryUpdatedAt: Date?
    @Published var connectionState = "Conectando"
    @Published var phoneReachable = false
    @Published var maximumHeartRate: Int?
    @Published var hrv: Int?
    @Published var restingHeartRate: Int?
    @Published var sleepHours: Double?
    @Published var routineName = "Entrenamiento"
    @Published var exerciseName: String?
    @Published var setNumber = 0
    @Published var totalSets = 0
    @Published var setWeight: Double?
    @Published var setReps: Int?
    @Published var completedSets = 0
    @Published var restEndsAt: Date?
    // When the CURRENT rest window actually started — distinct from
    // restEndsAt, and deliberately NOT reset on every phone re-sync: a
    // ±15s adjustment changes restEndsAt but is still the same rest
    // period, so the progress bar should keep growing from where it was,
    // not snap back to empty. Only reset when a genuinely new rest window
    // begins (the previous one was inactive/expired).
    @Published private(set) var restStartedAt: Date?
    @Published var totalVolume = 0.0
    @Published var completedSummary: WatchWorkoutSummary?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var timer: Timer?
    private var startedAt: Date?
    private var workoutID: String?
    private var workoutDate: Date?
    private var heartRateSum = 0.0
    private var heartRateSamples = 0
    private var peakHeartRate = 0.0
    private var zoneSeconds = Array(repeating: 0, count: 5)

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType(), energy], read: [heartRate, energy])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func start(configuration suppliedConfiguration: HKWorkoutConfiguration? = nil) async {
        guard !isRunning, await requestAuthorization() else { return }
        heartRate = 0
        activeEnergy = 0
        elapsed = 0
        completedSummary = nil
        heartRateSum = 0
        heartRateSamples = 0
        peakHeartRate = 0
        zoneSeconds = Array(repeating: 0, count: 5)
        errorMessage = nil
        let configuration = suppliedConfiguration ?? HKWorkoutConfiguration()
        if suppliedConfiguration == nil {
            configuration.activityType = .traditionalStrengthTraining
            configuration.locationType = .indoor
        }
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let start = Date()
            startedAt = start
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            isRunning = true
            isPaused = false
            startTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startRecommendation() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        await start(configuration: configuration)
    }

    func togglePause() {
        guard let session else { return }
        if isPaused { session.resume() } else { session.pause() }
    }

    func finish() async {
        guard let session, let builder else { return }
        let end = Date()
        let summary = WatchWorkoutSummary(
            workoutID: workoutID, workoutDate: workoutDate ?? startedAt ?? end,
            routine: routineName, duration: elapsed, energy: activeEnergy,
            averageHeartRate: heartRateSamples > 0 ? heartRateSum / Double(heartRateSamples) : 0,
            maximumHeartRate: peakHeartRate, zoneSeconds: zoneSeconds,
            completedSets: completedSets, totalVolume: totalVolume
        )
        session.end()
        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            errorMessage = error.localizedDescription
        }
        timer?.invalidate()
        timer = nil
        isRunning = false
        isPaused = false
        sendMetrics(terminalAction: "finish")
        completedSummary = summary
        self.session = nil
        self.builder = nil
        startedAt = nil
    }

    func saveReview(effort: Int, pain: Bool) {
        guard let summary = completedSummary else { return }
        if let workoutID = summary.workoutID {
            let payload: [String: Any] = [
                "reviewEffort": effort, "reviewPain": pain,
                "reviewWorkoutID": workoutID,
                "reviewWorkoutDate": summary.workoutDate.timeIntervalSince1970
            ]
            let connection = WCSession.default
            if connection.isReachable { connection.sendMessage(payload, replyHandler: nil) }
            else { connection.transferUserInfo(payload) }
        }
        completedSummary = nil
    }

    func dismissSummary() { completedSummary = nil }

    func discard() {
        guard let session, let builder else { return }
        session.end()
        builder.discardWorkout()
        timer?.invalidate()
        timer = nil
        isRunning = false
        isPaused = false
        sendMetrics(terminalAction: "discard")
        self.session = nil
        self.builder = nil
        startedAt = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateElapsedTime), userInfo: nil, repeats: true)
    }

    @objc private func updateElapsedTime() {
        guard let startedAt, isRunning else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if !isPaused && heartRate > 0 {
            heartRateSum += heartRate
            heartRateSamples += 1
            peakHeartRate = max(peakHeartRate, heartRate)
            zoneSeconds[currentHeartZone - 1] += 1
        }
        sendMetrics()
    }

    private var currentHeartZone: Int {
        let maximum = Double(maximumHeartRate ?? max(170, Int(heartRate.rounded()) + 5))
        let fraction = heartRate / max(1, maximum)
        return fraction < 0.60 ? 1 : fraction < 0.70 ? 2 : fraction < 0.80 ? 3 : fraction < 0.90 ? 4 : 5
    }

    private func update(_ statistics: HKStatistics?) {
        guard let statistics else { return }
        switch statistics.quantityType.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            heartRate = statistics.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) ?? heartRate
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            activeEnergy = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? activeEnergy
        default: break
        }
        sendMetrics()
    }

    private func sendMetrics(terminalAction: String? = nil) {
        var payload: [String: Any] = ["heartRate": heartRate, "activeEnergy": activeEnergy, "elapsed": elapsed, "running": isRunning, "paused": isPaused]
        if let terminalAction { payload["terminalAction"] = terminalAction }
        let connection = WCSession.default
        if connection.isReachable {
            connection.sendMessage(payload, replyHandler: nil)
        } else if terminalAction != nil {
            // Terminal actions must survive a temporary iPhone/Watch disconnect.
            connection.transferUserInfo(payload)
        }
        try? connection.updateApplicationContext(payload)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            isPaused = toState == .paused
            isRunning = toState == .running || toState == .paused
            sendMetrics()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in errorMessage = error.localizedDescription }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            for type in collectedTypes.compactMap({ $0 as? HKQuantityType }) {
                update(workoutBuilder.statistics(for: type))
            }
        }
    }
}

extension WatchWorkoutManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            phoneReachable = session.isReachable
            connectionState = error == nil && activationState == .activated ? "Sincronizado" : "Sin conexión"
            if let error { errorMessage = error.localizedDescription }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            phoneReachable = reachable
            connectionState = reachable ? "iPhone conectado" : "Datos guardados"
        }
    }

    nonisolated private func receive(_ message: [String: Any]) {
        if message["payloadType"] as? String == "workoutContext" {
            let payload = WatchActivePayload(message)
            Task { @MainActor in apply(payload) }
        } else if message["payloadType"] as? String == "twinSummary" || message["readiness"] != nil {
            let payload = WatchTwinPayload(message)
            Task { @MainActor in apply(payload) }
        } else {
            receiveCommand(message)
        }
    }

    private func apply(_ payload: WatchTwinPayload) {
        readiness = payload.readiness ?? readiness
        readinessState = payload.state ?? readinessState
        recommendation = payload.recommendation ?? recommendation
        recommendationReason = payload.reason ?? recommendationReason
        recommendedActivity = payload.activity ?? recommendedActivity
        baselineConfidence = payload.confidence ?? baselineConfidence
        summaryUpdatedAt = payload.updatedAt ?? summaryUpdatedAt
        maximumHeartRate = payload.maximumHeartRate ?? maximumHeartRate
        hrv = payload.hrv ?? hrv
        restingHeartRate = payload.restingHeartRate ?? restingHeartRate
        sleepHours = payload.sleepHours ?? sleepHours
        connectionState = "Sincronizado"
    }

    private func apply(_ payload: WatchActivePayload) {
        routineName = payload.routine ?? routineName
        exerciseName = payload.exercise
        setNumber = payload.setNumber ?? setNumber
        totalSets = payload.totalSets ?? totalSets
        setWeight = payload.weight
        setReps = payload.reps
        completedSets = payload.completedSets ?? completedSets
        let now = Date()
        let wasResting = restEndsAt.map { $0 > now } ?? false
        let willRest = payload.restEndsAt.map { $0 > now } ?? false
        if willRest && !wasResting { restStartedAt = now }
        else if !willRest { restStartedAt = nil }
        restEndsAt = payload.restEndsAt
        workoutID = payload.workoutID ?? workoutID
        workoutDate = payload.workoutDate ?? workoutDate
        totalVolume = payload.totalVolume ?? totalVolume
    }

    func completeSetOnPhone() {
        sendPhoneCommand("completeSet")
    }

    func skipRestOnPhone() {
        sendPhoneCommand("skipRest")
    }

    // Positive to add time, negative to subtract — mirrors Hevy's own
    // -15s/+15s rest-adjust buttons. Sent to the phone (the source of
    // truth for restEndsAt) rather than applied locally, so both devices
    // keep showing the same countdown instead of quietly drifting apart.
    func adjustRestOnPhone(seconds: Int) {
        sendPhoneCommand("restAdjust:\(seconds)")
    }

    private func sendPhoneCommand(_ command: String) {
        let payload: [String: Any] = ["workoutCommand": command, "commandID": UUID().uuidString]
        let connection = WCSession.default
        guard connection.isReachable else {
            errorMessage = "Abre Éter en el iPhone para completar la serie desde el reloj."
            return
        }
        connection.sendMessage(payload, replyHandler: nil)
    }

    nonisolated private func receiveCommand(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        Task { @MainActor in
            switch command {
            case "pause" where !isPaused: togglePause()
            case "resume" where isPaused: togglePause()
            case "finish": await finish()
            case "discard": discard()
            default: break
            }
        }
    }
}
