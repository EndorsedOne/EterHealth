import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

struct StrengthLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exerciseName: String
        var setID: String
        var setNumber: Int
        var totalSets: Int
        var weight: Double
        var reps: Int
        var targetRIR: Double?
        var actualRIR: Int?
        var completedSets: Int
        var totalSetsInWorkout: Int
        var restSeconds: Int
        var restEndsAt: Date?
        var canCompleteSet: Bool
        var updatedAt: Date
    }
    let workoutID: String
    let routineName: String
    let startedAt: Date
}

private struct LiveStrengthCommand: Codable {
    let id: UUID
    let issuedAt: Date
    let workoutID: String
    let setID: String?
    let action: String
    let value: Int
}

struct StrengthLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Controlar entrenamiento"
    static let description = IntentDescription("Completa una serie o ajusta su descanso en Éter.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Entrenamiento") var workoutID: String
    @Parameter(title: "Serie") var setID: String
    @Parameter(title: "Acción") var action: String
    @Parameter(title: "Valor") var value: Int

    init() {}
    init(workoutID: String, setID: String, action: String, value: Int) {
        self.workoutID = workoutID; self.setID = setID; self.action = action; self.value = value
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: suite)
        let key = "eter.strength.live.commands.v1"
        var commands: [LiveStrengthCommand] = []
        if let data = defaults?.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LiveStrengthCommand].self, from: data) { commands = decoded }
        commands.append(LiveStrengthCommand(
            id: UUID(), issuedAt: Date(), workoutID: workoutID,
            setID: setID.isEmpty ? nil : setID, action: action, value: value
        ))
        if let encoded = try? JSONEncoder().encode(Array(commands.suffix(30))) { defaults?.set(encoded, forKey: key) }

        for activity in Activity<StrengthLiveActivityAttributes>.activities where activity.attributes.workoutID == workoutID {
            var state = activity.content.state
            let now = Date()
            switch action {
            case "completeSet":
                guard state.canCompleteSet, state.setID == setID else { continue }
                state.completedSets = min(state.totalSetsInWorkout, state.completedSets + 1)
                state.restEndsAt = now.addingTimeInterval(TimeInterval(max(15, value)))
                state.canCompleteSet = false
            case "adjustRest":
                if let end = state.restEndsAt {
                    let adjusted = end.addingTimeInterval(TimeInterval(value))
                    state.restEndsAt = adjusted > now ? adjusted : nil
                }
            case "skipRest": state.restEndsAt = nil
            case "adjustRIR":
                let target = state.targetRIR.map { Int($0.rounded()) } ?? 2
                state.actualRIR = min(5, max(0, (state.actualRIR ?? target) + value))
            default: break
            }
            state.updatedAt = now
            await activity.update(ActivityContent(state: state, staleDate: state.restEndsAt))
        }
        return .result()
    }
}

private let suite = "group.com.angelmartinez.eterhealth"
private let snapshotKey = "eter.widget.snapshot.v1"
private let vitalsKey = "eter.widget.vitals.v1"
private let eterBackground = Color(red: 0.035, green: 0.095, blue: 0.082)
private let green = Color(red: 0.50, green: 0.78, blue: 0.39)

private struct Snapshot: Codable {
    var updatedAt: Date
    let readiness: Int
    let state: String
    let recommendation: String
    let reason: String
    let readinessConfidence: String?
    let readinessConfidenceScore: Int?
    let readinessConfidenceReason: String?
    var hrv: Int
    var restingHeartRate: Int
    let sleepHours: Double
    var energy: Int
    var energyCurve: [Double]
    var currentHour: Double
    let sleepStartHour: Double?
    let sleepEndHour: Double?
    let energyEvents: [EnergyEvent]
    let energyBasis: String
    let energyConfidence: String?
    let energyConfidenceScore: Int?
    let energyConfidenceReason: String?
    let loadRatio: Double
    let loadState: String
    // Opcional por el mismo motivo que en WidgetSnapshotStore: el decoder
    // sintetizado no usa valores por defecto, así que un campo nuevo no
    // opcional dejaría el widget en blanco con los snapshots ya guardados.
    var loadChannel: String?
    let loadConfidence: String?
    let loadConfidenceScore: Int?
    let loadConfidenceReason: String?
    let dailyLoads: [Double]
    let runningShare: Int
    let strengthShare: Int
    // Reto 1 · opcionales por el mismo motivo que loadChannel: los snapshots
    // ya guardados no los traen y el decoder sintetizado no aplica defaults.
    var hrvPoints: [HRVPoint]?
    var inputMarkers: [InputMarker]?
    var hrvBaseline: Double?
    var restingHeartRateBaseline: Double?
    var caffeineCurve: [CaffeinePoint]?
    var caffeineNowMg: Double?
    var caffeineBedtimeMg: Double?
    var caffeineBedtimeHour: Double?
    var heartRatePoints: [HeartRatePoint]?
    var restorativeWindows: [TimeWindow]?
    var strainWindows: [TimeWindow]?
    var muscleCurrent: [Double]?
    var musclePrevious: [Double]?
    var muscleCardio: [Double]?
    var muscleTargets: [Double]?

    static let sample = Snapshot(
        updatedAt: .now, readiness: 70, state: "Disponible", recommendation: "Recuperación",
        reason: "Abre Éter para actualizar tu gemelo.",
        readinessConfidence: "Media", readinessConfidenceScore: 58,
        readinessConfidenceReason: "Línea base 62% y 5 señales activas; falta el check-in de hoy.",
        hrv: 53, restingHeartRate: 56,
        sleepHours: 8.2, energy: 64,
        energyCurve: [24, 27, 31, 35, 40, 46, 52, 58, 64, 69, 74, 78, 81, 83, 82, 80, 77, 73, 69, 66, 64],
        currentHour: 10, sleepStartHour: 0, sleepEndHour: 7.5,
        energyEvents: [EnergyEvent(startHour: 8.6, endHour: 9.3, symbol: "figure.run", drain: 14)],
        energyBasis: "Noche +55 · día −7 · ejercicio −14",
        energyConfidence: "Media", energyConfidenceScore: 63,
        energyConfidenceReason: "Usa sueño, HRV y actividad; falta check-in.",
        loadRatio: 1.10, loadState: "Carga productiva", loadChannel: "aeróbica",
        loadConfidence: "Alta", loadConfidenceScore: 82,
        loadConfidenceReason: "28 días de carga observados y 8 sesiones recientes.",
        dailyLoads: [12, 0, 18, 9, 0, 31, 8, 15, 0, 24, 10, 6, 0, 28, 12, 7, 0, 20, 35, 8, 0, 16, 11, 26, 0, 14, 20, 9],
        runningShare: 72, strengthShare: 28,
        hrvPoints: [HRVPoint(hour: 6.5, value: 61), HRVPoint(hour: 7.2, value: 55), HRVPoint(hour: 9.1, value: 49)],
        inputMarkers: [InputMarker(hour: 7.0, symbol: "cup.and.saucer.fill", kind: "coffee", label: "Cafeína 95 mg"),
                       InputMarker(hour: 8.0, symbol: "snowflake", kind: "cold", label: "Frío 3 min")],
        hrvBaseline: 49, restingHeartRateBaseline: 59,
        caffeineCurve: [CaffeinePoint(hour: 7, remainingMg: 95), CaffeinePoint(hour: 12, remainingMg: 47.5), CaffeinePoint(hour: 23, remainingMg: 10)],
        caffeineNowMg: 47.5, caffeineBedtimeMg: 10, caffeineBedtimeHour: 23,
        heartRatePoints: [HeartRatePoint(hour: 0.2, bpm: 52, segment: 0), HeartRatePoint(hour: 6.8, bpm: 55, segment: 1), HeartRatePoint(hour: 8.7, bpm: 126, segment: 2), HeartRatePoint(hour: 9.3, bpm: 91, segment: 2), HeartRatePoint(hour: 10, bpm: 61, segment: 3)],
        restorativeWindows: [TimeWindow(startHour: 9.5, endHour: 10)],
        strainWindows: [TimeWindow(startHour: 8.5, endHour: 9.4)],
        muscleCurrent: [9, 18, 8, 11, 17, 4],
        musclePrevious: [7, 12, 6, 8, 13, 10],
        muscleCardio: [0, 0, 0, 0, 0, 9],
        muscleTargets: [16, 15, 10, 13, 20, 42]
    )
}

private struct VitalsSnapshot: Codable {
    let updatedAt: Date
    let hrv: Int
    let restingHeartRate: Int
    let heartRatePoints: [HeartRatePoint]
}

private struct EnergyEvent: Codable {
    let startHour: Double
    let endHour: Double
    let symbol: String
    let drain: Double
}

private struct HRVPoint: Codable {
    let hour: Double
    let value: Double
}

private struct InputMarker: Codable {
    let hour: Double
    let symbol: String
    let kind: String
    let label: String
}

private struct CaffeinePoint: Codable {
    let hour: Double
    let remainingMg: Double
}

private struct HeartRatePoint: Codable {
    let hour: Double
    let bpm: Double
    let segment: Int
}

private struct TimeWindow: Codable {
    let startHour: Double
    let endHour: Double
}

private struct Entry: TimelineEntry { let date: Date; let snapshot: Snapshot }

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let base = load().snapshot
        let now = Date()
        // Entradas precomputadas: no consumen una nueva recarga de WidgetKit y
        // permiten que energía/cafeína avancen aunque Éter no esté abierta.
        // HRV y pulso sólo cambian cuando BackgroundVitalsObserver recibe una
        // muestra real y solicita una timeline nueva.
        let entries = (0...24).map { step -> Entry in
            let date = now.addingTimeInterval(Double(step) * 15 * 60)
            return Entry(date: date, snapshot: projected(base, at: date))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
    private func load() -> Entry {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: snapshotKey),
              var value = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Entry(date: .now, snapshot: .sample)
        }
        // Las constantes vitales tienen una cadencia propia y más ligera. Sólo
        // sustituyen al snapshot completo si realmente son más recientes.
        if let vitalsData = UserDefaults(suiteName: suite)?.data(forKey: vitalsKey),
           let vitals = try? JSONDecoder().decode(VitalsSnapshot.self, from: vitalsData),
           vitals.updatedAt >= value.updatedAt {
            value.updatedAt = vitals.updatedAt
            value.hrv = vitals.hrv
            value.restingHeartRate = vitals.restingHeartRate
            value.heartRatePoints = vitals.heartRatePoints
        }
        return Entry(date: .now, snapshot: value)
    }

    private func projected(_ source: Snapshot, at date: Date) -> Snapshot {
        guard date > source.updatedAt,
              Calendar.current.isDate(date, inSameDayAs: source.updatedAt) else { return source }
        var value = source
        let elapsed = date.timeIntervalSince(source.updatedAt) / 3_600
        let wakeHour = source.sleepEndHour ?? min(8, source.currentHour)
        let awakeBefore = max(0, source.currentHour - wakeHour)
        func timeDrain(_ hours: Double) -> Double {
            min(max(0, hours), 10) * 0.90 + max(0, hours - 10) * 1.60
        }
        let incrementalDrain = timeDrain(awakeBefore + elapsed) - timeDrain(awakeBefore)
        value.energy = max(5, Int((Double(source.energy) - incrementalDrain).rounded()))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        value.currentHour = Double(components.hour ?? 0)
            + Double(components.minute ?? 0) / 60 + Double(components.second ?? 0) / 3_600
        let targetCount = max(value.energyCurve.count, Int((value.currentHour * 2).rounded(.up)) + 1)
        if targetCount > value.energyCurve.count {
            for index in value.energyCurve.count..<targetCount {
                let hour = Double(index) / 2
                let delta = timeDrain(max(0, hour - wakeHour)) - timeDrain(awakeBefore)
                value.energyCurve.append(max(5, Double(source.energy) - delta))
            }
        }
        if let curve = value.caffeineCurve, !curve.isEmpty {
            let ordered = curve.sorted { $0.hour < $1.hour }
            if let next = ordered.first(where: { $0.hour >= value.currentHour }),
               let previous = ordered.last(where: { $0.hour <= value.currentHour }),
               next.hour > previous.hour {
                let progress = (value.currentHour - previous.hour) / (next.hour - previous.hour)
                value.caffeineNowMg = previous.remainingMg + (next.remainingMg - previous.remainingMg) * progress
            } else {
                value.caffeineNowMg = ordered.last(where: { $0.hour <= value.currentHour })?.remainingMg
                    ?? ordered.first?.remainingMg
            }
        }
        return value
    }
}

private struct DecisionView: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: Double(entry.snapshot.readiness) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text("\(entry.snapshot.readiness)").font(.system(size: 31, weight: .bold, design: .rounded))
                    Text("/100").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.frame(width: 89, height: 89)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(entry.snapshot.state.uppercased()).font(.caption2.bold()).tracking(1).foregroundStyle(scoreColor)
                    confidenceBadge(entry.snapshot.readinessConfidence)
                }
                Text(entry.snapshot.recommendation).font(.title3.bold()).lineLimit(1)
                Text(entry.snapshot.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    signal("HRV", "\(entry.snapshot.hrv) ms")
                    signal("REPOSO", "\(entry.snapshot.restingHeartRate)")
                    signal("SUEÑO", String(format: "%.1f h", entry.snapshot.sleepHours))
                }
            }
        }.containerBackground(eterBackground, for: .widget).foregroundStyle(.white)
            .accessibilityHint("Confianza \(entry.snapshot.readinessConfidence ?? "baja"). \(entry.snapshot.readinessConfidenceReason ?? "Faltan señales personales.")")
    }
    private var scoreColor: Color { entry.snapshot.readiness >= 70 ? green : entry.snapshot.readiness >= 45 ? .orange : .red }
    private func signal(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.caption2.bold())
        }
    }
    private func confidenceBadge(_ value: String?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(confidenceColor(value)).frame(width: 5, height: 5)
            Text("Conf. \((value ?? "Baja").lowercased())").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
    private func confidenceColor(_ value: String?) -> Color {
        value == "Alta" ? green : value == "Media" ? .orange : .red
    }
}

private struct EnergyView: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Banco de energía", systemImage: "bolt.fill").font(.caption.bold())
                HStack(spacing: 3) {
                    Circle().fill(confidenceColor).frame(width: 5, height: 5)
                    Text("Conf. \((entry.snapshot.energyConfidence ?? "Baja").lowercased())")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if let pulse = entry.snapshot.heartRatePoints?.last?.bpm {
                    Label("\(Int(pulse.rounded()))", systemImage: "waveform.path.ecg")
                        .font(.caption2.bold()).foregroundStyle(.red)
                }
                Text("\(entry.snapshot.energy)").font(.title3.bold()).monospacedDigit().foregroundStyle(energyColor)
                Text("·").foregroundStyle(.secondary)
                Text(entry.snapshot.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            EnergyTimeline(snapshot: entry.snapshot, color: energyColor)
            HStack(spacing: 5) {
                contextMetric("HRV", value: entry.snapshot.hrv, baseline: entry.snapshot.hrvBaseline, percent: true, unit: "ms")
                Spacer(minLength: 4)
                contextMetric("Reposo", value: entry.snapshot.restingHeartRate,
                              baseline: entry.snapshot.restingHeartRateBaseline, percent: false, unit: "ppm")
            }
            if let now = entry.snapshot.caffeineNowMg, now >= 1 {
                HStack(spacing: 4) {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(.brown)
                    Text("~\(Int(now.rounded())) mg")
                    CaffeineBars(points: entry.snapshot.caffeineCurve ?? [], currentHour: entry.snapshot.currentHour)
                        .frame(height: 9)
                    Spacer(minLength: 3)
                    if let night = entry.snapshot.caffeineBedtimeMg,
                       let hour = entry.snapshot.caffeineBedtimeHour {
                        Text("\(formattedHour(hour)) · ~\(Int(night.rounded())) mg")
                    }
                }.font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text("\(label) · \(entry.snapshot.energyBasis)")
                .font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1)
        }.containerBackground(eterBackground, for: .widget).foregroundStyle(.white)
            .accessibilityHint("Confianza \(entry.snapshot.energyConfidence ?? "baja"). \(entry.snapshot.energyConfidenceReason ?? "Faltan señales personales.")")
    }
    private var energyColor: Color { entry.snapshot.energy >= 65 ? green : entry.snapshot.energy >= 35 ? .yellow : .orange }
    private var label: String { entry.snapshot.energy >= 65 ? "Disponible" : entry.snapshot.energy >= 35 ? "Dosifica" : "Recupera" }
    private var confidenceColor: Color {
        switch entry.snapshot.energyConfidence {
        case "Alta": return green
        case "Media": return .orange
        default: return .red
        }
    }
    private func contextMetric(_ name: String, value: Int, baseline: Double?, percent: Bool, unit: String) -> some View {
        let delta: Int? = baseline.flatMap { expected in
            guard expected > 0 else { return nil }
            let raw = percent ? (Double(value) - expected) / expected * 100 : Double(value) - expected
            return Int(raw.rounded())
        }
        let comparison = delta.map { "\($0 > 0 ? "+" : "")\($0)\(percent ? "%" : "")" } ?? "sin base"
        return Text("\(name) \(value) \(unit) · \(comparison)")
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
    }
    private func formattedHour(_ hour: Double) -> String {
        let minutes = (Int((hour * 12).rounded()) * 5) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct EnergyTimeline: View {
    let snapshot: Snapshot
    let color: Color
    private let hours = [0.0, 6.0, 12.0, 18.0, 24.0]

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = max(1, proxy.size.width - 27)
            let plotHeight = max(1, proxy.size.height - 17)
            let pulseHeadroom: CGFloat = 10
            let energyHeight = max(1, plotHeight - pulseHeadroom)
            ZStack(alignment: .topLeading) {
                ForEach(hours, id: \.self) { hour in
                    Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: energyHeight)
                        .offset(x: plotWidth * hour / 24)
                        .offset(y: pulseHeadroom)
                }
                if let start = snapshot.sleepStartHour, let end = snapshot.sleepEndHour, end > start {
                    Rectangle().fill(LinearGradient(colors: [Color.indigo.opacity(0.20), Color.blue.opacity(0.07)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: plotWidth * (end - start) / 24, height: energyHeight)
                        .offset(x: plotWidth * start / 24)
                        .offset(y: pulseHeadroom)
                }
                ForEach(Array((snapshot.restorativeWindows ?? []).enumerated()), id: \.offset) { _, window in
                    Rectangle().fill(LinearGradient(colors: [Color.blue.opacity(0.04), Color.cyan.opacity(0.18), Color.blue.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, plotWidth * (window.endHour - window.startHour) / 24), height: energyHeight)
                        .offset(x: plotWidth * window.startHour / 24, y: pulseHeadroom)
                }
                ForEach(Array((snapshot.strainWindows ?? []).enumerated()), id: \.offset) { _, window in
                    Rectangle().fill(LinearGradient(colors: [Color.yellow.opacity(0.04), Color.orange.opacity(0.17), Color.red.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, plotWidth * (window.endHour - window.startHour) / 24), height: energyHeight)
                        .offset(x: plotWidth * window.startHour / 24, y: pulseHeadroom)
                }
                ForEach(Array(snapshot.energyEvents.enumerated()), id: \.offset) { _, event in
                    Rectangle().fill(LinearGradient(colors: [Color.orange.opacity(0.06), Color.red.opacity(0.18), Color.orange.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, plotWidth * (event.endHour - event.startHour) / 24), height: energyHeight)
                        .offset(x: plotWidth * event.startHour / 24, y: pulseHeadroom)
                }
                LinearGradient(colors: [color.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                    .clipShape(TimelineArea(values: snapshot.energyCurve, currentHour: snapshot.currentHour))
                    .frame(width: plotWidth, height: energyHeight)
                    .offset(y: pulseHeadroom)
                TimelineLine(values: snapshot.energyCurve, currentHour: snapshot.currentHour)
                    .stroke(
                        LinearGradient(colors: [.orange, green, .yellow], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: plotWidth, height: energyHeight)
                    .offset(y: pulseHeadroom)
                PulseTimeline(points: snapshot.heartRatePoints ?? [])
                    .stroke(Color.red.opacity(0.82), style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                    .frame(width: plotWidth, height: plotHeight)
                Circle().fill(color).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .position(
                        x: plotWidth * min(24, max(0, snapshot.currentHour)) / 24,
                        y: pulseHeadroom + energyHeight * (1 - min(100, max(0, snapshot.energyCurve.last ?? Double(snapshot.energy))) / 100)
                    )
                ForEach(Array((snapshot.inputMarkers ?? []).enumerated()), id: \.offset) { index, marker in
                    ZStack {
                        Circle().fill(inputColor(marker.kind).opacity(0.20)).frame(width: 14, height: 14)
                        Image(systemName: marker.symbol).font(.system(size: 7, weight: .bold))
                            .foregroundStyle(inputColor(marker.kind))
                    }
                    .position(
                        x: min(plotWidth - 7, max(7, plotWidth * marker.hour / 24)),
                        y: pulseHeadroom + energyHeight - 7 - CGFloat(index % 2) * 13
                    )
                }
                Text("100").font(.system(size: 8)).foregroundStyle(.secondary)
                    .position(x: plotWidth + 15, y: pulseHeadroom + 3)
                Text("0").font(.system(size: 8)).foregroundStyle(.secondary)
                    .position(x: plotWidth + 11, y: plotHeight - 3)
                ForEach(hours.dropLast(), id: \.self) { hour in
                    Text(String(format: "%02d", Int(hour))).font(.system(size: 8)).foregroundStyle(.secondary)
                        .position(x: min(plotWidth - 8, max(8, plotWidth * hour / 24)), y: proxy.size.height - 4)
                }
            }
        }
        .frame(height: 102)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banco de energía durante el día")
        .accessibilityValue("\(snapshot.energy) a las \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
    }

    private func inputColor(_ kind: String) -> Color {
        switch kind {
        case "sauna": return .red
        case "cold": return .cyan
        case "coffee": return .brown
        case "alcohol": return .purple
        case "supplement": return .teal
        case "food": return .green
        case "stress": return .pink
        case "rest": return .blue
        case "sleep": return .indigo
        case "travel": return .mint
        default: return .gray
        }
    }
}

private struct TimelineLine: Shape {
    let values: [Double]
    let currentHour: Double
    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var result = Path()
        for (index, value) in values.enumerated() {
            let progress = CGFloat(index) / CGFloat(values.count - 1)
            let point = CGPoint(
                x: rect.width * progress * CGFloat(min(24, max(0, currentHour)) / 24),
                y: rect.height * (1 - CGFloat(min(100, max(0, value)) / 100))
            )
            index == 0 ? result.move(to: point) : result.addLine(to: point)
        }
        return result
    }
}

private struct TimelineArea: Shape {
    let values: [Double]
    let currentHour: Double
    func path(in rect: CGRect) -> Path {
        var result = TimelineLine(values: values, currentHour: currentHour).path(in: rect)
        let endX = rect.width * CGFloat(min(24, max(0, currentHour)) / 24)
        result.addLine(to: CGPoint(x: endX, y: rect.maxY))
        result.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        result.closeSubpath()
        return result
    }
}

/// Pulso real sobre la misma escala numérica 0–100 que la energía. Las ppm
/// superiores a 100 ocupan una pequeña franja superior comprimida; los saltos
/// de `segment` quedan sin unir para no inventar señal durante huecos de Salud.
private struct PulseTimeline: Shape {
    let points: [HeartRatePoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let headroom: CGFloat = 10
        let energyHeight = max(1, rect.height - headroom)
        var previousSegment: Int?
        for point in points.sorted(by: { $0.hour < $1.hour }) {
            let x = rect.width * CGFloat(min(24, max(0, point.hour)) / 24)
            let y: CGFloat
            if point.bpm <= 100 {
                y = headroom + energyHeight * (1 - CGFloat(max(0, point.bpm) / 100))
            } else {
                y = headroom * (1 - CGFloat(min(1, (point.bpm - 100) / 80)))
            }
            let position = CGPoint(x: x, y: y)
            if previousSegment == point.segment { path.addLine(to: position) }
            else { path.move(to: position) }
            previousSegment = point.segment
        }
        return path
    }
}

private struct CaffeineBars: View {
    let points: [CaffeinePoint]
    let currentHour: Double
    var body: some View {
        let peak = max(1, points.map(\.remainingMg).max() ?? 1)
        HStack(alignment: .bottom, spacing: 0.7) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Capsule()
                    .fill(Color.brown.opacity(point.hour <= currentHour ? 0.9 : 0.4))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(1, 9 * point.remainingMg / peak))
            }
        }
    }
}

private struct Line: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var result = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * CGFloat(index) / CGFloat(values.count - 1), y: rect.height * (1 - CGFloat(value / 100)))
            index == 0 ? result.move(to: point) : result.addLine(to: point)
        }
        return result
    }
}

private struct Area: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var result = Line(values: values).path(in: rect)
        result.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        result.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); result.closeSubpath()
        return result
    }
}

private struct LoadView: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("CARGA HÍBRIDA").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                    Circle().fill(confidenceColor).frame(width: 5, height: 5)
                    Text("Conf. \((entry.snapshot.loadConfidence ?? "Baja").lowercased())")
                        .font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                }
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(entry.snapshot.loadRatio > 0 ? String(format: "%.2f", entry.snapshot.loadRatio) : "—")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    // De qué canal es ese ratio: manda el más exigido, y sin
                    // decir cuál el número no se puede interpretar.
                    if let channel = entry.snapshot.loadChannel, entry.snapshot.loadRatio > 0 {
                        Text(channel).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                Label(entry.snapshot.loadState, systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(loadColor)
                Text("Running \(entry.snapshot.runningShare)% · Fuerza \(entry.snapshot.strengthShare)%")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(width: 135, alignment: .leading)
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(loadColor.opacity(0.18)).frame(height: proxy.size.height * 0.35)
                    Line(values: normalizedLoads).stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }.containerBackground(eterBackground, for: .widget).foregroundStyle(.white)
            .accessibilityHint("Confianza \(entry.snapshot.loadConfidence ?? "baja"). \(entry.snapshot.loadConfidenceReason ?? "Falta historial de carga.")")
    }
    private var confidenceColor: Color {
        entry.snapshot.loadConfidence == "Alta" ? green : entry.snapshot.loadConfidence == "Media" ? .orange : .red
    }
    private var loadColor: Color { (0.65..<1.30).contains(entry.snapshot.loadRatio) ? green : entry.snapshot.loadRatio < 1.55 ? .orange : .red }
    private var normalizedLoads: [Double] {
        let values = Array(entry.snapshot.dailyLoads.suffix(18)); let maximum = max(1, values.max() ?? 1)
        return values.map { 15 + $0 / maximum * 75 }
    }
}

private struct MuscleMatrixView: View {
    let entry: Entry
    private let axes = ["Espalda", "Pecho", "Core", "Hombros", "Brazos", "Piernas"]
    // El snapshot transporta los mismos MAV personales del ciclo que la app.
    // El fallback mantiene legibles snapshots escritos por versiones previas.
    private var strengthTargets: [Double] {
        let values = entry.snapshot.muscleTargets ?? []
        return values.count == axes.count ? values : [16, 15, 10, 13, 20, 42]
    }
    private let cardioTargets = [4.0, 4.0, 4.0, 4.0, 4.0, 8.0].map { $0 * 7 / 10 }

    var body: some View {
        HStack(spacing: 12) {
            CompactRadar(current: normalized(entry.snapshot.muscleCurrent, targets: strengthTargets, cap: 1.15),
                         previous: normalized(entry.snapshot.musclePrevious, targets: strengthTargets),
                         cardio: normalized(entry.snapshot.muscleCardio, targets: cardioTargets))
                .frame(width: 145, height: 135)
            VStack(alignment: .leading, spacing: 6) {
                Text("MATRIZ MUSCULAR").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                Text("Últimos 7 días").font(.headline)
                ForEach(priorityRows, id: \.0) { row in
                    HStack {
                        Text(row.0).lineLimit(1)
                        Spacer()
                        Text("\(row.1)%").monospacedDigit().foregroundStyle(row.1 >= 70 ? green : .secondary)
                    }.font(.caption2.bold())
                }
                if cardioLegPercent > 0 {
                    Label("Piernas · cardio \(cardioLegPercent)%", systemImage: "figure.run")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    legend("Actual", .blue)
                    legend("Anterior", .gray)
                    legend("Cardio", .orange)
                }
            }
        }
        .containerBackground(eterBackground, for: .widget).foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Matriz muscular de los últimos siete días")
        .accessibilityValue(priorityRows.map { "\($0.0) \($0.1) por ciento" }.joined(separator: ", "))
    }

    private func normalized(_ values: [Double]?, targets: [Double], cap: Double = 1) -> [Double] {
        let values = values ?? Array(repeating: 0, count: axes.count)
        return axes.indices.map { min(cap, (values.indices.contains($0) ? values[$0] : 0) / targets[$0]) }
    }
    private var strengthPercents: [Int] {
        let values = entry.snapshot.muscleCurrent ?? []
        return axes.indices.map { Int(((values.indices.contains($0) ? values[$0] : 0) / strengthTargets[$0] * 100).rounded()) }
    }
    private var priorityRows: [(String, Int)] {
        zip(axes, strengthPercents).sorted { $0.1 < $1.1 }.prefix(3).map { ($0.0, $0.1) }
    }
    private var cardioLegPercent: Int {
        let values = entry.snapshot.muscleCardio ?? []
        return values.count > 5 ? Int((values[5] / cardioTargets[5] * 100).rounded()) : 0
    }
    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 5, height: 5); Text(label) }
            .font(.system(size: 7)).foregroundStyle(.secondary)
    }
}

private struct CompactRadar: View {
    let current: [Double]
    let previous: [Double]
    let cardio: [Double]
    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) * 0.39
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            Canvas { context, _ in
                for level in 1...4 {
                    context.stroke(polygon(center, radius * CGFloat(level) / 4, Array(repeating: 1, count: 6)),
                                   with: .color(.white.opacity(0.11)), lineWidth: 0.8)
                }
                context.fill(polygon(center, radius, current), with: .color(.blue.opacity(0.22)))
                context.stroke(polygon(center, radius, previous), with: .color(.gray.opacity(0.8)), lineWidth: 1.4)
                context.stroke(polygon(center, radius, current), with: .color(.blue), lineWidth: 2.2)
                for index in cardio.indices where cardio[index] > 0 {
                    let end = point(center, radius * min(1, cardio[index]), index)
                    var path = Path(); path.move(to: center); path.addLine(to: end)
                    context.stroke(path, with: .color(.orange),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)),
                                 with: .color(.orange))
                }
            }
        }
    }
    private func polygon(_ center: CGPoint, _ radius: CGFloat, _ values: [Double]) -> Path {
        var path = Path()
        for index in 0..<6 {
            let value = values.indices.contains(index) ? min(1, max(0, values[index])) : 0
            let p = point(center, radius * CGFloat(value), index)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath(); return path
    }
    private func point(_ center: CGPoint, _ radius: CGFloat, _ index: Int) -> CGPoint {
        let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * CGFloat.pi / 6
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}

struct DecisionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EterDecisionWidget", provider: Provider()) { DecisionView(entry: $0) }
            .configurationDisplayName("Decisión de hoy").description("Readiness y recomendación del gemelo.")
            .supportedFamilies([.systemMedium])
    }
}

struct EnergyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EterEnergyWidget", provider: Provider()) { EnergyView(entry: $0) }
            .configurationDisplayName("Banco de energía").description("Energía estimada durante el día.")
            .supportedFamilies([.systemMedium])
    }
}

struct LoadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EterLoadWidget", provider: Provider()) { LoadView(entry: $0) }
            .configurationDisplayName("Carga híbrida").description("Carga reciente y equilibrio de entrenamiento.")
            .supportedFamilies([.systemMedium])
    }
}

struct MuscleMatrixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EterMuscleMatrixWidget", provider: Provider()) { MuscleMatrixView(entry: $0) }
            .configurationDisplayName("Matriz muscular")
            .description("Fuerza reciente y carga muscular del cardio.")
            .supportedFamilies([.systemMedium])
    }
}

private struct StrengthTrainingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StrengthLiveActivityAttributes.self) { context in
            StrengthLockScreenActivityView(context: context)
                .activityBackgroundTint(eterBackground.opacity(0.96))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.routineName, systemImage: "dumbbell.fill")
                        .font(.caption.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) { activityProgress(context.state) }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.exerciseName).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StrengthActivityControls(attributes: context.attributes, state: context.state, compact: true)
                }
            } compactLeading: {
                Image(systemName: context.state.restEndsAt.map { $0 > Date() } == true ? "timer" : "dumbbell.fill")
                    .foregroundStyle(context.state.restEndsAt.map { $0 > Date() } == true ? .orange : green)
            } compactTrailing: {
                if let end = context.state.restEndsAt, end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.caption2.bold()).monospacedDigit().foregroundStyle(.orange).frame(width: 45)
                } else {
                    Text("S\(context.state.setNumber)").font(.caption.bold()).foregroundStyle(green)
                }
            } minimal: {
                if let end = context.state.restEndsAt, end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.orange)
                } else {
                    Image(systemName: "dumbbell.fill").foregroundStyle(green)
                }
            }
            .keylineTint(green)
        }
    }

    @ViewBuilder private func activityProgress(_ state: StrengthLiveActivityAttributes.ContentState) -> some View {
        if let end = state.restEndsAt, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .font(.headline.bold()).monospacedDigit().foregroundStyle(.orange)
        } else {
            Text("\(state.completedSets)/\(state.totalSetsInWorkout)")
                .font(.headline.bold()).monospacedDigit().foregroundStyle(green)
        }
    }
}

private struct StrengthLockScreenActivityView: View {
    let context: ActivityViewContext<StrengthLiveActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.routineName, systemImage: "dumbbell.fill")
                    .font(.subheadline.bold()).foregroundStyle(green).lineLimit(1)
                Spacer()
                Text("\(context.state.completedSets)/\(context.state.totalSetsInWorkout) series")
                    .font(.subheadline.bold()).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.exerciseName).font(.title3.bold()).lineLimit(1)
                    Text(setDescription(context.state)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let end = context.state.restEndsAt, end > Date() {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.orange)
                        .minimumScaleFactor(0.75)
                }
            }
            StrengthActivityControls(attributes: context.attributes, state: context.state, compact: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(height: 160)
        .foregroundStyle(.white)
    }

    private func setDescription(_ state: StrengthLiveActivityAttributes.ContentState) -> String {
        var parts = ["Serie \(state.setNumber)/\(state.totalSets)"]
        if state.weight > 0 { parts.append(String(format: "%.1f kg", state.weight)) }
        if state.reps > 0 { parts.append("\(state.reps) reps") }
        if let rir = state.targetRIR { parts.append("objetivo RIR \(rir == rir.rounded() ? String(Int(rir)) : String(format: "%.1f", rir))") }
        return parts.joined(separator: " · ")
    }
}

private struct StrengthActivityControls: View {
    let attributes: StrengthLiveActivityAttributes
    let state: StrengthLiveActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            if let end = state.restEndsAt, end > Date() {
                HStack(spacing: compact ? 7 : 10) {
                    control("−15 s", action: "adjustRest", value: -15, tint: .orange)
                    control("Omitir", action: "skipRest", value: 0, tint: .secondary)
                    control("+15 s", action: "adjustRest", value: 15, tint: .orange)
                }
            } else if state.canCompleteSet {
                HStack(spacing: compact ? 6 : 8) {
                    control("−", action: "adjustRIR", value: -1, tint: green)
                        .frame(maxWidth: compact ? 48 : 52)
                    Text("RIR \(displayRIR)")
                        .font((compact ? Font.caption : Font.subheadline).bold())
                        .monospacedDigit().frame(minWidth: compact ? 45 : 54)
                    control("+", action: "adjustRIR", value: 1, tint: green)
                        .frame(maxWidth: compact ? 48 : 52)
                    Button(intent: StrengthLiveActivityIntent(
                        workoutID: attributes.workoutID, setID: state.setID,
                        action: "completeSet", value: state.restSeconds
                    )) {
                        Label("Completar", systemImage: "checkmark.circle.fill")
                            .font((compact ? Font.caption : Font.subheadline).bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(green)
                }
            } else {
                Label("Entrenamiento completado", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold()).foregroundStyle(green).frame(maxWidth: .infinity)
            }
        }
    }

    private var displayRIR: Int {
        state.actualRIR ?? state.targetRIR.map { Int($0.rounded()) } ?? 2
    }

    private func control(_ title: String, action: String, value: Int, tint: Color) -> some View {
        Button(intent: StrengthLiveActivityIntent(
            workoutID: attributes.workoutID, setID: state.setID,
            action: action, value: value
        )) {
            Text(title).font((compact ? Font.caption : Font.subheadline).bold())
                .frame(maxWidth: .infinity, minHeight: compact ? 28 : 34)
        }
        .buttonStyle(.bordered).tint(tint)
    }
}

@main
struct EterWidgets: WidgetBundle {
    var body: some Widget {
        DecisionWidget(); EnergyWidget(); LoadWidget(); MuscleMatrixWidget()
        StrengthTrainingLiveActivityWidget()
    }
}
