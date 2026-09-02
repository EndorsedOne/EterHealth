import SwiftUI
import Charts

struct LifestyleHistoryCardView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var lifestyle: LifestyleFactorStore

    @Binding var showLifestyleFactors: Bool
    @Binding var lifestyleFactorPendingEdit: LifestyleEvent?

    var body: some View {
        let alcoholMonths = monthlyAlcoholHistory
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Factores y contexto").font(.headline)
                    Text("Exposiciones que pueden explicar cambios posteriores").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: DataTrust(nature: .declared, source: "Éter + Apple Salud", measuredAt: lifestyle.events.first?.date ?? health.alcoholHistory.first?.date, samples: lifestyle.events.count + health.alcoholHistory.count, level: ConfidenceEngine.declared(samples: lifestyle.events.count + health.alcoholHistory.count).level, explanation: "Registro declarado de alimentación, ayuno, hidratación, cafeína y recuperación.", limitations: "Las asociaciones observadas no demuestran causalidad."))
            }
            if lifestyle.events.isEmpty && health.alcoholHistory.isEmpty {
                Text("Todavía no hay factores registrados.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(Array(lifestyle.events.prefix(8))) { event in
                    HStack(alignment: .top) {
                        Button { lifestyleFactorPendingEdit = event; showLifestyleFactors = true } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.summary).font(.subheadline.bold())
                                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                if !event.note.isEmpty { Text(event.note).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            lifestyle.delete(event)
                            if event.alcoholDrinks > 0 { Task { await health.deleteAlcohol(near: event.date) } }
                        } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain).eterTouchTarget().accessibilityLabel("Eliminar \(event.summary)")
                    }
                    if event.id != lifestyle.events.prefix(8).last?.id { Divider() }
                }
                if !health.alcoholHistory.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alcohol · últimos 12 meses").font(.subheadline.bold())
                                Text("Bebidas estándar por mes").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(health.alcoholHistory.reduce(0) { $0 + $1.drinks }.rounded()))")
                                .font(.title3.bold()).monospacedDigit()
                            Text("total").font(.caption2).foregroundStyle(.secondary)
                        }
                        Chart(alcoholMonths) { month in
                            BarMark(
                                x: .value("Mes", month.month, unit: .month),
                                y: .value("Bebidas", month.drinks)
                            )
                            .foregroundStyle(Color.orange.gradient)
                            .cornerRadius(3)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                                AxisGridLine().foregroundStyle(.clear)
                                AxisValueLabel(format: .dateTime.month(.abbreviated))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.10)); AxisValueLabel()
                            }
                        }
                        .frame(height: 145)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Consumo mensual de alcohol durante los últimos doce meses")
                        .accessibilityValue(alcoholMonths.map { "\($0.month.formatted(.dateTime.month(.wide))): \(Int($0.drinks.rounded())) bebidas" }.joined(separator: ". "))
                        let drinkingDays = Set(health.alcoholHistory.map { Calendar.current.startOfDay(for: $0.date) }).count
                        HStack {
                            Label("\(drinkingDays) días con consumo", systemImage: "calendar")
                            Spacer()
                            if let latest = health.alcoholHistory.first {
                                Text("Último: \(latest.date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.cardStyle()
    }

    private var monthlyAlcoholHistory: [LifestyleAlcoholMonth] {
        let calendar = Calendar.current
        let now = Date()
        return (0..<12).reversed().compactMap { offset -> LifestyleAlcoholMonth? in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now),
                  let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
            let samples = health.alcoholHistory.filter { interval.contains($0.date) }
            return LifestyleAlcoholMonth(month: interval.start, drinks: samples.reduce(0) { $0 + $1.drinks })
        }
    }

}

private struct LifestyleAlcoholMonth: Identifiable {
    let month: Date
    let drinks: Double
    var id: Date { month }
}
