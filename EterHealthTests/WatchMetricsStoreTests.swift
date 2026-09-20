import XCTest
@testable import EterHealth

/// Fija el contrato del payload `workoutContext` (iPhone → reloj). El reloj se
/// simplificó en 56e8f15: ya no pinta el recorrido serie a serie, así que ese
/// detalle no debe volver a viajar por WCSession. Este test evita que un
/// cambio futuro reintroduzca campos sin consumidor en el reloj.
final class WatchMetricsStoreTests: XCTestCase {

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
                              "workoutDate", "completedSets", "totalVolume", "restEndsAt"])
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
    }

    func testDescansoSoloCuandoLoHay() {
        XCTAssertNotNil(payload(restEndsAt: Date())["restEndsAt"])
        XCTAssertNil(payload(restEndsAt: nil)["restEndsAt"],
                     "Sin descanso activo, la clave no debe estar presente (no un 0 que el reloj interprete como temporizador).")
    }
}
