import XCTest
@testable import EterHealth

/// Fija el contrato del payload `workoutContext` (iPhone → reloj). El reloj se
/// simplificó en 56e8f15: ya no pinta el recorrido serie a serie, así que ese
/// detalle no debe volver a viajar por WCSession. Este test evita que un
/// cambio futuro reintroduzca campos sin consumidor en el reloj.
final class WatchMetricsStoreTests: XCTestCase {

    func testPostSessionClosureDoesNotInventMissingEvidence() {
        XCTAssertNil(PostSessionClosure.strength([:]))
        XCTAssertNil(PostSessionClosure.cardio(verdict: .init(isQuality: false, basis: .insufficient)))
        XCTAssertNil(PostSessionClosure.cardio(verdict: .init(isQuality: true, basis: .legacyCalories)))
    }

    func testPostSessionClosureUsesEffectiveStimulusAndQuality() {
        let strength = PostSessionClosure.strength(["Pecho": 3.5, "Core": 1])
        XCTAssertTrue(strength?.counted.contains("Pecho") == true)
        let intervals = PostSessionClosure.cardio(verdict: .init(isQuality: true, basis: .detectedStructure))
        XCTAssertTrue(intervals?.counted.contains("Intervalos") == true)
        XCTAssertTrue(intervals?.tomorrow.contains("recuperación") == true)
    }

    private func payload(restEndsAt: Date? = Date(timeIntervalSince1970: 1_000)) -> [String: Any] {
        WatchMetricsStore.workoutContextPayload(
            routine: "Empuje A",
            workoutID: "Empuje A|123",
            workoutDate: Date(timeIntervalSince1970: 123),
            completedSets: 4,
            totalVolume: 1_250,
            restEndsAt: restEndsAt
        )
    }

    func testCarriesOnlyWhatTheWatchConsumes() {
        let keys = Set(payload().keys)
        XCTAssertEqual(keys, ["payloadType", "routineName", "workoutID",
                              "workoutDate", "completedSets", "totalVolume", "restEndsAt",
                              "contextIssuedAt", "workoutContextID"])
    }

    func testNeverCarriesPerSetDetail() {
        let keys = Set(payload().keys)
        for forbidden in ["exerciseName", "setNumber", "totalSets", "setWeight", "setReps"] {
            XCTAssertFalse(keys.contains(forbidden),
                           "El contexto de entrenamiento no debe transportar '\(forbidden)': el reloj ya no pinta el recorrido serie a serie (56e8f15).")
        }
    }

    func testResumenEIdentidadLleganAlReloj() {
        let p = payload()
        XCTAssertEqual(p["payloadType"] as? String, "workoutContext")
        XCTAssertEqual(p["completedSets"] as? Int, 4)
        XCTAssertEqual(p["totalVolume"] as? Double, 1_250)
        XCTAssertEqual(p["workoutID"] as? String, "Empuje A|123")
        XCTAssertNotNil(p["workoutContextID"] as? String)
    }

    func testDescansoSoloCuandoLoHay() {
        XCTAssertNotNil(payload(restEndsAt: Date())["restEndsAt"])
        XCTAssertNil(payload(restEndsAt: nil)["restEndsAt"],
                     "Sin descanso activo, la clave no debe estar presente (no un 0 que el reloj interprete como temporizador).")
    }

    func testTerminalCommandCarriesIdentityWithoutDiscardDeadline() {
        let issuedAt = Date(timeIntervalSince1970: 10_000)
        let payload = WatchMetricsStore.terminalCommandPayload(
            command: "finish", workoutID: "Empuje A|123",
            issuedAt: issuedAt
        )

        XCTAssertEqual(payload["command"] as? String, "finish")
        XCTAssertEqual(payload["workoutID"] as? String, "Empuje A|123")
        XCTAssertEqual(payload["issuedAt"] as? Double, 10_000)
        XCTAssertNil(payload["fallbackDeadline"],
                     "El timeout del iPhone nunca debe ordenar al Watch descartar un builder válido.")
        XCTAssertNotNil(payload["commandID"] as? String)
    }

    func testTerminalCommandWithoutFallbackHasNoDeadline() {
        let payload = WatchMetricsStore.terminalCommandPayload(
            command: "discard", workoutID: "Empuje A|123",
            issuedAt: Date(timeIntervalSince1970: 10_000)
        )
        XCTAssertNil(payload["fallbackDeadline"])
    }

    func testPhoneDoesNotWriteHealthKitAfterAmbiguousWatchTimeout() {
        XCTAssertFalse(WatchMetricsStore.shouldSaveStrengthWorkoutOnPhone(
            outcome: nil, observedRunningWatchSession: true
        ))
        XCTAssertTrue(WatchMetricsStore.shouldSaveStrengthWorkoutOnPhone(
            outcome: nil, observedRunningWatchSession: false
        ))
    }

    func testPhoneOnlyFallsBackAfterDefinitiveWatchFailure() {
        XCTAssertFalse(WatchMetricsStore.shouldSaveStrengthWorkoutOnPhone(
            outcome: .savedByWatch, observedRunningWatchSession: true
        ))
        XCTAssertTrue(WatchMetricsStore.shouldSaveStrengthWorkoutOnPhone(
            outcome: .noActiveSession, observedRunningWatchSession: true
        ))
        XCTAssertTrue(WatchMetricsStore.shouldSaveStrengthWorkoutOnPhone(
            outcome: .watchSaveFailed, observedRunningWatchSession: true
        ))
    }

    func testWatchConnectivityErrorCallbacksRunOffMainActor() async {
        let error = NSError(domain: "WatchMetricsStoreTests", code: 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                WatchMetricsStore.logWorkoutContextDeliveryError(error)
                WatchMetricsStore.logTerminalDeliveryError(error)
                continuation.resume()
            }
        }
    }
}
