import Foundation

// PR15. Un techo de intensidad sobre la sesión que status() YA ha decidido.
//
// Esto no es un décimo gate. Los nueve gates de status() deciden QUÉ sesión
// toca; esto sólo puede rebajarla, y generaliza el bloque que ya existía para
// la alerta fisiológica `.caution`:
//
//     if physiologicalAlert?.severity == .caution,
//        [.qualityRun, .longRun, .hybrid, .brick].contains(next) { next = .easyRun }
//
// El brief de viajes pide exactamente esa semántica —"limitar intensidad sólo
// cuando el estado de viaje y las señales lo justifican", "no bloquear de
// forma ciega", "evitar HIIT, híbrido largo, test o máxima fuerza en las fases
// de mayor riesgo"— así que la respuesta correcta era generalizar el mecanismo
// existente y no montar uno paralelo que pudiera contradecirlo.
//
// DOS REGLAS QUE NO SE NEGOCIAN, y el porqué:
//
//  1. El viaje NUNCA produce el tier duro (mandar a `.recovery` por encima
//     del calendario). En status() el gate 1 (illness / readiness < 42 /
//     alerta `.recover`) va ANTES del gate 2 (`eventToday` → `.raceDay`), así
//     que un override duro por viaje CANCELARÍA la carrera a la que has
//     volado. Sólo una desviación medida puede anular el calendario; haber
//     cogido un avión, no. Por eso `.raceDay` no aparece en ningún conjunto
//     de excluidos.
//  2. La fuerza no se sustituye por otra sesión, se rebaja. El tier
//     `.caution` deja la fuerza en paz a propósito (su propio factor de carga
//     por readiness ya modera la intensidad), y para "evitar máxima fuerza"
//     ya existe la vía: `capsStrengthIntensity` lleva la prescripción al RIR
//     3–4 de la descarga en vez de al 2–3 habitual. Cambiar el kind aquí
//     sería quitarle al atleta la sesión que sí puede hacer.
struct SessionIntensityCeiling: Equatable {
    /// Los kinds que hoy no pueden proponerse.
    let excluded: Set<PlannedSessionKind>
    /// A qué se sustituye uno excluido. Siempre un estímulo real y ligero, no
    /// recuperación: el brief pide explícitamente permitir una sesión ligera
    /// si las señales son buenas.
    let substitute: PlannedSessionKind
    /// La fuerza se mantiene pero con margen: RIR 3–4 en vez de 2–3.
    let capsStrengthIntensity: Bool
    /// Los motivos CONCRETOS, ya enumerados. "vuelo nocturno + sueño 5.2 h +
    /// HRV bajo tu banda", no "porque has viajado".
    let reasons: [String]

    func excludes(_ kind: PlannedSessionKind) -> Bool { excluded.contains(kind) }

    var explanation: String {
        guard !reasons.isEmpty else { return "" }
        return reasons.joined(separator: " + ")
    }

    /// Une dos techos quedándose con el más restrictivo de cada cosa. Existe
    /// porque una alerta `.caution` y un viaje pueden coincidir, y en ese caso
    /// el atleta tiene que ver los dos motivos, no el primero que se compruebe.
    static func merged(_ ceilings: [SessionIntensityCeiling?]) -> SessionIntensityCeiling? {
        let present = ceilings.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return SessionIntensityCeiling(
            excluded: present.reduce(into: Set<PlannedSessionKind>()) { $0.formUnion($1.excluded) },
            // Todos los techos de este archivo sustituyen por `.easyRun`; si
            // alguna vez hubiera dos distintos, gana el de menor carga según
            // la misma tabla que el resto del plan ya usa.
            substitute: present.map(\.substitute).min { TrainingPlanEngine.forecastSessionLoad($0) < TrainingPlanEngine.forecastSessionLoad($1) } ?? .easyRun,
            capsStrengthIntensity: present.contains(where: \.capsStrengthIntensity),
            reasons: present.flatMap(\.reasons)
        )
    }

    // MARK: Fuentes

    /// El techo que ya existía, extraído tal cual: una alerta `.caution` no
    /// deja pasar calidad, tirada larga, híbrido ni brick, y no toca la fuerza.
    nonisolated static func fromAlert(_ alert: PhysiologicalAlert?) -> SessionIntensityCeiling? {
        guard let alert, alert.severity == .caution else { return nil }
        return SessionIntensityCeiling(
            excluded: [.qualityRun, .longRun, .hybrid, .brick],
            substitute: .easyRun, capsStrengthIntensity: false,
            reasons: ["\(alert.summary) \(alert.action)"]
        )
    }

    /// Umbrales del techo por viaje. Dos tiers y no cinco: con este número de
    /// episodios reales (ninguno todavía) más granularidad sería precisión
    /// falsa.
    static let highRiskFatigue = 0.50
    static let highRiskOffsetHours = 5.0
    static let moderateFatigue = 0.25
    static let moderateOffsetHours = 2.0

    /// El techo por viaje. `nil` cuando el estado de viaje no lo justifica —
    /// que es la mayoría del episodio: en preparación, en una estancia ya
    /// estable y una vez recuperado no se limita nada.
    ///
    /// `signalsAreReassuring` es lo que hace que esto no bloquee a ciegas: si
    /// no hay ninguna señal medida fuera de banda y ningún confusor, el tier
    /// baja uno. Las señales sólo RELAJAN el techo, nunca lo suben — subirlo
    /// sería cobrar dos veces el mismo HRV, que ya cuenta en las señales
    /// propias de assess.
    nonisolated static func fromTravel(_ impact: TravelImpact) -> SessionIntensityCeiling? {
        guard impact.isMeaningful else { return nil }
        let inTransit = impact.phase == .outboundTransit || impact.phase == .returnTransit
        // "Tranquilizador" exige EVIDENCIA tranquilizadora, no ausencia de
        // evidencia. Sin línea base personal, `signalFactors` sale vacío
        // simplemente porque no hay nada con lo que comparar — y relajar el
        // techo por eso sería tratar "no lo sé" como "está bien", que es
        // justo lo contrario de lo que esta app hace en todas partes. El
        // `confidence.level != .low` es la comprobación de que existen bandas
        // personales de verdad: TravelImpactEngine.confidence devuelve `.low`
        // exactamente en el caso de "sólo el prior, sin nada que lo confirme".
        //
        // Encontrado ejecutando los tests: a un día de llegar con 7 h de
        // desajuste y CERO datos, el techo se relajaba solo.
        let signalsAreReassuring = impact.signalFactors.isEmpty
            && !impact.isPotentiallyConfounded
            && impact.confidence.level != .low

        let offset = abs(impact.circadianOffsetHours)
        var isHighRisk = inTransit || impact.travelFatigue >= highRiskFatigue || offset >= highRiskOffsetHours
        var isModerate = impact.travelFatigue >= moderateFatigue || offset >= moderateOffsetHours
        if signalsAreReassuring, isHighRisk, !inTransit {
            // Un desajuste grande con sueño y HRV dentro de banda es
            // exactamente el caso en el que el brief pide dejar entrenar
            // ligero. En vuelo no se relaja: ahí no hay señal del día que
            // pueda tranquilizar a nadie.
            isHighRisk = false
            isModerate = true
        }
        guard isHighRisk || isModerate else { return nil }

        var reasons = impact.structuralFactors.map(\.description) + impact.signalFactors.map(\.description)
        if reasons.isEmpty { reasons = [impact.phase.rawValue.lowercased()] }

        if isHighRisk {
            return SessionIntensityCeiling(
                excluded: [.qualityRun, .longRun, .hybrid, .brick],
                substitute: .easyRun, capsStrengthIntensity: true, reasons: reasons
            )
        }
        // Moderado: la tirada larga en Z2 sigue siendo asumible con señales
        // buenas — lo que no lo es es la calidad ni un brick, que exigen ritmo
        // objetivo sobre un reloj que todavía no está en hora.
        return SessionIntensityCeiling(
            excluded: [.qualityRun, .brick],
            substitute: .easyRun, capsStrengthIntensity: true, reasons: reasons
        )
    }

    /// El techo del día: el más restrictivo de la alerta y el viaje.
    nonisolated static func resolve(alert: PhysiologicalAlert?, travel: TravelImpact) -> SessionIntensityCeiling? {
        merged([fromAlert(alert), fromTravel(travel)])
    }
}
