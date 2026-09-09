import SwiftUI

/// Composición segmental (masa magra por zona) del último InBody: valores por
/// brazo/pierna/tronco y asimetría izquierda/derecha. Se muestra junto a la
/// distribución muscular de entreno para decidir dónde meter volumen.
struct InBodySegmentalSection: View {
    @EnvironmentObject private var inBody: InBodyStore

    var body: some View {
        if let latest = inBody.latest, latest.hasSegmental {
            content(latest)
        }
    }

    @ViewBuilder
    private func content(_ measurement: InBodyMeasurement) -> some View {
        let maxValue = [measurement.armLeanLeftPercent, measurement.armLeanRightPercent,
                        measurement.legLeanLeftPercent, measurement.legLeanRightPercent,
                        measurement.trunkLeanPercent].compactMap { $0 }.max() ?? 100
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Composición segmental").font(.headline)
                    Text("Masa magra por zona · % vs ideal (InBody)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(measurement.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            segmentRow("Brazo izquierdo", measurement.armLeanLeftPercent, maxValue)
            segmentRow("Brazo derecho", measurement.armLeanRightPercent, maxValue)
            segmentRow("Pierna izquierda", measurement.legLeanLeftPercent, maxValue)
            segmentRow("Pierna derecha", measurement.legLeanRightPercent, maxValue)
            segmentRow("Tronco", measurement.trunkLeanPercent, maxValue)
            Divider()
            asymmetry("Brazos", measurement.armLeanLeftPercent, measurement.armLeanRightPercent)
            asymmetry("Piernas", measurement.legLeanLeftPercent, measurement.legLeanRightPercent)
            Text("Cada zona es el % de masa magra vs tu ideal (100% = ideal). La asimetría compara lado izquierdo y derecho; por encima del ~10% conviene revisar técnica y añadir trabajo unilateral del lado más débil. Crúzalo con tu Distribución muscular de arriba para decidir dónde meter volumen.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func segmentRow(_ name: String, _ value: Double?, _ maxValue: Double) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.caption).frame(width: 116, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if let value {
                        Capsule().fill(EterTheme.positive.opacity(0.78))
                            .frame(width: max(4, proxy.size.width * (value / max(maxValue, 0.001))))
                    }
                }
            }.frame(height: 8)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "—")
                .font(.caption.monospacedDigit()).frame(width: 58, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func asymmetry(_ title: String, _ left: Double?, _ right: Double?) -> some View {
        if let left, let right, left > 0, right > 0 {
            let diff = abs(left - right) / max(left, right) * 100
            let stronger = left > right ? "izquierdo" : "derecho"
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(title) · asimetría izq/der").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f%%", diff)).font(.caption.bold().monospacedDigit())
                        .foregroundStyle(asymmetryColor(diff))
                }
                if diff >= 10 {
                    Text("Lado \(stronger) más fuerte; prioriza trabajo unilateral del otro lado.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func asymmetryColor(_ diff: Double) -> Color {
        diff >= 10 ? EterTheme.negative : diff >= 5 ? .orange : EterTheme.positive
    }
}
