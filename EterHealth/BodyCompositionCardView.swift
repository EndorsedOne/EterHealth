import SwiftUI
import Charts

private struct CompositionZone: Identifiable {
    var id: String { label }
    let upper: Double
    let color: Color
    let label: String
}

struct BodyCompositionCardView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var inBody: InBodyStore
    @Binding var showBodyComposition: Bool
    @Binding var bodyMeasurementPendingEdit: BodyMeasurement?

    private let fatColor = Color(red: 0.90, green: 0.58, blue: 0.25)
    private let waterColor = Color(red: 0.29, green: 0.66, blue: 0.80)
    private let muscleColor = Color(red: 0.71, green: 0.89, blue: 0.30)

    private var weight: Double? { health.bodyWeightHistory.last?.value ?? health.bodyMeasurements.first?.weightKg }
    private var fatPercent: Double? { health.bodyFatHistory.last?.value ?? health.bodyMeasurements.first?.bodyFatPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Button { bodyMeasurementPendingEdit = nil; showBodyComposition = true } label: {
                Label("Añadir medición", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)

            if let latest = inBody.latest {
                heroRow(latest)
                previousDelta
                if let fat = fatPercent { fatGauge(fat) }
                if let visceral = latest.visceralFatLevel { visceralGauge(Double(visceral)) }
                moreMetrics(latest)
            } else {
                HStack(spacing: 10) {
                    bodyValue("Peso", weight, "kg")
                    bodyValue("Grasa", fatPercent, "%")
                    bodyValue("Masa magra", health.leanMassHistory.last?.value, "kg")
                }
            }

            trendChart
            historyList
            Text("La composición es estimada. Éter usa tendencias y fuerza relativa, no una lectura aislada.")
                .font(.caption2).foregroundStyle(.secondary)
            if let bodyFat = fatPercent, let tip = WellnessRecommendationEngine.bodyFatPercentage(bodyFat) {
                Label(tip, systemImage: "lightbulb.fill").font(.caption2).foregroundStyle(EterTheme.primary).lineSpacing(2)
            }
        }.cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Composición corporal").font(.title3.bold())
                Text(inBody.latest.map { "InBody · \($0.date.formatted(date: .abbreviated, time: .omitted))" }
                     ?? "Peso, grasa corporal y masa magra")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let weight {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(weight.formatted(.number.precision(.fractionLength(1)))).font(.title.bold())
                    Text("kg").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Hero (figura + composición)

    private func heroRow(_ latest: InBodyMeasurement) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "figure.arms.open")
                .resizable().scaledToFit()
                .frame(width: 88, height: 148)
                .foregroundStyle(RadialGradient(colors: [muscleColor, waterColor, fatColor],
                                                center: .center, startRadius: 6, endRadius: 96))
                .shadow(color: muscleColor.opacity(0.25), radius: 12)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                compRow(color: fatColor, name: "Grasa", value: fatLine(latest))
                compRow(color: waterColor, name: "Agua", value: waterLine(latest))
                if let smm = latest.skeletalMuscleMassKg {
                    compRow(color: muscleColor, name: "Músculo esq.",
                            value: "\(smm.formatted(.number.precision(.fractionLength(1)))) kg")
                }
            }
        }
    }

    private func compRow(color: Color, name: String, value: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(name).font(.caption)
            Spacer()
            Text(value).font(.caption.bold()).monospacedDigit()
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.28), lineWidth: 1))
    }

    private func fatLine(_ latest: InBodyMeasurement) -> String {
        let pct = fatPercent.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" }
        let kg = latest.bodyFatMassKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" }
        return [pct, kg].compactMap { $0 }.joined(separator: " · ")
    }

    private func waterLine(_ latest: InBodyMeasurement) -> String {
        guard let water = latest.totalBodyWaterKg else { return "—" }
        let pct = (weight.map { $0 > 0 ? "\((water / $0 * 100).formatted(.number.precision(.fractionLength(0))))%" : nil } ?? nil)
        let kg = "\(water.formatted(.number.precision(.fractionLength(1)))) kg"
        return [pct, kg].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Evolución

    @ViewBuilder private var previousDelta: some View {
        let d = deltas()
        if d.weight != nil || d.fat != nil || d.muscle != nil {
            VStack(alignment: .leading, spacing: 9) {
                Text("DESDE LA MEDICIÓN ANTERIOR")
                    .font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let w = d.weight { deltaItem("Peso", w, unit: "kg", goodWhenDown: nil) }
                    if let f = d.fat { deltaItem("Grasa", f, unit: "pp", goodWhenDown: true) }
                    if let m = d.muscle { deltaItem("Músculo", m, unit: "kg", goodWhenDown: false) }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// goodWhenDown: true = bajar es bueno (grasa); false = subir es bueno
    /// (músculo); nil = neutro (peso, sin juicio de valor).
    private func deltaItem(_ name: String, _ delta: Double, unit: String, goodWhenDown: Bool?) -> some View {
        let down = delta < 0
        let color: Color
        if abs(delta) < 0.05 { color = .secondary }
        else if let goodWhenDown { color = (down == goodWhenDown) ? EterTheme.positive : EterTheme.warning }
        else { color = .blue }
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: down ? "arrow.down" : "arrow.up").font(.caption2.bold())
                Text("\(delta >= 0 ? "+" : "")\(delta.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                    .font(.subheadline.bold()).monospacedDigit()
            }.foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deltas() -> (weight: Double?, fat: Double?, muscle: Double?) {
        var weightD: Double?, fatD: Double?
        let measurements = health.bodyMeasurements
        if measurements.count >= 2 {
            if let a = measurements[0].weightKg, let b = measurements[1].weightKg { weightD = a - b }
            if let a = measurements[0].bodyFatPercent, let b = measurements[1].bodyFatPercent { fatD = a - b }
        }
        var muscleD: Double?
        let records = inBody.measurements
        if records.count >= 2, let a = records[0].skeletalMuscleMassKg, let b = records[1].skeletalMuscleMassKg {
            muscleD = a - b
        }
        return (weightD, fatD, muscleD)
    }

    // MARK: Medidores por rango

    private func fatGauge(_ value: Double) -> some View {
        zoneCard(title: "Grasa corporal",
                 valueText: "\(value.formatted(.number.precision(.fractionLength(1))))%",
                 value: value, maxScale: 30,
                 zones: [
                    CompositionZone(upper: 6, color: Color(red: 0.34, green: 0.45, blue: 0.72), label: "Esencial"),
                    CompositionZone(upper: 13, color: Color(red: 0.24, green: 0.62, blue: 0.42), label: "Atlético"),
                    CompositionZone(upper: 17, color: Color(red: 0.52, green: 0.62, blue: 0.26), label: "Fitness"),
                    CompositionZone(upper: 24, color: Color(red: 0.66, green: 0.53, blue: 0.22), label: "Media"),
                    CompositionZone(upper: 30, color: Color(red: 0.66, green: 0.32, blue: 0.27), label: "Alta")
                 ])
    }

    private func visceralGauge(_ value: Double) -> some View {
        zoneCard(title: "Grasa visceral",
                 valueText: "\(Int(value))",
                 value: value, maxScale: 20,
                 zones: [
                    CompositionZone(upper: 9, color: Color(red: 0.24, green: 0.62, blue: 0.42), label: "Óptimo ≤9"),
                    CompositionZone(upper: 14, color: Color(red: 0.66, green: 0.53, blue: 0.22), label: "Alto"),
                    CompositionZone(upper: 20, color: Color(red: 0.66, green: 0.32, blue: 0.27), label: "Muy alto")
                 ])
    }

    private func zoneCard(title: String, valueText: String, value: Double, maxScale: Double, zones: [CompositionZone]) -> some View {
        let zone = zones.first { value <= $0.upper } ?? zones[zones.count - 1]
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.subheadline.bold())
                Text(valueText).font(.headline).monospacedDigit()
                Text(zone.label.replacingOccurrences(of: " ≤9", with: ""))
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(zone.color.opacity(0.22)).foregroundStyle(zone.color)
                    .clipShape(Capsule())
                Spacer()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    HStack(spacing: 1.5) {
                        ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
                            let lower = index == 0 ? 0 : zones[index - 1].upper
                            zone.color.frame(width: max(2, proxy.size.width * (zone.upper - lower) / maxScale))
                        }
                    }.clipShape(Capsule())
                    Capsule().fill(.white)
                        .frame(width: 3, height: 15)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                        .offset(x: proxy.size.width * min(1, max(0, value / maxScale)) - 1.5, y: -3)
                }
            }.frame(height: 9)
            HStack(spacing: 1) {
                ForEach(zones) { zone in
                    Text(zone.label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func moreMetrics(_ latest: InBodyMeasurement) -> some View {
        HStack(spacing: 10) {
            if let ffm = latest.fatFreeMassKg {
                metricPill("FFM", "\(ffm.formatted(.number.precision(.fractionLength(1)))) kg", icon: "leaf.fill")
            }
            if let bmr = latest.basalMetabolicRateKcal {
                metricPill("BMR", "\(Int(bmr.rounded())) kcal", icon: "flame.fill")
            }
        }
    }

    private func metricPill(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.bold()).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Tendencia + historial (se conservan)

    @ViewBuilder private var trendChart: some View {
        if !health.bodyWeightHistory.isEmpty {
            Chart(health.bodyWeightHistory) { point in
                LineMark(x: .value("Fecha", point.date), y: .value("Peso", point.value))
                    .foregroundStyle(Color.teal).lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Fecha", point.date), y: .value("Peso", point.value)).foregroundStyle(Color.teal)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Evolución del peso")
            .accessibilityValue(health.bodyWeightHistory.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.value.formatted()) kilogramos" }.joined(separator: ". "))
        } else {
            Text("Añade tu primera medición o permite leerla desde Apple Salud.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var historyList: some View {
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
    }

    private func bodyValue(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" } ?? "—")
                .font(.subheadline.bold()).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
