import SwiftUI

struct HyroxForecastCard: View {
    let goal: TrainingGoal
    let forecast: HyroxForecast?
    let measuredAt: Date?
    /// true cuando va incrustado dentro de otra card (Performance forecast): no
    /// pinta su propio fondo de tarjeta.
    var bare: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                EterSectionHeader(goal.hyroxDivision?.rawValue ?? HyroxDivision.open.rawValue, eyebrow: "Forecast HYROX")
                Spacer()
                if let forecast {
                    DataTrustBadge(trust: DataTrust(
                        nature: .inferred, source: "Running + fuerza importada + sesiones HYROX",
                        measuredAt: measuredAt, samples: forecast.stations.filter(\.observed).count + forecast.specificSessions,
                        level: forecast.confidence.level, explanation: forecast.confidence.reason + " " + forecast.basis,
                        limitations: "Sin parciales de cada estación, la banda de estaciones es estructural y no personal. Formato, pesos, transiciones y ejecución pueden cambiar mucho el resultado."
                    ))
                }
            }
            if let forecast {
                // Confidence already has a real home in the DataTrustBadge
                // above — this used to repeat it a second time right here
                // with its own hand-rolled dot instead of just pointing at
                // that badge.
                forecastHeadline(forecast)
                Text("Centro \(duration(forecast.seconds)) · intervalo prudente, no promesa de resultado")
                    .font(.caption).foregroundStyle(.secondary)
                breakdown(forecast)
                Divider()
                Text("ESTACIONES OBSERVADAS").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], spacing: 8) {
                    ForEach(forecast.stations) { station in
                        Label(station.name, systemImage: station.observed ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(station.observed ? EterTheme.positive : .secondary)
                    }
                }
                Label(forecast.bottleneck, systemImage: "scope")
                    .font(.caption.bold()).foregroundStyle(EterTheme.warning).lineSpacing(3)
                Text(forecast.basis).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            } else {
                Label("Aún no estimable", systemImage: "timer")
                    .font(.headline).foregroundStyle(.secondary)
                Text("Necesitamos al menos una carrera con distancia y duración. Después podremos construir los 8 km y mantener una banda amplia para las estaciones hasta que registres sesiones específicas.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.cardStyle(active: !bare)
    }

    private func forecastHeadline(_ forecast: HyroxForecast) -> some View {
        Text("\(duration(forecast.optimisticSeconds))–\(duration(forecast.conservativeSeconds))")
            .font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
            .minimumScaleFactor(0.7)
            .accessibilityLabel("Entre \(durationSpoken(forecast.optimisticSeconds)) y \(durationSpoken(forecast.conservativeSeconds))")
    }

    private func breakdown(_ forecast: HyroxForecast) -> some View {
        let total = max(1, forecast.runSeconds + forecast.stationSeconds + forecast.transitionSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.blue).frame(width: proxy.size.width * forecast.runSeconds / total)
                    Rectangle().fill(Color.orange).frame(width: proxy.size.width * forecast.stationSeconds / total)
                    Rectangle().fill(Color.purple).frame(width: proxy.size.width * forecast.transitionSeconds / total)
                }.clipShape(Capsule())
            }.frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], spacing: 8) {
                breakdownItem("Carrera comprometida", forecast.runSeconds, .blue)
                breakdownItem("Estaciones", forecast.stationSeconds, .orange)
                breakdownItem("Roxzone", forecast.transitionSeconds, .purple)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Desglose. Carrera \(durationSpoken(forecast.runSeconds)). Estaciones \(durationSpoken(forecast.stationSeconds)). Transiciones \(durationSpoken(forecast.transitionSeconds)).")
    }

    private func breakdownItem(_ name: String, _ seconds: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(name).font(.caption2).foregroundStyle(.secondary) }
            Text(duration(seconds)).font(.subheadline.bold()).monospacedDigit()
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func durationSpoken(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 3_600) horas, \(total % 3_600 / 60) minutos y \(total % 60) segundos"
    }
}
