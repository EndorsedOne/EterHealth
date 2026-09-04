import SwiftUI

/// "Distancia al objetivo": dónde estás y qué falta para cada objetivo. Se
/// reparte por tipo — los objetivos de fuerza (`strengthOnly: true`) viven en la
/// pestaña Fuerza; los de carrera e híbridos (HYROX, triatlón), en Rendimiento.
/// Componente propio para que ambas pestañas lo compongan con el mismo render.
struct GoalDistanceCard: View {
    /// true = sólo objetivos de fuerza; false = sólo carrera/híbridos.
    let strengthOnly: Bool
    let distances: [GoalDistance]

    var body: some View {
        let visibleDistances = distances.filter { $0.goal.kind.isStrength == strengthOnly }

        return Group {
            if !visibleDistances.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    EterSectionHeader(strengthOnly ? "Fuerza: dónde estás y qué falta" : "Dónde estás y qué falta",
                                      eyebrow: "Distancia al objetivo")
                    ForEach(visibleDistances) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.goal.title).font(.headline)
                                if let days = item.daysRemaining {
                                    Text("\(days) días").font(.caption2.bold()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle().fill(item.confidence.color).frame(width: 7, height: 7)
                                Text(item.confidence.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                metric("Actual", item.current)
                                metric("Objetivo", item.target)
                            }
                            if let progress = item.progress {
                                ProgressView(value: progress).tint(color(item.state))
                                Text("Proximidad de marca \(Int((progress * 100).rounded()))% · \(item.gap)")
                                    .font(.caption.bold()).foregroundStyle(color(item.state))
                            } else {
                                Text(item.gap).font(.caption).foregroundStyle(.secondary).lineSpacing(2)
                            }
                            Text(item.evidence).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if item.id != visibleDistances.last?.id { Divider() }
                    }
                    Text("La proximidad compara la marca actual estimada con el objetivo; no representa el porcentaje de preparación total para competir.")
                        .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                }.cardStyle()
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ state: GoalDistanceState) -> Color {
        switch state {
        case .achieved: return EterTheme.positive
        case .close: return EterTheme.primary
        case .progressing: return EterTheme.warning
        case .missingTarget, .insufficientData: return .secondary
        }
    }
}
