import SwiftUI
import WidgetKit

private let suite = "group.com.angelmartinez.eterhealth"
private let snapshotKey = "eter.widget.snapshot.v1"
private let eterBackground = Color(red: 0.035, green: 0.095, blue: 0.082)
private let green = Color(red: 0.50, green: 0.78, blue: 0.39)

private struct Snapshot: Codable {
    let updatedAt: Date
    let readiness: Int
    let state: String
    let recommendation: String
    let reason: String
    let readinessConfidence: String?
    let readinessConfidenceScore: Int?
    let readinessConfidenceReason: String?
    let hrv: Int
    let restingHeartRate: Int
    let sleepHours: Double
    let energy: Int
    let energyCurve: [Double]
    let currentHour: Double
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
        runningShare: 72, strengthShare: 28
    )
}

private struct EnergyEvent: Codable {
    let startHour: Double
    let endHour: Double
    let symbol: String
    let drain: Double
}

private struct Entry: TimelineEntry { let date: Date; let snapshot: Snapshot }

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
    private func load() -> Entry {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: snapshotKey),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Entry(date: .now, snapshot: .sample)
        }
        return Entry(date: .now, snapshot: value)
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
                Text("\(entry.snapshot.energy)").font(.title3.bold()).monospacedDigit().foregroundStyle(energyColor)
                Text("·").foregroundStyle(.secondary)
                Text(entry.snapshot.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            EnergyTimeline(snapshot: entry.snapshot, color: energyColor)
            HStack(spacing: 5) {
                Text(label).font(.caption2.bold()).foregroundStyle(energyColor)
                Text("· \(entry.snapshot.energyBasis)").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(entry.snapshot.energyConfidenceReason ?? "Confianza limitada hasta actualizar las señales personales.")
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
}

private struct EnergyTimeline: View {
    let snapshot: Snapshot
    let color: Color
    private let hours = [0.0, 6.0, 12.0, 18.0, 24.0]

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = max(1, proxy.size.width - 27)
            let plotHeight = max(1, proxy.size.height - 17)
            ZStack(alignment: .topLeading) {
                ForEach(hours, id: \.self) { hour in
                    Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: plotHeight)
                        .offset(x: plotWidth * hour / 24)
                }
                if let start = snapshot.sleepStartHour, let end = snapshot.sleepEndHour, end > start {
                    Rectangle().fill(Color.indigo.opacity(0.14))
                        .frame(width: plotWidth * (end - start) / 24, height: plotHeight)
                        .offset(x: plotWidth * start / 24)
                    Image(systemName: "moon.fill").font(.system(size: 10)).foregroundStyle(.indigo)
                        .position(x: plotWidth * ((start + end) / 2) / 24, y: 7)
                }
                ForEach(Array(snapshot.energyEvents.enumerated()), id: \.offset) { _, event in
                    Rectangle().fill(Color.orange.opacity(0.14))
                        .frame(width: max(2, plotWidth * (event.endHour - event.startHour) / 24), height: plotHeight)
                        .offset(x: plotWidth * event.startHour / 24)
                    Image(systemName: event.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                        .position(x: plotWidth * ((event.startHour + event.endHour) / 2) / 24, y: 7)
                }
                LinearGradient(colors: [color.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                    .clipShape(TimelineArea(values: snapshot.energyCurve, currentHour: snapshot.currentHour))
                    .frame(width: plotWidth, height: plotHeight)
                TimelineLine(values: snapshot.energyCurve, currentHour: snapshot.currentHour)
                    .stroke(
                        LinearGradient(colors: [.orange, green, .yellow], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: plotWidth, height: plotHeight)
                Circle().fill(color).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .position(
                        x: plotWidth * min(24, max(0, snapshot.currentHour)) / 24,
                        y: plotHeight * (1 - min(100, max(0, snapshot.energyCurve.last ?? Double(snapshot.energy))) / 100)
                    )
                Text("100").font(.system(size: 8)).foregroundStyle(.secondary)
                    .position(x: plotWidth + 15, y: 5)
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

@main
struct EterWidgets: WidgetBundle {
    var body: some Widget { DecisionWidget(); EnergyWidget(); LoadWidget() }
}
