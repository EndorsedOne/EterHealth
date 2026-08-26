import Foundation

struct ConfidenceAssessment: Equatable {
    let score: Int
    let level: TrustLevel
    let reason: String
}

enum ConfidenceEngine {
    nonisolated static func level(samples: Int, medium: Int, high: Int) -> TrustLevel {
        samples >= high ? .high : samples >= medium ? .medium : .low
    }

    nonisolated static func level(score: Int) -> TrustLevel {
        score >= 70 ? .high : score >= 40 ? .medium : .low
    }

    nonisolated static func samples(_ samples: Int, medium: Int, high: Int,
                                    label: String) -> ConfidenceAssessment {
        let level = level(samples: samples, medium: medium, high: high)
        let score: Int
        if samples <= 0 { score = 0 }
        else if samples >= high { score = 85 }
        else if samples >= medium { score = 55 }
        else { score = 25 }
        return ConfidenceAssessment(
            score: score, level: level,
            reason: samples == 1 ? "Basada en 1 \(label)." : "Basada en \(samples) \(label)."
        )
    }

    nonisolated static func readiness(baselineConfidence: Int, signalCount: Int,
                                      hasCheckIn: Bool, updatedAt: Date?, now: Date = Date()) -> ConfidenceAssessment {
        var score = Int((Double(min(100, max(0, baselineConfidence))) * 0.60).rounded())
        score += min(20, signalCount * 3)
        if hasCheckIn { score += 10 }
        if let updatedAt, now.timeIntervalSince(updatedAt) <= 6 * 3_600 { score += 10 }
        score = min(100, max(0, score))
        let missing = hasCheckIn ? "" : "; falta el check-in de hoy"
        return ConfidenceAssessment(score: score, level: level(score: score),
                                    reason: "Línea base \(baselineConfidence)% y \(signalCount) señales activas\(missing).")
    }

    nonisolated static func trainingLoad(observedDays: Int, sessions: Int) -> ConfidenceAssessment {
        let history = min(75, Int((Double(max(0, observedDays)) / 28 * 75).rounded()))
        let density = min(25, sessions * 3)
        let score = min(100, history + density)
        return ConfidenceAssessment(score: score, level: level(score: score),
                                    reason: "\(observedDays) días de carga observados y \(sessions) sesiones recientes.")
    }

    nonisolated static func declared(samples: Int) -> ConfidenceAssessment {
        let score = samples > 0 ? 72 : 0
        return ConfidenceAssessment(score: score, level: level(score: score),
                                    reason: samples > 0 ? "Registro declarado directamente por el usuario." : "No hay registros declarados.")
    }

    nonisolated static func physiologicalAlert(signalConfidences: [Int], hasCheckIn: Bool) -> ConfidenceAssessment {
        guard !signalConfidences.isEmpty else {
            return ConfidenceAssessment(score: 0, level: .low, reason: "No hay señales fisiológicas actuales suficientes.")
        }
        let mean = signalConfidences.reduce(0, +) / signalConfidences.count
        let agreement = signalConfidences.count >= 2 ? 12 : 0
        let subjective = hasCheckIn ? 8 : 0
        let score = min(100, max(0, mean + agreement + subjective))
        return ConfidenceAssessment(
            score: score, level: level(score: score),
            reason: "\(signalConfidences.count) señales personales actuales\(hasCheckIn ? " y check-in de hoy" : "")."
        )
    }

    nonisolated static func habitAssociation(samples: Int, metrics: Int, overlapRatio: Double,
                                             consistency: Double) -> ConfidenceAssessment {
        let history = min(65, samples * 9)
        let breadth = min(18, metrics * 6)
        let agreement = Int((max(0, min(1, consistency)) * 17).rounded())
        let confoundingPenalty = Int((max(0, min(1, overlapRatio)) * 25).rounded())
        var score = min(100, max(0, history + breadth + agreement - confoundingPenalty))
        // Two or three mornings can reveal a hypothesis, never a mature association.
        if samples < 4 { score = min(score, 35) }
        else if samples < 6 { score = min(score, 60) }
        let overlap = overlapRatio >= 0.5 ? " Muchas exposiciones coinciden con otros factores." : ""
        return ConfidenceAssessment(
            score: score, level: level(score: score),
            reason: "\(samples) mañanas emparejadas, \(metrics) métricas y \(Int((consistency * 100).rounded()))% de consistencia.\(overlap)"
        )
    }

    nonisolated static func hyrox(stationCoverage: Int, specificSessions: Int,
                                  completedRaces: Int, running: TrustLevel?) -> ConfidenceAssessment {
        if completedRaces > 0 {
            let score = min(96, 78 + completedRaces * 7)
            return ConfidenceAssessment(score: score, level: level(score: score),
                                        reason: "\(completedRaces) resultados completos y \(stationCoverage)/8 estaciones observadas.")
        }
        var score = stationCoverage * 5 + min(24, specificSessions * 8)
        if running == .high { score += 20 }
        else if running == .medium { score += 13 }
        else if running == .low { score += 6 }
        if specificSessions == 0 { score = min(score, 35) }
        score = min(68, max(0, score))
        return ConfidenceAssessment(
            score: score, level: level(score: score),
            reason: "\(stationCoverage)/8 estaciones, \(specificSessions) sesiones específicas y carrera \(running?.rawValue.lowercased() ?? "sin estimar")."
        )
    }

    nonisolated static func triathlon(swimSessions: Int, swimIsPersonal: Bool, bikeSessions: Int, bikeIsPersonal: Bool,
                                      brickSessions: Int, running: TrustLevel?) -> ConfidenceAssessment {
        var score = 0
        score += swimIsPersonal ? min(24, 8 + swimSessions * 3) : 0
        score += bikeIsPersonal ? min(24, 8 + bikeSessions * 3) : 0
        score += min(18, brickSessions * 6)
        if running == .high { score += 24 }
        else if running == .medium { score += 16 }
        else if running == .low { score += 8 }
        score = min(100, max(0, score))
        return ConfidenceAssessment(
            score: score, level: level(score: score),
            reason: "\(swimSessions) sesiones de natación, \(bikeSessions) de ciclismo, \(brickSessions) brick y carrera \(running?.rawValue.lowercased() ?? "sin estimar")."
        )
    }

    nonisolated static func energy(
        baselineConfidence: Int, hasSleep: Bool, hasSleepStages: Bool,
        hasHRV: Bool, hasRestingHeartRate: Bool, hasCheckIn: Bool,
        activityEvents: Int, updatedAt: Date?, now: Date = Date()
    ) -> ConfidenceAssessment {
        var score = Int((Double(min(100, max(0, baselineConfidence))) * 0.35).rounded())
        var available: [String] = []
        var missing: [String] = []

        if hasSleep { score += 14; available.append("sueño") } else { missing.append("sueño") }
        if hasSleepStages { score += 8; available.append("fases") } else { missing.append("fases") }
        if hasHRV { score += 10; available.append("HRV") } else { missing.append("HRV") }
        if hasRestingHeartRate { score += 8; available.append("reposo") } else { missing.append("reposo") }
        if hasCheckIn { score += 8; available.append("check-in") } else { missing.append("check-in") }
        if activityEvents > 0 { score += min(7, 3 + activityEvents); available.append("actividad") }

        if let updatedAt {
            let age = max(0, now.timeIntervalSince(updatedAt))
            if age <= 3_600 { score += 10 }
            else if age <= 6 * 3_600 { score += 7 }
            else if age <= 24 * 3_600 { score += 3 }
            else { missing.append("actualización reciente") }
        } else { missing.append("fecha") }

        score = min(100, max(0, score))
        let reason: String
        if missing.isEmpty {
            reason = "Basada en \(available.joined(separator: ", ")) y datos recientes."
        } else if available.isEmpty {
            reason = "Faltan señales personales suficientes."
        } else {
            reason = "Usa \(available.joined(separator: ", ")); falta \(missing.prefix(2).joined(separator: " y "))."
        }
        return ConfidenceAssessment(score: score, level: level(score: score), reason: reason)
    }
}
