import Foundation

struct RunningSignalPoint: Equatable {
    let date: Date
    let value: Double
}

enum RunningSessionStructureKind: String, Equatable {
    case strides
    case sprintIntervals
    case repeatedIntervals
    case vo2Intervals
    case thresholdIntervals
}

struct RunningSessionStructure: Equatable {
    let kind: RunningSessionStructureKind
    let repetitions: Int
    let workSeconds: Double
    let recoverySeconds: Double?
    let confidence: TrustLevel
    let evidence: String
    let intervals: [DateInterval]

    var isQuality: Bool { repetitions >= 3 }
}

/// Detects repeated work/recovery structure from the signals recorded inside a
/// run. It deliberately does not use average pace or average HR: both are
/// diluted by recoveries, and HR also trails very short efforts. The output is
/// compact evidence stored on HealthWorkout; raw HealthKit samples remain in
/// HealthKit and are never persisted by Eter.
enum RunningSessionStructureEngine {
    private struct Bout {
        let start: Date
        let end: Date
        var duration: Double { end.timeIntervalSince(start) }
    }

    static func detect(speed: [RunningSignalPoint], power: [RunningSignalPoint] = [],
                       heartRate: [RunningSignalPoint] = [], markedIntervals: Int = 0) -> RunningSessionStructure? {
        let usableSpeed = speed.filter { $0.value >= 0.7 && $0.value <= 12 }.sorted { $0.date < $1.date }
        let usablePower = power.filter { $0.value >= 40 && $0.value <= 2_500 }.sorted { $0.date < $1.date }
        let primary: [RunningSignalPoint]
        let source: String
        if usableSpeed.count >= 12 {
            primary = usableSpeed
            source = "velocidad"
        } else if usablePower.count >= 12 {
            primary = usablePower
            source = "potencia"
        } else {
            return detectFromHeartRate(heartRate)
        }

        let values = primary.map(\.value).sorted()
        guard let low = percentile(values, 0.35), let high = percentile(values, 0.85),
              low > 0, high / low >= 1.22 else { return nil }
        let enter = low + (high - low) * 0.62
        let leave = low + (high - low) * 0.42
        let bouts = workBouts(points: primary, enter: enter, leave: leave)
            .filter { $0.duration >= 8 && $0.duration <= 8 * 60 }
        guard bouts.count >= 3 else { return nil }

        let durations = bouts.map(\.duration).sorted()
        guard let medianWork = percentile(durations, 0.5) else { return nil }
        // A real repeated workout has broadly comparable repetitions. This
        // rejects GPS spikes and the arbitrary fast fragments of a normal run.
        let comparable = bouts.filter { $0.duration >= medianWork * 0.35 && $0.duration <= medianWork * 2.8 }
        guard comparable.count >= 3 else { return nil }

        let recoveries = zip(comparable, comparable.dropFirst()).map { next, following in
            following.start.timeIntervalSince(next.end)
        }.filter { $0 >= 5 && $0 <= 12 * 60 }.sorted()
        let medianRecovery = percentile(recoveries, 0.5)
        let hrRange: Double = {
            guard let min = heartRate.map(\.value).min(), let max = heartRate.map(\.value).max() else { return 0 }
            return max - min
        }()
        let repeatedMarkers = markedIntervals >= 3
        let corroborated = hrRange >= 12 || repeatedMarkers
        let confidence: TrustLevel = corroborated && comparable.count >= 4 ? .high : .medium
        let kind: RunningSessionStructureKind
        switch medianWork {
        case ..<20: kind = .strides
        case ..<75: kind = .sprintIntervals
        case ..<360.0: kind = .vo2Intervals
        default: kind = .thresholdIntervals
        }
        let totalWork = comparable.reduce(0) { $0 + $1.duration }
        let evidence = "\(comparable.count) bloques por \(source)" + (corroborated ? " corroborados" : "")
        return RunningSessionStructure(kind: kind, repetitions: comparable.count,
                                       workSeconds: totalWork, recoverySeconds: medianRecovery,
                                       confidence: confidence, evidence: evidence,
                                       intervals: comparable.map { DateInterval(start: $0.start, end: $0.end) })
    }

    /// HR is a lagging signal, so it must never claim "sprints" or estimate
    /// work duration. It can still establish that a session contained repeated
    /// high-intensity bouts when several clear rises are separated by genuine
    /// recoveries. That is enough to count quality with medium confidence and
    /// fixes the common case where Apple keeps the HR trace but does not expose
    /// running-speed samples to a third-party reader.
    private static func detectFromHeartRate(_ heartRate: [RunningSignalPoint]) -> RunningSessionStructure? {
        let points = heartRate.filter { (35...230).contains($0.value) }.sorted { $0.date < $1.date }
        guard points.count >= 20 else { return nil }
        let values = points.map(\.value).sorted()
        guard let low = percentile(values, 0.30), let high = percentile(values, 0.88),
              high - low >= 14 else { return nil }
        let bouts = workBouts(points: points,
                              enter: low + (high - low) * 0.60,
                              leave: low + (high - low) * 0.35)
            .filter { $0.duration >= 20 && $0.duration <= 6 * 60 }
        guard bouts.count >= 3 else { return nil }
        let durations = bouts.map(\.duration).sorted()
        guard let median = percentile(durations, 0.5) else { return nil }
        let comparable = bouts.filter { $0.duration >= median * 0.30 && $0.duration <= median * 3.2 }
        guard comparable.count >= 3 else { return nil }
        let recoveries = zip(comparable, comparable.dropFirst()).map { current, next in
            next.start.timeIntervalSince(current.end)
        }.filter { $0 >= 10 && $0 <= 12 * 60 }.sorted()
        guard recoveries.count >= 2 else { return nil }
        return RunningSessionStructure(
            kind: .repeatedIntervals,
            repetitions: comparable.count,
            workSeconds: comparable.reduce(0) { $0 + $1.duration },
            recoverySeconds: percentile(recoveries, 0.5),
            confidence: .medium,
            evidence: "\(comparable.count) esfuerzos y recuperaciones por pulso",
            intervals: comparable.map { DateInterval(start: $0.start, end: $0.end) }
        )
    }

    private static func workBouts(points: [RunningSignalPoint], enter: Double, leave: Double) -> [Bout] {
        guard points.count >= 2 else { return [] }
        var result: [Bout] = []
        var start: Date?
        var lastHigh: Date?
        for point in points {
            if start == nil, point.value >= enter {
                start = point.date
                lastHigh = point.date
            } else if start != nil {
                if point.value >= leave { lastHigh = point.date }
                if point.value < leave, let opened = start, let last = lastHigh,
                   point.date.timeIntervalSince(last) >= 6 {
                    result.append(Bout(start: opened, end: max(last.addingTimeInterval(5), opened.addingTimeInterval(1))))
                    start = nil
                    lastHigh = nil
                }
            }
        }
        if let opened = start, let last = lastHigh {
            result.append(Bout(start: opened, end: max(last.addingTimeInterval(5), opened.addingTimeInterval(1))))
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
