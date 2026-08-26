import Foundation

struct TwinDailyState: Codable, Identifiable {
    var id: Date { day }
    let day: Date
    let openedAt: Date
    var updatedAt: Date
    let openingScore: Int
    var latestScore: Int
    let openingRecommendation: String
    var latestRecommendation: String
    var predictedNextDayScore: Int
    var observedNextDayScore: Int?
    var predictionError: Int?
    var baselineConfidence: Int
    var signalImpacts: [String: Int]
    var hrv: Int?
    var restingHeartRate: Int?
    var sleepHours: Double?
    var completedSessions: Int
}

struct TwinCalibration: Equatable {
    static let none = TwinCalibration(observations: 0, signedBias: 0, confidence: 0, scoreAdjustment: 0)

    let observations: Int
    let signedBias: Double
    let confidence: Int
    let scoreAdjustment: Int

    static func derive(errors: [Int]) -> TwinCalibration {
        let recent = Array(errors.prefix(42))
        guard recent.count >= 3 else {
            return TwinCalibration(observations: recent.count, signedBias: 0, confidence: 0, scoreAdjustment: 0)
        }

        // The newest observation receives the most weight. Individual errors are
        // winsorized so one exceptional day cannot teach the model a false rule.
        var weightedTotal = 0.0
        var totalWeight = 0.0
        for (index, rawError) in recent.enumerated() {
            let error = Double(min(20, max(-20, rawError)))
            let weight = pow(0.92, Double(index))
            weightedTotal += error * weight
            totalWeight += weight
        }
        let bias = weightedTotal / max(totalWeight, 1)
        let evidence = min(1, Double(recent.count - 2) / 12)
        let adjustment = min(8, max(-8, Int((bias * evidence).rounded())))
        return TwinCalibration(
            observations: recent.count,
            signedBias: bias,
            confidence: Int((evidence * 100).rounded()),
            scoreAdjustment: adjustment
        )
    }
}

struct PersonalReadinessAnchor: Equatable {
    static let provisional = PersonalReadinessAnchor(score: 70, observations: 0, confidence: 0, personalMedian: nil)

    let score: Int
    let observations: Int
    let confidence: Int
    let personalMedian: Double?

    nonisolated static func derive(scores: [Int]) -> PersonalReadinessAnchor {
        let plausible = scores.map { min(100, max(0, $0)) }
        guard plausible.count >= 7 else {
            return PersonalReadinessAnchor(score: 70, observations: plausible.count, confidence: 0, personalMedian: nil)
        }

        let ordered = plausible.sorted()
        let middle = ordered.count / 2
        let median = ordered.count.isMultiple(of: 2)
            ? Double(ordered[middle - 1] + ordered[middle]) / 2
            : Double(ordered[middle])
        // Seven mornings unlock the personal reference. It progressively replaces
        // the provisional 70 and fully takes over after 30 valid mornings.
        let evidence = min(1, Double(plausible.count - 6) / 24)
        let boundedMedian = min(85, max(45, median))
        let blended = 70 + (boundedMedian - 70) * evidence
        return PersonalReadinessAnchor(
            score: Int(blended.rounded()), observations: plausible.count,
            confidence: Int((evidence * 100).rounded()), personalMedian: median
        )
    }
}

@MainActor
final class TwinStateStore: ObservableObject {
    static let shared = TwinStateStore()
    @Published private(set) var states: [TwinDailyState] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("twin-daily-state.json")
    }

    private init() { load() }

    func capture(assessment: TwinAssessment, health: HealthStore, now: Date = Date()) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let predicted = predictedTomorrow(from: assessment)
        let sessions = health.recentWorkouts.filter { calendar.isDate($0.date, inSameDayAs: day) }.count
        let impacts = Dictionary(assessment.signals.map { ($0.name, $0.impact) }, uniquingKeysWith: +)
        let hrv = health.snapshot.hrv > 0 ? health.snapshot.hrv : nil
        let resting = health.snapshot.restingHeartRate > 0 ? health.snapshot.restingHeartRate : nil
        let sleep = health.snapshot.sleepHours > 0 ? health.snapshot.sleepHours : nil

        if let index = states.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            states[index].updatedAt = now
            states[index].latestScore = assessment.score
            states[index].latestRecommendation = assessment.recommendation
            states[index].predictedNextDayScore = predicted
            states[index].baselineConfidence = assessment.baselineConfidence
            states[index].signalImpacts = impacts
            states[index].hrv = hrv
            states[index].restingHeartRate = resting
            states[index].sleepHours = sleep
            states[index].completedSessions = sessions
        } else {
            states.append(TwinDailyState(
                day: day, openedAt: now, updatedAt: now,
                openingScore: assessment.score, latestScore: assessment.score,
                openingRecommendation: assessment.recommendation, latestRecommendation: assessment.recommendation,
                predictedNextDayScore: predicted, observedNextDayScore: nil, predictionError: nil,
                baselineConfidence: assessment.baselineConfidence, signalImpacts: impacts,
                hrv: hrv, restingHeartRate: resting, sleepHours: sleep, completedSessions: sessions
            ))
        }

        if let previousIndex = states.indices.filter({ states[$0].day < day }).max(by: { states[$0].day < states[$1].day }),
           calendar.dateComponents([.day], from: states[previousIndex].day, to: day).day == 1 {
            states[previousIndex].observedNextDayScore = assessment.score
            states[previousIndex].predictionError = assessment.score - states[previousIndex].predictedNextDayScore
        }

        states.sort { $0.day > $1.day }
        if states.count > 730 { states.removeLast(states.count - 730) }
        persist()
    }

    func restore(_ restored: [TwinDailyState]) {
        let days = Set(restored.map(\.day))
        states.removeAll { days.contains($0.day) }
        states.append(contentsOf: restored)
        states.sort { $0.day > $1.day }
        persist()
    }

    var calibratedObservations: Int { states.filter { $0.observedNextDayScore != nil }.count }

    var meanAbsoluteError: Double? {
        let errors = states.compactMap(\.predictionError).map { abs(Double($0)) }
        guard !errors.isEmpty else { return nil }
        return errors.reduce(0, +) / Double(errors.count)
    }

    var calibration: TwinCalibration {
        TwinCalibration.derive(errors: states.compactMap(\.predictionError))
    }

    func personalAnchor(now: Date = Date()) -> PersonalReadinessAnchor {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -90, to: today) ?? .distantPast
        let morningScores = states.filter { $0.day >= cutoff && $0.day < today }.map(\.openingScore)
        return PersonalReadinessAnchor.derive(scores: morningScores)
    }

    private func predictedTomorrow(from assessment: TwinAssessment) -> Int {
        let recommendation = assessment.recommendation.lowercased()
        let delta: Int
        if recommendation.contains("recuper") || recommendation.contains("descanso") { delta = 6 }
        else if recommendation.contains("calidad") || recommendation.contains("tirada larga") { delta = -4 }
        else if recommendation.contains("fuerza") || recommendation.contains("pierna") || recommendation.contains("empuje") || recommendation.contains("tirón") { delta = -2 }
        else { delta = 1 }
        return min(100, max(0, assessment.score + delta))
    }

    private func persist() {
        do { try JSONEncoder().encode(states).write(to: storageURL, options: .atomic) }
        catch { assertionFailure("No se pudo guardar el estado diario del gemelo: \(error)") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TwinDailyState].self, from: data) else { return }
        states = decoded.sorted { $0.day > $1.day }
    }
}
