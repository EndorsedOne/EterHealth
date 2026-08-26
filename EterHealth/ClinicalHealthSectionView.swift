import SwiftUI
import Charts

struct ClinicalHealthSectionView: View {
    @EnvironmentObject private var imports: ImportStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EterSectionHeader("Analíticas clínicas", subtitle: "Resultados importados y evolución frente a sus límites")
            if imports.latestLabs.isEmpty {
                Text("No hay resultados clínicos importados. Puedes añadirlos desde la pestaña Datos.").font(.caption).foregroundStyle(.secondary).cardStyle()
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text("Última analítica").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        DataTrustBadge(trust: clinicalTrust(samples: imports.labCount, date: imports.latestLabs.map(\.date).max()))
                    }
                    // Grouped by clinical category (hemograma, bioquímica,
                    // perfil lipídico...) instead of one flat list in
                    // whatever order the PDF yielded them — see
                    // LabCategory. A category header only appears when
                    // more than one is actually present, since a single
                    // group repeating its own name back adds nothing.
                    let groups = LabCategory.grouped(imports.latestLabs, name: \.name)
                    ForEach(groups, id: \.0) { category, labsInCategory in
                        VStack(alignment: .leading, spacing: 8) {
                            if groups.count > 1 {
                                Text(category.rawValue.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                            }
                            ForEach(labsInCategory) { lab in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading) { Text(lab.name); Text(lab.status).font(.caption2).foregroundStyle(lab.status == "En rango" ? EterTheme.positive : EterTheme.negative) }
                                        Spacer(); Text("\(lab.value.formatted()) \(lab.unit)").bold()
                                    }
                                    // General lifestyle guidance for a lab outside
                                    // its own reported reference range — never a
                                    // diagnosis, and only for the handful of
                                    // markers with well-established directionality
                                    // (see WellnessRecommendationEngine).
                                    if let tip = WellnessRecommendationEngine.lab(name: lab.name, status: lab.status) {
                                        Label(tip, systemImage: "lightbulb.fill").font(.caption2).foregroundStyle(EterTheme.primary).lineSpacing(2)
                                    }
                                }
                            }
                        }
                    }
                }.cardStyle()
                labCharts
            }
        }
    }

    private var labCharts: some View {
        let series = imports.labSeries()
        let groups = LabCategory.grouped(series, name: \.0)
        return VStack(alignment: .leading, spacing: 14) {
            if !series.isEmpty { EterSectionHeader("Evolución clínica") }
            ForEach(groups, id: \.0) { category, seriesInCategory in
                VStack(alignment: .leading, spacing: 14) {
                    if groups.count > 1 {
                        Text(category.rawValue.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                    }
                    ForEach(seriesInCategory, id: \.0) { name, points, unit, low, high in
                        labSeriesCard(name: name, points: points, unit: unit, low: low, high: high)
                    }
                }
            }
        }
    }

    private func labSeriesCard(name: String, points: [TrendPoint], unit: String, low: Double?, high: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.headline)
                Spacer()
                DataTrustBadge(trust: clinicalTrust(samples: points.count, date: points.last?.date))
                if let last = points.last { Text("\(last.value, specifier: "%.1f") \(unit)").font(.subheadline.bold()) }
            }
            if points.count == 1 {
                VStack(alignment: .leading, spacing: 10) {
                    if let value = points.first?.value {
                        labRangeGauge(value: value, low: low, high: high)
                    }
                    Text("Una sola medición: todavía no hay evolución temporal.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Fecha", point.date), y: .value(name, point.value)).foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("Fecha", point.date), y: .value(name, point.value)).foregroundStyle(.teal).symbolSize(42)
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 1) {
                                Text(point.value.formatted()).bold()
                                Text(point.date.formatted(.dateTime.month(.twoDigits).year())).foregroundStyle(.secondary)
                            }.font(.caption2)
                        }
                    // Both boundaries share one color on purpose:
                    // whether low or high is the "bad" direction
                    // varies by marker (low ferritin is the risk;
                    // high LDL is), so coloring min=orange/max=red
                    // unconditionally (the old behavior) implied a
                    // direction that isn't always true. lab.status
                    // above already carries the real verdict.
                    if let low {
                        RuleMark(y: .value("Mínimo", low)).foregroundStyle(EterTheme.negative.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    if let high {
                        RuleMark(y: .value("Máximo", high)).foregroundStyle(EterTheme.negative.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).year()) } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.10)); AxisValueLabel() } }
                .frame(height: 130)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Evolución de \(name)")
                .accessibilityValue(points.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.value.formatted()) \(unit)" }.joined(separator: ". "))
                HStack(spacing: 14) {
                    if let low { Text("Mín. \(low.formatted())").foregroundStyle(EterTheme.negative) }
                    if let high { Text("Máx. \(high.formatted())").foregroundStyle(EterTheme.negative) }
                }.font(.caption2)
            }
        }.cardStyle()
    }

    private func labRangeGauge(value: Double, low: Double?, high: Double?) -> some View {
        let upper = max(high ?? value * 1.25, value * 1.15, 1)
        let lower = min(low ?? 0, value)
        let span = max(upper - lower, 0.001)
        let position = min(1, max(0, (value - lower) / span))
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(height: 8)
                    if let low, let high {
                        let start = min(1, max(0, (low - lower) / span))
                        let end = min(1, max(0, (high - lower) / span))
                        Capsule().fill(EterTheme.positive.opacity(0.35)).frame(width: proxy.size.width * (end - start), height: 8).offset(x: proxy.size.width * start)
                    }
                    Circle().fill(Color.teal).frame(width: 15, height: 15).offset(x: max(0, proxy.size.width * position - 7.5))
                }
            }.frame(height: 15)
            HStack {
                if let low { Text("Mínimo \(low.formatted())") }
                Spacer()
                Text("Valor \(value.formatted())").bold().foregroundStyle(.teal)
                Spacer()
                if let high { Text("Máximo \(high.formatted())") }
            }.font(.caption2)
        }
    }


    private func clinicalTrust(samples: Int, date: Date?) -> DataTrust {
        DataTrust(
            nature: .imported,
            source: "PDF de laboratorio · extracción local",
            measuredAt: date,
            samples: samples,
            level: ConfidenceEngine.samples(samples, medium: 1, high: 3, label: "resultados clínicos importados").level,
            explanation: "El valor, la fecha, la unidad y los límites se extraen del documento importado y se normalizan para mostrar evolución.",
            limitations: "PDF y OCR pueden confundir columnas, unidades o fechas. Contrasta cualquier valor relevante con el informe original y criterio médico."
        )
    }

}
