import SwiftUI
import Charts

/// Curva modelada de energía y contexto que puede explicar sus cambios. HRV y
/// pulso en reposo son señales diarias, no series intradía comparables con una
/// batería: se muestran contra la línea base personal y no contaminan el chart.
struct TodayTrendsCardView: View {
    let result: EnergyTimelineEngine.Result

    private struct CurvePoint: Identifiable { let id: Int; let hour: Double; let value: Double }

    // Mismo mapeo índice→hora que EnergyTimelineEngine.energyModel (pasos de
    // media hora, tope en la hora actual).
    private var curvePoints: [CurvePoint] {
        result.curve.enumerated().map { index, value in
            CurvePoint(id: index, hour: min(result.currentHour, Double(index) / 2), value: value)
        }
    }

    private let energyGradient = LinearGradient(
        colors: [Color(red: 0.90, green: 0.55, blue: 0.30), Color(red: 0.50, green: 0.78, blue: 0.39)],
        startPoint: .bottom, endPoint: .top
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            physiologicalContext
            chart.frame(height: 210)
            legend
            Text("Curva de energía estimada (0–100). Los iconos sitúan eventos registrados que aportan contexto; no demuestran por sí solos causalidad. \(result.basis).")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tendencias de hoy").font(.headline)
                Text("Tu batería del día y cómo responden tus señales").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(result.energy)").font(.title2.bold()).fontDesign(.rounded).foregroundStyle(energyColor)
                Text("energía").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var physiologicalContext: some View {
        HStack(spacing: 10) {
            metricContext(title: "HRV", unit: "ms", metric: result.hrv, percentComparison: true)
            Divider().frame(height: 42)
            metricContext(title: "Reposo", unit: "ppm", metric: result.restingHeartRate, percentComparison: false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricContext(title: String, unit: String, metric: EnergyTimelineEngine.DailyMetricContext,
                               percentComparison: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            if let value = metric.value {
                Text("\(Int(value.rounded())) \(unit)").font(.headline).fontDesign(.rounded)
                Text(comparison(metric, percent: percentComparison))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text("Sin dato").font(.headline).foregroundStyle(.secondary)
                Text("Aún sin lectura de hoy").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func comparison(_ metric: EnergyTimelineEngine.DailyMetricContext, percent: Bool) -> String {
        guard let value = metric.value, let expected = metric.expected, expected > 0 else {
            return "Línea base aún insuficiente"
        }
        let delta = percent ? (value - expected) / expected * 100 : value - expected
        let rounded = Int(delta.rounded())
        let signed = rounded > 0 ? "+\(rounded)" : "\(rounded)"
        return "\(signed)\(percent ? "%" : "") frente a tu normal"
    }

    private var chart: some View {
        Chart {
            if let start = result.sleepStartHour, let end = result.sleepEndHour, end > start {
                RectangleMark(
                    xStart: .value("Inicio", start), xEnd: .value("Fin", end),
                    yStart: .value("min", 0), yEnd: .value("max", 100)
                ).foregroundStyle(Color.indigo.opacity(0.10))
            }
            ForEach(curvePoints) { point in
                AreaMark(x: .value("Hora", point.hour), y: .value("Energía", point.value))
                    .foregroundStyle(LinearGradient(colors: [energyColor.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(curvePoints) { point in
                LineMark(x: .value("Hora", point.hour), y: .value("Energía", point.value))
                    .foregroundStyle(energyGradient)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            }
            if let last = curvePoints.last {
                PointMark(x: .value("Hora", last.hour), y: .value("Energía", last.value))
                    .foregroundStyle(energyColor)
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let hour = value.as(Int.self) { Text(String(format: "%02d", hour)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let energy = value.as(Int.self) { Text("\(energy)") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    // Entrenamientos arriba, inputs de estilo de vida abajo, para
                    // que no se pisen y se lean como dos capas distintas.
                    ForEach(Array(result.events.enumerated()), id: \.offset) { index, event in
                        marker(proxy: proxy, rect: rect, hour: (event.startHour + event.endHour) / 2,
                               symbol: event.symbol, color: .orange, y: rect.minY + 10 + CGFloat(index % 2) * 22)
                    }
                    ForEach(Array(result.inputMarkers.enumerated()), id: \.offset) { index, input in
                        marker(proxy: proxy, rect: rect, hour: input.hour,
                               symbol: input.symbol, color: inputColor(input.kind),
                               y: rect.maxY - 10 - CGFloat(index % 2) * 22)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tendencias de hoy")
        .accessibilityValue(accessibilitySummary)
    }

    @ViewBuilder
    private func marker(proxy: ChartProxy, rect: CGRect, hour: Double, symbol: String, color: Color, y: CGFloat) -> some View {
        if let x = proxy.position(forX: hour) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 20, height: 20)
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            }
            .position(x: rect.minX + x, y: y)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Energía", systemImage: "bolt.fill").foregroundStyle(energyColor)
            if !result.inputMarkers.isEmpty { Label("Contexto", systemImage: "circle.fill").foregroundStyle(.teal) }
            if !result.events.isEmpty { Label("Ejercicio", systemImage: "circle.fill").foregroundStyle(.orange) }
        }.font(.caption2).frame(maxWidth: .infinity)
    }

    private var energyColor: Color {
        result.energy >= 65 ? Color(red: 0.50, green: 0.78, blue: 0.39) : result.energy >= 35 ? .yellow : .orange
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

    private var accessibilitySummary: String {
        var parts = ["Energía actual \(result.energy) de 100. \(result.basis)."]
        if let value = result.hrv.value { parts.append("HRV \(Int(value.rounded())) milisegundos. \(comparison(result.hrv, percent: true)).") }
        if let value = result.restingHeartRate.value { parts.append("Pulso en reposo \(Int(value.rounded())) pulsaciones por minuto. \(comparison(result.restingHeartRate, percent: false)).") }
        if !result.inputMarkers.isEmpty {
            parts.append("Inputs: " + result.inputMarkers.map(\.label).joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}
