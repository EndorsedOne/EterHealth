import SwiftUI
import Charts

struct BodyCompositionCardView: View {
    @EnvironmentObject private var health: HealthStore
    @Binding var showBodyComposition: Bool
    @Binding var bodyMeasurementPendingEdit: BodyMeasurement?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Composición corporal").font(.headline)
                    Text("Peso, grasa corporal y masa magra").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: HealthDataTrust.trend(title: "Peso", points: health.bodyWeightHistory, health: health))
            }
            Button { bodyMeasurementPendingEdit = nil; showBodyComposition = true } label: {
                Label("Añadir medición", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            HStack(spacing: 10) {
                bodyValue("Peso", health.bodyWeightHistory.last?.value, "kg")
                bodyValue("Grasa", health.bodyFatHistory.last?.value, "%")
                bodyValue("Masa magra", health.leanMassHistory.last?.value, "kg")
            }
            if !health.bodyWeightHistory.isEmpty {
                Chart(health.bodyWeightHistory) { point in
                    LineMark(x: .value("Fecha", point.date), y: .value("Peso", point.value))
                        .foregroundStyle(Color.teal).lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Fecha", point.date), y: .value("Peso", point.value)).foregroundStyle(Color.teal)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 145)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Evolución del peso")
                .accessibilityValue(health.bodyWeightHistory.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.value.formatted()) kilogramos" }.joined(separator: ". "))
            } else {
                Text("Añade tu primera medición o permite leerla desde Apple Salud.").font(.caption).foregroundStyle(.secondary)
            }
            if !health.bodyMeasurements.isEmpty {
                Divider()
                ForEach(Array(health.bodyMeasurements.prefix(5))) { measurement in
                    Button { bodyMeasurementPendingEdit = measurement; showBodyComposition = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(measurement.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.bold())
                                Text(measurement.source).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(measurement.weightKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "Composición")
                                .font(.caption.bold())
                            Image(systemName: measurement.isOwnedByEter ? "pencil" : "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Text("La composición es estimada. Éter usará tendencias y fuerza relativa, no una lectura aislada.")
                .font(.caption2).foregroundStyle(.secondary)
            if let bodyFat = health.bodyFatHistory.last?.value, let tip = WellnessRecommendationEngine.bodyFatPercentage(bodyFat) {
                Label(tip, systemImage: "lightbulb.fill").font(.caption2).foregroundStyle(EterTheme.primary).lineSpacing(2)
            }
        }.cardStyle()
    }


    private func bodyValue(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "—")
                .font(.subheadline.bold()).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}
