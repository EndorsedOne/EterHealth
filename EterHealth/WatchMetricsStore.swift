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

    // Último resumen enviado, para reenviarlo cuando el reloj aparezca.
    private var lastTwinPayload: [String: Any]?
    /// Por qué no llegó el último envío. Visible para poder diagnosticar un
    /// reloj en "Esperando datos" sin adivinar.
    @Published private(set) var lastWatchSyncError: String?

    private func send(_ payload: [String: Any]) {
        let session = WCSession.default
        // `try?` a secas era el fallo silencioso que hizo esto difícil de
        // encontrar: updateApplicationContext LANZA si la sesión no está
        // activada todavía, o si el reloj no tiene la app instalada, y el
        // error se tiraba a la basura. Cada intento deja rastro.
        let diagnostic = "activation=\(session.activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable)"
        guard session.activationState == .activated else {
            lastWatchSyncError = "Sesión no activada todavía · \(diagnostic)"
            print("[éter/watch] envío descartado: \(lastWatchSyncError ?? "")")
            return
        }
        do {
            try session.updateApplicationContext(payload)
            lastWatchSyncError = nil
            print("[éter/watch] contexto enviado · \(diagnostic)")
        } catch {
            lastWatchSyncError = "\(error.localizedDescription) · \(diagnostic)"
            print("[éter/watch] updateApplicationContext falló: \(lastWatchSyncError ?? "")")
        }
        if session.isReachable { session.sendMessage(payload, replyHandler: nil) }
    }

    /// Reenvía el último resumen conocido. Si no hay ninguno todavía no se
    /// inventa uno: el iPhone lo produce en cuanto ContentView sincroniza.
    func resendLastSummary() {
        guard let lastTwinPayload else { return }
        send(lastTwinPayload)
    }

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
        // Se guarda para poder reenviarlo cuando el reloj aparezca: el
        // applicationContext persiste, pero sólo si ya se llegó a poner uno, y
        // un reloj que arranca después de que el iPhone enviara su último
        // contexto se quedaba en "Esperando datos" sin nada que pedirle.
        lastTwinPayload = completedPayload
        send(completedPayload)
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
        // Segunda red de seguridad contra el envío por pulsación: si el
        // contenido es idéntico al último enviado, no se manda. La primera es
        // que la firma que dispara esto ya sólo depende de lo que el reloj
        // muestra (ver LiveStrengthWorkoutView.workoutContextSignature); esto
        // cubre a cualquier otro llamante presente o futuro.
        //
        // Importa sobre todo con el reloj NO alcanzable: ahí cada envío es un
        // `transferUserInfo`, que se encola en disco y se entrega más tarde.
        // Un mensaje por tecla llenaba esa cola de estados intermedios que
        // nadie iba a leer nunca.
        let signature = payload.keys.sorted().map { "\($0)=\(payload[$0] ?? "")" }.joined(separator: "&")
        guard signature != lastWorkoutContextSignature else { return }
        lastWorkoutContextSignature = signature
        let session = WCSession.default
        if session.isReachable { session.sendMessage(payload, replyHandler: nil) }
        else { session.transferUserInfo(payload) }
    }

    private var lastWorkoutContextSignature: String?

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
    // Estaba vacío: al activarse la sesión —lo que ocurre cuando el reloj
    // abre la app— el iPhone no enviaba nada, así que el reloj esperaba un
    // cambio en el iPhone que podía no llegar nunca.
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard error == nil, activationState == .activated else { return }
        Task { @MainActor in resendLastSummary() }
    }
    // Y no existía en absoluto: el reloj pasa a alcanzable justo al abrir su
    // app, que es exactamente el momento en que necesita el resumen.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in resendLastSummary() }
    }
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
