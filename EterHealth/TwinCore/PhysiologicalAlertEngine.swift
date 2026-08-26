import Foundation

enum PhysiologicalAlertSeverity: Int, Equatable {
    case observe = 1
    case caution = 2
    case recover = 3
}

struct PhysiologicalAlertSignal: Equatable {
    let name: String
    let value: String
    /// A negative z-score means worse than the user's personal baseline.
    let favorableDeviation: Double
    let confidence: Int
    let measuredAt: Date?
    /// Temperature can corroborate other signals but cannot trigger an alert by itself.
    var corroboratingOnly: Bool = false
}

struct PhysiologicalAlert: Equatable {
    let severity: PhysiologicalAlertSeverity
    let title: String
    let summary: String
    let action: String
    let signals: [PhysiologicalAlertSignal]
    let confidence: ConfidenceAssessment
}

enum PhysiologicalAlertEngine {
    nonisolated static func evaluate(
        signals: [PhysiologicalAlertSignal], illness: Bool,
        hasCheckIn: Bool, now: Date = Date()
    ) -> PhysiologicalAlert? {
        let current = signals.filter { signal in
            guard signal.confidence >= 40, let measuredAt = signal.measuredAt else { return false }
            return now.timeIntervalSince(measuredAt) >= -300 && now.timeIntervalSince(measuredAt) <= 48 * 3_600
        }
        let adverse = current.filter { $0.favorableDeviation <= -1.0 }
            .sorted { $0.favorableDeviation < $1.favorableDeviation }
        let primaryAdverse = adverse.filter { !$0.corroboratingOnly }
        let strong = primaryAdverse.filter { $0.favorableDeviation <= -1.75 }

        // Wrist temperature is deliberately corroborative: without symptoms or another
        // adverse personal signal it remains visible in Health, but raises no alert.
        guard illness || !strong.isEmpty || (primaryAdverse.count >= 1 && adverse.count >= 2) else { return nil }

        let severity: PhysiologicalAlertSeverity
        if illness || strong.count >= 2 || (primaryAdverse.count >= 2 && adverse.count >= 3) { severity = .recover }
        else if primaryAdverse.count >= 1 && adverse.count >= 2 { severity = .caution }
        else { severity = .observe }

        let selected = Array(adverse.prefix(3))
        let confidence = ConfidenceEngine.physiologicalAlert(
            signalConfidences: selected.map(\.confidence), hasCheckIn: hasCheckIn
        )
        let names = selected.map(\.name)
        let summary: String
        if illness {
            summary = selected.isEmpty
                ? "Has declarado síntomas. Hoy las sensaciones pesan más que cualquier marcador aislado."
                : "Los síntomas coinciden con cambios en \(joined(names))."
        } else if selected.count >= 2 {
            summary = "\(joined(names)) se apartan a la vez de tu rango personal reciente."
        } else {
            summary = "\(names.first ?? "Una señal") está muy fuera de tu rango personal, pero aún es una lectura aislada."
        }

        let title: String
        let action: String
        switch severity {
        case .recover:
            title = "Prioriza recuperación"
            action = illness
                ? "Evita entrenar con intensidad. Descansa, hidrátate y reevalúa mañana; si los síntomas preocupan o persisten, consulta a un profesional."
                : "No añadas intensidad hoy. Favorece sueño, hidratación y carga muy suave; confirma las señales en Apple Salud mañana."
        case .caution:
            title = "Modera la carga hoy"
            action = "Cambia intensidad por trabajo fácil o fuerza no fatigante y vuelve a comprobar tus señales mañana."
        case .observe:
            title = "Confirma esta señal"
            action = "No concluyas nada por una sola lectura. Revisa el dato en Apple Salud y usa tus sensaciones para decidir la intensidad."
        }

        return PhysiologicalAlert(
            severity: severity, title: title, summary: summary, action: action,
            signals: selected, confidence: confidence
        )
    }

    @MainActor static func evaluate(profile: PersonalBaselineProfile, checkIn: DailyCheckIn?, now: Date = Date()) -> PhysiologicalAlert? {
        evaluate(
            signals: [
                signal(profile.hrv, unit: "ms"),
                signal(profile.restingHeartRate, unit: "ppm"),
                signal(profile.sleep, unit: "h", decimals: 1),
                temperatureSignal(profile.wristTemperature),
                // Unlike wrist temperature, an elevated overnight respiratory
                // rate isn't treated as corroborating-only — it's specific
                // enough on its own (less confounded by room temperature,
                // sleep position, or cycle phase) to count as a primary
                // adverse signal, same tier as HRV/pulse/sleep.
                signal(profile.respiratoryRate, unit: "resp/min", decimals: 1)
            ].compactMap { $0 },
            illness: checkIn?.illness == true, hasCheckIn: checkIn != nil, now: now
        )
    }

    private nonisolated static func temperatureSignal(_ metric: PersonalMetricBaseline) -> PhysiologicalAlertSignal? {
        guard let current = metric.current, let deviation = metric.deviation,
              deviation < 0 else { return nil }
        return PhysiologicalAlertSignal(
            name: metric.name,
            value: current.formatted(.number.precision(.fractionLength(1))) + " °C",
            favorableDeviation: deviation, confidence: metric.confidence,
            measuredAt: metric.measuredAt, corroboratingOnly: true
        )
    }

    private nonisolated static func signal(_ metric: PersonalMetricBaseline, unit: String, decimals: Int = 0) -> PhysiologicalAlertSignal? {
        guard let current = metric.current, let deviation = metric.deviation else { return nil }
        let value = current.formatted(.number.precision(.fractionLength(decimals))) + " " + unit
        return PhysiologicalAlertSignal(
            name: metric.name, value: value, favorableDeviation: deviation,
            confidence: metric.confidence, measuredAt: metric.measuredAt
        )
    }

    private nonisolated static func joined(_ values: [String]) -> String {
        guard values.count > 1 else { return values.first ?? "tus señales" }
        return values.dropLast().joined(separator: ", ") + " y " + (values.last ?? "")
    }
}
