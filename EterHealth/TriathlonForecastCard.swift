import SwiftUI

struct TriathlonForecastCard: View {
    let goal: TrainingGoal
    let forecast: TriathlonForecast?
    let measuredAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                EterSectionHeader((goal.resolvedTriathlonDistance ?? .olympic).rawValue, eyebrow: "Forecast \(goal.kind.rawValue)")
                Spacer()
                if let forecast {
                    DataTrustBadge(trust: DataTrust(
                        nature: .inferred, source: "Natación + ciclismo + running importados",
                        measuredAt: measuredAt, samples: forecast.swimSessions + forecast.bikeSessions + forecast.brickSessions,
                        level: forecast.confidence.level, explanation: forecast.confidence.reason + " " + forecast.basis,
                        limitations: "Natación y ciclismo sin evidencia propia usan un ritmo/velocidad genéricos, no personales. Transiciones, nutrición y meteorología del día pueden cambiar mucho el resultado."
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], spacing: 8) {
                    Label(forecast.swimIsPersonal ? "Natación personal" : "Natación genérica", systemImage: forecast.swimIsPersonal ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(forecast.swimIsPersonal ? EterTheme.positive : .secondary)
                    Label(forecast.bikeIsPersonal ? "Ciclismo personal" : "Ciclismo genérico", systemImage: forecast.bikeIsPersonal ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(forecast.bikeIsPersonal ? EterTheme.positive : .secondary)
                    Label("\(forecast.brickSessions) brick registrados", systemImage: forecast.brickSessions > 0 ? "checkmark.circle.fill" : "circle")
                        .font(.caption).foregroundStyle(forecast.brickSessions > 0 ? EterTheme.positive : .secondary)
                }
                if forecast.averageBikePowerWatts != nil || forecast.averageBikeCadenceRpm != nil {
                    HStack(spacing: 14) {
                        if let power = forecast.averageBikePowerWatts {
                            Label("\(Int(power.rounded())) W medios", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        if let cadence = forecast.averageBikeCadenceRpm {
                            Label("\(Int(cadence.rounded())) rpm medias", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Label(forecast.bottleneck, systemImage: "scope")
                    .font(.caption.bold()).foregroundStyle(EterTheme.warning).lineSpacing(3)
                if let courseCaveat = forecast.courseCaveat {
                    Label(courseCaveat, systemImage: "map").font(.caption).foregroundStyle(.secondary).lineSpacing(2)
                }
                Text(forecast.basis).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            } else {
                Label("Aún no estimable", systemImage: "timer")
                    .font(.headline).foregroundStyle(.secondary)
                Text("Necesitamos al menos una carrera con distancia y duración para construir la pierna de running. Natación y ciclismo pueden empezar con una estimación genérica hasta que registres tus propias sesiones.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.cardStyle()
    }

    private func forecastHeadline(_ forecast: TriathlonForecast) -> some View {
        Text("\(duration(forecast.optimisticSeconds))–\(duration(forecast.conservativeSeconds))")
            .font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
            .minimumScaleFactor(0.7)
            .accessibilityLabel("Entre \(durationSpoken(forecast.optimisticSeconds)) y \(durationSpoken(forecast.conservativeSeconds))")
    }

    private func breakdown(_ forecast: TriathlonForecast) -> some View {
        let total = max(1, forecast.swimSeconds + forecast.bikeSeconds + forecast.runSeconds + forecast.transitionSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.cyan).frame(width: proxy.size.width * forecast.swimSeconds / total)
                    Rectangle().fill(Color.orange).frame(width: proxy.size.width * forecast.bikeSeconds / total)
                    Rectangle().fill(Color.blue).frame(width: proxy.size.width * forecast.runSeconds / total)
                    Rectangle().fill(Color.purple).frame(width: proxy.size.width * forecast.transitionSeconds / total)
                }.clipShape(Capsule())
            }.frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], spacing: 8) {
                breakdownItem("Natación", forecast.swimSeconds, .cyan)
                breakdownItem("Ciclismo", forecast.bikeSeconds, .orange)
                breakdownItem("Carrera", forecast.runSeconds, .blue)
                breakdownItem("Transiciones", forecast.transitionSeconds, .purple)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Desglose. Natación \(durationSpoken(forecast.swimSeconds)). Ciclismo \(durationSpoken(forecast.bikeSeconds)). Carrera \(durationSpoken(forecast.runSeconds)). Transiciones \(durationSpoken(forecast.transitionSeconds)).")
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
