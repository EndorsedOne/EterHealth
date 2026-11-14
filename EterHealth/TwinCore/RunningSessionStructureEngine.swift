import Foundation

struct RunningSignalPoint: Equatable {
    let date: Date
    let value: Double
}

enum RunningSessionStructureKind: String, Codable, Equatable {
    case strides
    case sprintIntervals
    case shortIntervals
    case repeatedIntervals
    case vo2Intervals
    case longIntervals
    case thresholdIntervals
}

struct RunningSessionStructure: Codable, Equatable {
    let kind: RunningSessionStructureKind
    let repetitions: Int
    let workSeconds: Double
    let recoverySeconds: Double?
    let confidence: TrustLevel
    let evidence: String
    let intervals: [DateInterval]

    var isQuality: Bool { repetitions >= 3 }
}

struct RunningHeartRatePeakAssessment: Equatable {
    let bpm: Double
    let plausibility: TrustLevel
    let evidence: String
    let sustainedSeconds: Double
}

/// Detects repeated work/recovery structure from the signals recorded inside a
/// run. It deliberately does not use average pace or average HR: both are
/// diluted by recoveries, and HR also trails very short efforts. The output is
/// compact evidence stored on HealthWorkout and in RunningStructureStore; raw
/// HealthKit samples remain in HealthKit and are never persisted by Eter.
enum RunningSessionStructureEngine {
    /// Centralised physiological/mechanical segmentation policy. These are
    /// signal-quality limits, not a prescription for a particular workout.
    /// They deliberately span anything from short 1' reps to long threshold
    /// blocks; no 3'/2' shape is encoded here.
    private enum Policy {
        static let minimumRepeatedBouts = 3
        static let minimumHeartSamples = 20
        static let heartSmoothingRadius = 12.0
        // Longer than a short rounded/plateaued peak after smoothing, but well
        // below the shortest supported 1' work block. This lets one peak
        // represent the whole crest instead of requiring an instantaneous
        // sign change that real optical HR rarely provides.
        static let heartSlopeHorizon = 35.0
        static let minimumHeartProminence = 4.5
        static let relativeHeartProminence = 0.11
        static let minimumPeakSeparation = 40.0
        static let maximumPeakContext = 8.0 * 60
        static let minimumCycleSeconds = 45.0
        static let maximumCycleSeconds = 12.0 * 60
    }

    private struct Bout {
        let start: Date
        let end: Date
        var duration: Double { end.timeIntervalSince(start) }
    }

    static func detect(speed: [RunningSignalPoint], power: [RunningSignalPoint] = [],
                       heartRate: [RunningSignalPoint] = [], markedIntervals: Int = 0,
                       markedIntervalBounds: [DateInterval] = []) -> RunningSessionStructure? {
        let usableSpeed = speed.filter { $0.value >= 0.7 && $0.value <= 12 }.sorted { $0.date < $1.date }
        let usablePower = power.filter { $0.value >= 40 && $0.value <= 2_500 }.sorted { $0.date < $1.date }
        // Explicit laps/segments outrank inference only when a mechanical
        // signal confirms which marked blocks were work. A bare marker count
        // is not enough: some recorders mark both work and recovery, and
        // treating all of them as efforts would invent repetitions.
        if let explicit = detectMarkedStructure(bounds: markedIntervalBounds,
                                                speed: usableSpeed, power: usablePower,
                                                heartRate: heartRate) {
            return explicit
        }
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
        guard bouts.count >= Policy.minimumRepeatedBouts else { return nil }

        let durations = bouts.map(\.duration).sorted()
        guard let medianWork = percentile(durations, 0.5) else { return nil }
        // A real repeated workout has broadly comparable repetitions. This
        // rejects GPS spikes and the arbitrary fast fragments of a normal run.
        let comparable = bouts.filter { $0.duration >= medianWork * 0.35 && $0.duration <= medianWork * 2.8 }
        guard comparable.count >= Policy.minimumRepeatedBouts else { return nil }

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
        case ..<35: kind = .sprintIntervals
        case ..<120: kind = .shortIntervals
        case ..<360.0: kind = .vo2Intervals
        case ..<600.0: kind = .longIntervals
        default: kind = .thresholdIntervals
        }
        let totalWork = comparable.reduce(0) { $0 + $1.duration }
        let evidence = "\(comparable.count) bloques por \(source)" + (corroborated ? " corroborados" : "")
        return RunningSessionStructure(kind: kind, repetitions: comparable.count,
                                       workSeconds: totalWork, recoverySeconds: medianRecovery,
                                       confidence: confidence, evidence: evidence,
                                       intervals: comparable.map { DateInterval(start: $0.start, end: $0.end) })
    }

    private static func detectMarkedStructure(bounds: [DateInterval], speed: [RunningSignalPoint],
                                              power: [RunningSignalPoint],
                                              heartRate: [RunningSignalPoint]) -> RunningSessionStructure? {
        let bounds = bounds.filter { $0.duration >= 8 && $0.duration <= 20 * 60 }
            .sorted { $0.start < $1.start }
        guard bounds.count >= Policy.minimumRepeatedBouts else { return nil }
        let signal: [RunningSignalPoint]
        let source: String
        if speed.count >= 12 { signal = speed; source = "segmentos y velocidad" }
        else if power.count >= 12 { signal = power; source = "segmentos y potencia" }
        else { return nil } // HR confirms physiology; it does not choose external work blocks.
        let blockValues: [(DateInterval, Double)] = bounds.compactMap { interval in
            let values = signal.filter { interval.contains($0.date) }.map(\.value).sorted()
            guard let median = percentile(values, 0.5) else { return nil }
            return (interval, median)
        }
        guard blockValues.count >= Policy.minimumRepeatedBouts else { return nil }
        let medians = blockValues.map(\.1).sorted()
        guard let low = percentile(medians, 0.30), let high = percentile(medians, 0.80),
              high > low * 1.08 else { return nil }
        let work = blockValues.filter { $0.1 >= low + (high - low) * 0.55 }.map(\.0)
        guard work.count >= Policy.minimumRepeatedBouts else { return nil }
        let duration = percentile(work.map(\.duration).sorted(), 0.5) ?? 0
        let kind: RunningSessionStructureKind
        switch duration {
        case ..<20: kind = .strides
        case ..<35: kind = .sprintIntervals
        case ..<120: kind = .shortIntervals
        case ..<360: kind = .vo2Intervals
        case ..<600: kind = .longIntervals
        default: kind = .thresholdIntervals
        }
        let recoveries = zip(work, work.dropFirst()).map { max(0, $1.start.timeIntervalSince($0.end)) }.sorted()
        return .init(kind: kind, repetitions: work.count,
                     workSeconds: work.reduce(0) { $0 + $1.duration },
                     recoverySeconds: percentile(recoveries, 0.5), confidence: .high,
                     evidence: "\(work.count) bloques explícitos por \(source)", intervals: work)
    }

    /// HR is a lagging response, not the external workload. Therefore this
    /// fallback never calls a bout a sprint nor pretends its boundaries are
    /// treadmill-speed changes. It recognises repeated *physiological waves*
    /// with local peak/trough prominence. Local baselines are essential:
    /// during a hard set both peaks and recovery minima drift upward, so a
    /// single global leave-threshold merges later repetitions (the old 3-vs-6
    /// failure). Mechanical signals and explicit workout markers still outrank
    /// this medium-confidence fallback in detect().
    private static func detectFromHeartRate(_ heartRate: [RunningSignalPoint]) -> RunningSessionStructure? {
        let points = heartRate.filter { (35...230).contains($0.value) }.sorted { $0.date < $1.date }
        guard points.count >= Policy.minimumHeartSamples else { return nil }
        let smoothed = timeSmoothed(points, radius: Policy.heartSmoothingRadius)
        let sortedValues = smoothed.map(\.value).sorted()
        guard let low = percentile(sortedValues, 0.15), let high = percentile(sortedValues, 0.95),
              high - low >= 14 else { return nil }

        let requiredProminence = max(Policy.minimumHeartProminence,
                                     (high - low) * Policy.relativeHeartProminence)
        let candidates = heartPeakCandidates(smoothed, requiredProminence: requiredProminence)
        let peaks = suppressNearbyPeaks(candidates, minimumSeparation: Policy.minimumPeakSeparation)
        guard peaks.count >= Policy.minimumRepeatedBouts else { return nil }

        // Retain the dominant repeated sequence. A broad tolerance permits
        // irregular fartlek, while rejecting a few unrelated undulations in a
        // steady/progressive run. We never require recovery to return to one
        // absolute bpm threshold.
        let sequence = dominantPeakSequence(peaks)
        guard sequence.count >= Policy.minimumRepeatedBouts else { return nil }
        let bouts = responseBouts(for: sequence, in: smoothed)
        guard bouts.count == sequence.count else { return nil }
        let cycleDurations = zip(sequence, sequence.dropFirst()).map {
            $1.point.date.timeIntervalSince($0.point.date)
        }.sorted()
        guard cycleDurations.count >= 2 else { return nil }
        let cycle = percentile(cycleDurations, 0.5)
        let recoveries = zip(bouts, bouts.dropFirst()).map { current, next in
            max(0, next.start.timeIntervalSince(current.end))
        }.filter { $0 >= 5 && $0 <= Policy.maximumCycleSeconds }.sorted()
        return RunningSessionStructure(
            kind: .repeatedIntervals,
            repetitions: bouts.count,
            workSeconds: bouts.reduce(0) { $0 + $1.duration },
            recoverySeconds: percentile(recoveries, 0.5),
            confidence: .medium,
            evidence: "\(bouts.count) respuestas repetidas por pulso" +
                (cycle.map { " · ciclo ~\(Int($0.rounded())) s" } ?? ""),
            intervals: bouts.map { DateInterval(start: $0.start, end: $0.end) }
        )
    }

    private struct HeartPeak {
        let index: Int
        let point: RunningSignalPoint
        let prominence: Double
    }

    /// Time-based smoothing rather than a fixed sample count: Apple may expose
    /// 1 Hz ordinary samples or a sparser expanded condensed series.
    private static func timeSmoothed(_ points: [RunningSignalPoint], radius: TimeInterval) -> [RunningSignalPoint] {
        var result: [RunningSignalPoint] = []
        var left = 0
        var right = 0
        var sum = 0.0
        for index in points.indices {
            let date = points[index].date
            while right < points.count, points[right].date.timeIntervalSince(date) <= radius {
                sum += points[right].value
                right += 1
            }
            while left < points.count, date.timeIntervalSince(points[left].date) > radius {
                sum -= points[left].value
                left += 1
            }
            let count = max(1, right - left)
            result.append(.init(date: date, value: sum / Double(count)))
        }
        return result
    }

    private static func heartPeakCandidates(_ points: [RunningSignalPoint],
                                            requiredProminence: Double) -> [HeartPeak] {
        guard points.count >= 5 else { return [] }
        var result: [HeartPeak] = []
        for index in 1..<(points.count - 1) {
            let date = points[index].date
            let before = points.indices.filter {
                let delta = date.timeIntervalSince(points[$0].date)
                return delta >= Policy.heartSlopeHorizon && delta <= Policy.maximumPeakContext
            }
            let after = points.indices.filter {
                let delta = points[$0].date.timeIntervalSince(date)
                return delta >= Policy.heartSlopeHorizon && delta <= Policy.maximumPeakContext
            }
            guard let recentIndex = before.last,
                  let followingIndex = after.first else { continue }
            let rising = points[index].value - points[recentIndex].value
            let falling = points[index].value - points[followingIndex].value
            guard rising >= 1.5, falling >= 1.5 else { continue }

            let priorFloor = before.map { points[$0].value }.min() ?? points[recentIndex].value
            let followingFloor = after.map { points[$0].value }.min() ?? points[followingIndex].value
            let prominence = min(points[index].value - priorFloor,
                                 points[index].value - followingFloor)
            guard prominence >= requiredProminence else { continue }
            result.append(.init(index: index, point: points[index], prominence: prominence))
        }
        return result
    }

    private static func suppressNearbyPeaks(_ peaks: [HeartPeak], minimumSeparation: TimeInterval) -> [HeartPeak] {
        var accepted: [HeartPeak] = []
        for candidate in peaks.sorted(by: { $0.point.date < $1.point.date }) {
            if let last = accepted.last,
               candidate.point.date.timeIntervalSince(last.point.date) < minimumSeparation {
                if candidate.prominence > last.prominence { accepted[accepted.count - 1] = candidate }
            } else {
                accepted.append(candidate)
            }
        }
        return accepted
    }

    private static func dominantPeakSequence(_ peaks: [HeartPeak]) -> [HeartPeak] {
        guard peaks.count >= Policy.minimumRepeatedBouts else { return [] }
        let gaps = zip(peaks, peaks.dropFirst()).map { $1.point.date.timeIntervalSince($0.point.date) }
            .filter { $0 >= Policy.minimumCycleSeconds && $0 <= Policy.maximumCycleSeconds }
            .sorted()
        guard let medianGap = percentile(gaps, 0.5) else { return [] }
        let minimumGap = max(Policy.minimumCycleSeconds, medianGap * 0.35)
        let maximumGap = min(Policy.maximumCycleSeconds, medianGap * 2.8)
        var best: [HeartPeak] = []
        var current: [HeartPeak] = [peaks[0]]
        for peak in peaks.dropFirst() {
            let gap = peak.point.date.timeIntervalSince(current.last!.point.date)
            if gap >= minimumGap && gap <= maximumGap {
                current.append(peak)
            } else {
                if current.count > best.count { best = current }
                current = [peak]
            }
        }
        if current.count > best.count { best = current }
        return best
    }

    /// The interval is explicitly a response wave (preceding local trough to
    /// local HR peak), not a claim about the exact external work boundary.
    private static func responseBouts(for peaks: [HeartPeak], in points: [RunningSignalPoint]) -> [Bout] {
        guard !peaks.isEmpty else { return [] }
        return peaks.enumerated().compactMap { offset, peak in
            let lowerBound: Int
            if offset == 0 {
                lowerBound = max(0, peak.index - max(2, points.count / max(3, peaks.count * 2)))
            } else {
                lowerBound = peaks[offset - 1].index
            }
            guard lowerBound < peak.index else { return nil }
            let troughIndex = (lowerBound..<peak.index).min(by: { points[$0].value < points[$1].value }) ?? lowerBound
            guard peak.point.date.timeIntervalSince(points[troughIndex].date) >= 15 else { return nil }
            return Bout(start: points[troughIndex].date, end: peak.point.date)
        }
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

    /// Evaluates an observed maximum without turning one optical reading into
    /// a new personal HRmax. Sustained neighbouring samples, a plausible rise
    /// into the peak and coincidence with a detected work/response block add
    /// evidence; an isolated discontinuity remains low confidence.
    static func assessHeartRatePeak(_ heartRate: [RunningSignalPoint],
                                    structure: RunningSessionStructure?) -> RunningHeartRatePeakAssessment? {
        let points = heartRate.filter { (35...230).contains($0.value) }.sorted { $0.date < $1.date }
        guard points.count >= 3, let peakIndex = points.indices.max(by: { points[$0].value < points[$1].value }) else { return nil }
        let peak = points[peakIndex]
        let near = 3.0
        var left = peakIndex
        var right = peakIndex
        while left > points.startIndex, peak.value - points[left - 1].value <= near { left -= 1 }
        while right < points.index(before: points.endIndex), peak.value - points[right + 1].value <= near { right += 1 }
        let sampleSpacing = zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
            .filter { $0 > 0 && $0 <= 30 }.sorted()
        let spacing = percentile(sampleSpacing, 0.5) ?? 1
        let sustained = Double(right - left + 1) * spacing

        let before = points.prefix(peakIndex).filter { peak.date.timeIntervalSince($0.date) <= 120 }
        let priorValues = before.map(\.value).sorted()
        let prior = percentile(priorValues, 0.5) ?? peak.value
        let rise = peak.value - prior
        let aligned = structure?.intervals.contains(where: {
            $0.start.addingTimeInterval(-30) <= peak.date && peak.date <= $0.end.addingTimeInterval(45)
        }) == true
        let secondHighest = points.enumerated().filter { $0.offset != peakIndex }.map { $0.element.value }.max() ?? peak.value

        var score = 0
        if sustained >= 10 { score += 35 } else if sustained >= 5 { score += 18 }
        if peak.value - secondHighest <= 4 { score += 20 }
        if rise >= 8 { score += 20 } else if rise >= 4 { score += 10 }
        if aligned { score += 15 }
        if (120...220).contains(peak.value) { score += 10 }
        // Repetition elsewhere in the workout cannot rescue an instantaneous
        // optical spike: continuity around this peak is mandatory before Éter
        // may even suggest that zones deserve review.
        let plausibility: TrustLevel = sustained < 10 ? .low
            : score >= 70 ? .high : score >= 45 ? .medium : .low
        let detail: String
        switch plausibility {
        case .high: detail = "varios segundos cercanos al máximo y progresión compatible con esfuerzo"
        case .medium: detail = "señal compatible, todavía insuficiente para recalibrar automáticamente"
        case .low: detail = "lectura aislada o sin continuidad suficiente"
        }
        return .init(bpm: peak.value, plausibility: plausibility, evidence: detail,
                     sustainedSeconds: sustained)
    }
}
