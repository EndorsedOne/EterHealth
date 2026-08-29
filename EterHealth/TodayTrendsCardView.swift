import SwiftUI
import Charts

/// Reto 1 · "Tendencias de hoy". La curva modelada de energía ("tu batería",
/// estilo Bevel) de fondo, los puntos REALES de HRV medidos hoy encima, y los
/// inputs del día (sauna, frío, café, alcohol, suplementos) más los
/// entrenamientos superpuestos como marcadores con su hora. Todo comparte el
/// mismo eje de tiempo, así se ve el input y su respuesta fisiológica en el
/// mismo sitio. Comparte el modelo (EnergyTimelineEngine) con el widget para no
/// dibujar dos curvas distintas.
struct TodayTrendsCardView: View {
    let result: EnergyTimelineEngine.Result
    let hrvSamples: [TrendPoint]
    let restingHeartRate: Int
    let referenceDate: Date

    private struct CurvePoint: Identifiable { let id: Int; let hour: Double; let value: Double }
    private struct HRVPoint: Identifiable { let id: Int; let hour: Double; let value: Double; let normalized: Double }

    // Mismo mapeo índice→hora que EnergyTimelineEngine.energyModel (pasos de
    // media hora, tope en la hora actual).
    private var curvePoints: [CurvePoint] {
        result.curve.enumerated().map { index, value in
            CurvePoint(id: index, hour: min(result.currentHour, Double(index) / 2), value: value)
        }
    }

    private var hrvPoints: [HRVPoint] {
        let startOfDay = Calendar.current.startOfDay(for: referenceDate)
        let values = hrvSamples.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return [] }
        let span = max(1, hi - lo)
        return hrvSamples.enumerated().map { index, point in
            let hour = point.date.timeIntervalSince(startOfDay) / 3600
            // Cuando todas las muestras son casi iguales, span→1 y todo se
            // aplasta arriba; centrar en 50 es más honesto que apilar en 100.
            let normalized = hi == lo ? 50 : (point.value - lo) / span * 100
            return HRVPoint(id: index, hour: hour, value: point.value, normalized: normalized)
        }
    }

    private let energyGradient = LinearGradient(
        colors: [Color(red: 0.90, green: 0.55, blue: 0.30), Color(red: 0.50, green: 0.78, blue: 0.39)],
        startPoint: .bottom, endPoint: .top
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chart.frame(height: 210)
            legend
            Text("Curva de energía modelada (izquierda, 0–100) · puntos de HRV reales medidos hoy (derecha, ms). \(result.basis).")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tendencias de hoy").font(.headline)
                Text("Tu batería del día y cómo responden tus señales").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(result.energy)").font(.title2.bold()).fontDesign(.rounded).foregroundStyle(energyColor)
                Text("energía").font(.caption2).foregroundStyle(.secondary)
            }
            if restingHeartRate > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(restingHeartRate)").font(.title2.bold()).fontDesign(.rounded)
                    Text("reposo ppm").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hrvRange: (min: Double, max: Double)? {
        let values = hrvSamples.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi)
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
            ForEach(hrvPoints) { point in
                PointMark(x: .value("Hora", point.hour), y: .value("HRV", point.normalized))
                    .foregroundStyle(Color.purple)
                    .symbolSize(46)
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
            if let range = hrvRange {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text("\(Int((range.min + (range.max - range.min) * fraction / 100).rounded()))")
                                .foregroundStyle(Color.purple.opacity(0.9))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    // Entrenamientos arriba, inputs de estilo de vida abajo, para
                    // que no se pisen y se lean como dos capas distintas.
                    ForEach(Array(result.events.enumerated()), id: \.offset) { _, event in
                        marker(proxy: proxy, rect: rect, hour: (event.startHour + event.endHour) / 2,
                               symbol: event.symbol, color: .orange, y: rect.minY + 10)
                    }
                    ForEach(Array(result.inputMarkers.enumerated()), id: \.offset) { _, input in
                        marker(proxy: proxy, rect: rect, hour: input.hour,
                               symbol: input.symbol, color: inputColor(input.kind), y: rect.maxY - 10)
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
            if !hrvPoints.isEmpty { Label("HRV real", systemImage: "circle.fill").foregroundStyle(.purple) }
            if !result.inputMarkers.isEmpty { Label("Inputs", systemImage: "circle.fill").foregroundStyle(.teal) }
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
        default: return .gray
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Energía actual \(result.energy) de 100. \(result.basis)."]
        if let range = hrvRange {
            parts.append("HRV de hoy entre \(Int(range.min)) y \(Int(range.max)) milisegundos en \(hrvSamples.count) muestras.")
        }
        if !result.inputMarkers.isEmpty {
            parts.append("Inputs: " + result.inputMarkers.map(\.label).joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}
