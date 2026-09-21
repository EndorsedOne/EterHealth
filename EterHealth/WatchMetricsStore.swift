import Foundation
import WatchConnectivity

private struct WatchMetricsPayload: Sendable {
    let heartRate: Double?
    let activeEnergy: Double?
    let elapsed: Double?
    let isRunning: Bool?
    let isPaused: Bool?
    let terminalAction: String?
    let terminalOutcome: String?
    let terminalWorkoutID: String?
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
        terminalOutcome = message["terminalOutcome"] as? String
        terminalWorkoutID = message["terminalWorkoutID"] as? String
        workoutCommand = message["workoutCommand"] as? String
        reviewEffort = message["reviewEffort"] as? Int
        reviewPain = message["reviewPain"] as? Bool
        reviewWorkoutID = message["reviewWorkoutID"] as? String
        reviewWorkoutDate = (message["reviewWorkoutDate"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

enum WatchTerminalOutcome: String, Sendable {
    case savedByWatch
    case noActiveSession
    case watchSaveFailed
    case expiredAndDiscarded
}

@MainActor
final class WatchMetricsStore: NSObject, ObservableObject {
    // Instancia única: es el delegado de WCSession y la fuente de métricas en
    // vivo. Tenerla como singleton permite que la sesión de fuerza haga las
    // llamadas imperativas (enviar contexto, finalizar, descartar) SIN
    // observar el objeto —y por tanto sin reconstruir toda la vista cada vez
    // que llega un pulso—, mientras la cabecera y el puente del reloj sí lo
    // observan para pintarse.
    static let shared = WatchMetricsStore()

    // Métricas de ALTA FRECUENCIA: deliberadamente NO @Published. Llegan cada
    // segundo mientras el reloj graba; si fueran @Published, cada recepción
    // emitiría objectWillChange y repintaría cualquier vista que observe el
    // store —incluida, por caminos indirectos, la lista de ejercicios— una vez
    // por segundo, congelando la sesión. La cabecera las lee a 1 Hz con su
    // propio TimelineView, sin depender de la observación del store.
    var heartRate = 0.0
    var activeEnergy = 0.0
    var elapsed = 0.0
    var lastReceived: Date?
    // Estado de BAJA frecuencia: sí @Published, pero en receive() sólo se
    // reasignan cuando cambian de verdad, para no emitir por segundo.
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var terminalAction: String?
    @Published var workoutCommand: String?
    private(set) var terminalOutcome: WatchTerminalOutcome?
    private(set) var terminalWorkoutID: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func receive(_ payload: WatchMetricsPayload) {
        // Campos no publicados: se asignan libremente, no repintan nada.
        heartRate = payload.heartRate ?? heartRate
        activeEnergy = payload.activeEnergy ?? activeEnergy
        elapsed = payload.elapsed ?? elapsed
        // Publicados: sólo se reasignan si cambian de verdad, para que
        // objectWillChange NO se dispare en cada recepción (evita el repintado
        // por segundo de la sesión).
        if let running = payload.isRunning, running != isRunning { isRunning = running }
        if let paused = payload.isPaused, paused != isPaused { isPaused = paused }
        if let action = payload.terminalAction { terminalAction = action }
        if let outcome = payload.terminalOutcome.flatMap(WatchTerminalOutcome.init(rawValue:)) {
            terminalOutcome = outcome
            terminalWorkoutID = payload.terminalWorkoutID
        }
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
    func finishAndAwait(workoutID: String, timeout: TimeInterval = 5) async -> WatchTerminalOutcome? {
        terminalOutcome = nil
        terminalWorkoutID = nil
        sendTerminal(command: "finish", workoutID: workoutID, fallbackAfter: 3)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if terminalWorkoutID == workoutID, let terminalOutcome { return terminalOutcome }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }
    func discard(workoutID: String) { sendTerminal(command: "discard", workoutID: workoutID) }

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
                           energy: Int, energyCurve: [Double], currentHour: Double,
                           caffeineCurve: [Double], caffeineNowMg: Double, caffeineBedtimeMg: Double,
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
            "energy": energy,
            "energyCurve": energyCurve,
            "currentHour": currentHour,
            "caffeineCurve": caffeineCurve,
            "caffeineNowMg": caffeineNowMg,
            "caffeineBedtimeMg": caffeineBedtimeMg,
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

    /// El reloj solo consume del contexto el descanso, el resumen (series
    /// completadas y volumen) y la identidad de la sesión. El recorrido serie
    /// a serie —ejercicio, peso, repeticiones— se retiró del reloj (56e8f15) y
    /// vive únicamente en el iPhone, así que el payload ya no lo transporta. Se
    /// construye con una función pura y probada para que ese contrato no vuelva
    /// a arrastrar campos sin consumidor.
    func updateWorkoutContext(routine: String, workoutID: String, workoutDate: Date,
                              completedSets: Int, totalVolume: Double, restEndsAt: Date?) {
        let payload = Self.workoutContextPayload(
            routine: routine, workoutID: workoutID, workoutDate: workoutDate,
            completedSets: completedSets, totalVolume: totalVolume, restEndsAt: restEndsAt
        )
        // Red de seguridad contra el envío por pulsación: si el contenido es
        // idéntico al último enviado, no se manda. La firma que dispara esto ya
        // sólo depende de lo que el reloj muestra (ver
        // LiveStrengthWorkoutView.workoutContextSignature); esto cubre a
        // cualquier otro llamante presente o futuro.
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

    /// Contrato del payload `workoutContext` (iPhone → reloj). Función pura para
    /// poder fijarlo en un test: solo descanso, resumen e identidad de sesión;
    /// nunca detalle de serie (ejercicio/peso/repeticiones), que el reloj ya no
    /// pinta.
    nonisolated static func workoutContextPayload(routine: String, workoutID: String, workoutDate: Date,
                                                  completedSets: Int, totalVolume: Double,
                                                  restEndsAt: Date?) -> [String: Any] {
        var payload: [String: Any] = [
            "payloadType": "workoutContext", "routineName": routine,
            "workoutID": workoutID, "workoutDate": workoutDate.timeIntervalSince1970,
            "completedSets": completedSets, "totalVolume": totalVolume
        ]
        if let restEndsAt { payload["restEndsAt"] = restEndsAt.timeIntervalSince1970 }
        return payload
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

    /// Finalizar o descartar no puede depender sólo de `isReachable`: puede
    /// cambiar justo cuando iOS presenta el resumen y desmonta la sesión. Se
    /// envía por el canal inmediato y también por la cola fiable. El reloj
    /// deduplica `commandID` y comprueba `workoutID`, por lo que una entrega
    /// tardía nunca puede cerrar el siguiente entrenamiento.
    private func sendTerminal(command: String, workoutID: String, fallbackAfter: TimeInterval? = nil) {
        var payload: [String: Any] = [
            "command": command,
            "commandID": UUID().uuidString,
            "workoutID": workoutID,
            "issuedAt": Date().timeIntervalSince1970
        ]
        if let fallbackAfter {
            payload["fallbackDeadline"] = Date().addingTimeInterval(fallbackAfter).timeIntervalSince1970
        }
        let session = WCSession.default
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
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
