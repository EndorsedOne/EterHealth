import SwiftUI
import Charts

struct RunningPerformanceView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var workoutReviews: WorkoutReviewStore
    @EnvironmentObject private var goals: GoalStore

    let running: RunningPerformanceSummary
    let plan: WeeklyPlanStatus

    @State private var selectedForecastDistance: ForecastDistance = .halfMarathon
    @State private var forecastWindowDays = 30

    var body: some View {
        let coverage = RunningPerformanceEngine.coverage(workouts: health.workoutHistory, reviews: workoutReviews.reviews,
                                                         summary: running, targetRuns: plan.targetRuns, targetQuality: plan.targetQuality,
                                                         block: plan.block)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                EterSectionHeader("Camino a tus objetivos", eyebrow: "Rendimiento running")
                Spacer()
                DataTrustBadge(trust: DataTrust(nature: .calculated, source: "Apple Salud · entrenamientos de carrera", measuredAt: running.sessions.last?.date ?? health.lastUpdated, samples: running.sessions.count, level: ConfidenceEngine.samples(running.sessions.count, medium: 3, high: 8, label: "carreras válidas").level, explanation: "Distancia, duración y pulso proceden de las carreras guardadas en Apple Salud. Ritmos, carga semanal y predicciones se calculan a partir de esas sesiones.", limitations: "El forecast no conoce todavía recorrido, viento, pausas ni intención de cada sesión. No sustituye una prueba específica ni garantiza un tiempo de carrera."))
            }

            if running.sessions.isEmpty {
                Text("Las carreras existentes todavía no incluyen distancia accesible. Actualiza Apple Salud y comprueba el permiso de Distancia caminando/corriendo.")
                    .font(.caption).foregroundStyle(.secondary).cardStyle()
            } else {
                runningCoverageCard(coverage)
                runningVolumeCard(running)
                raceForecastCard(running)
                if running.hasZoneData { runningIntensityCard(running, coverage: coverage, block: plan.block) }
                recentRunsCard(running)
            }
        }
    }

    private func runningCoverageCard(_ coverage: RunningCoverageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cobertura de running").font(.headline)
                    Text("Realizado frente a tu rango objetivo").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(); Text("Ciclo \(coverage.days)d").font(.caption).foregroundStyle(.secondary)
            }
            runningCoverageRow("Volumen", value: coverage.kilometers, range: coverage.kilometerTarget, unit: "km")
            runningCoverageRow("Tirada larga", value: coverage.longestRun, range: coverage.longRunTarget, unit: "km")
            runningCoverageCountRow("Sesiones", value: coverage.runs, target: coverage.targetRuns)
            runningCoverageCountRow("Calidad", value: coverage.qualityRuns, target: coverage.targetQuality)
            Divider()
            Text(coverage.interpretation).font(.caption.bold()).lineSpacing(3)
            Text(coverage.context).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            if coverage.cyclingMinutes > 0 {
                Label("\(Int(coverage.cyclingMinutes.rounded())) min de bici aportan carga aeróbica global, pero no sustituyen kilómetros ni impacto de carrera.", systemImage: "bicycle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }

    private func runningCoverageRow(_ name: String, value: Double, range: ClosedRange<Double>, unit: String) -> some View {
        let state = coverageState(value, range: range)
        let percentage = coveragePercentage(value, range: range)
        return VStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(name).font(.caption); Spacer()
                    coverageValue(value, range: range, unit: unit, percentage: percentage)
                    coverageStateLabel(state)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(name).font(.caption); Spacer(); coverageStateLabel(state) }
                    coverageValue(value, range: range, unit: unit, percentage: percentage)
                }
            }
            coverageBar(value: value, upper: range.upperBound, state: state)
        }
    }

    private func runningCoverageCountRow(_ name: String, value: Int, target: Int) -> some View {
        let range = Double(target)...Double(target)
        let state = target == 0 ? "No requerido" : coverageState(Double(value), range: range)
        let percentage = target == 0 ? 100 : Int((Double(value) / Double(max(1, target)) * 100).rounded())
        return VStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(name).font(.caption); Spacer()
                    Text("\(value) / \(target) · \(percentage)%").font(.caption.monospacedDigit())
                    coverageStateLabel(state)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(name).font(.caption); Spacer(); coverageStateLabel(state) }
                    Text("\(value) / \(target) · \(percentage)%").font(.caption.monospacedDigit())
                }
            }
            coverageBar(value: Double(value), upper: Double(max(1, target)), state: state)
        }
    }

    private func coverageValue(_ value: Double, range: ClosedRange<Double>, unit: String, percentage: Int) -> some View {
        Text("\(value, specifier: "%.1f") / \(range.lowerBound, specifier: "%.1f")–\(range.upperBound, specifier: "%.1f") \(unit) · \(percentage)%")
            .font(.caption.monospacedDigit())
    }

    private func coverageStateLabel(_ state: String) -> some View {
        Text(state).font(.caption2.bold()).foregroundStyle(coverageStatusColor(state))
    }

    private func coverageBar(value: Double, upper: Double, state: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(coverageStatusColor(state).opacity(0.78))
                    .frame(width: min(proxy.size.width, proxy.size.width * value / max(upper, 0.01)))
            }
        }.frame(height: 7)
    }

    private func coverageState(_ value: Double, range: ClosedRange<Double>) -> String {
        if value < range.lowerBound { return "Pendiente" }
        if value <= range.upperBound { return "Adecuado" }
        if value <= range.upperBound * 1.15 { return "Alto" }
        return "Excesivo"
    }

    private func coveragePercentage(_ value: Double, range: ClosedRange<Double>) -> Int {
        if range.contains(value) { return 100 }
        let reference = value < range.lowerBound ? range.lowerBound : range.upperBound
        return Int((value / max(reference, 0.01) * 100).rounded())
    }

    private func coverageStatusColor(_ state: String) -> Color { coverageStateColor(state) }

    private func runningMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(value). \(detail)")
    }

    private func runningVolumeCard(_ running: RunningPerformanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Tolerancia semanal").font(.headline); Spacer(); Text("6 semanas").font(.caption).foregroundStyle(.secondary) }
            Chart(running.weeks) { week in
                BarMark(x: .value("Semana", week.start, unit: .weekOfYear), y: .value("Kilómetros", week.kilometers))
                    .foregroundStyle(Color.blue.gradient).cornerRadius(4)
                    .annotation(position: .top) { if week.kilometers > 0 { Text("\(week.kilometers, specifier: "%.0f")").font(.caption2).foregroundStyle(.secondary) } }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 140)
            .accessibilityLabel("Kilómetros por semana durante seis semanas")
            .accessibilityValue(running.weeks.map { "\($0.start.formatted(date: .abbreviated, time: .omitted)): \(Int($0.kilometers.rounded())) kilómetros" }.joined(separator: ". "))
            Text("Una subida semanal grande no es automáticamente mala, pero necesita contexto de intensidad, sueño y molestias.").font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func raceForecastCard(_ running: RunningPerformanceSummary) -> some View {
        let forecast = selectedRaceForecast(running)
        let trend = RunningPerformanceEngine.forecastTrend(
            distance: selectedForecastDistance,
            workouts: health.workoutHistory,
            reviews: workoutReviews.reviews,
            days: forecastWindowDays
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance forecast").font(.headline)
                    Text("Predicción de hoy y cómo ha evolucionado").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let forecast {
                    DataTrustBadge(trust: DataTrust(
                        nature: .calculated, source: forecast.basis, measuredAt: nil, samples: 0,
                        level: forecast.confidence, explanation: forecast.basis,
                        limitations: "Cada punto se recalcula solo con los entrenamientos que ya existían en esa fecha. El rango refleja la confianza disponible; no es una garantía de resultado."
                    ))
                }
            }

            Picker("Distancia", selection: $selectedForecastDistance) {
                ForEach(ForecastDistance.allCases) { distance in Text(distance.rawValue).tag(distance) }
            }.pickerStyle(.segmented)

            if let forecast {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(raceTime(forecast.seconds)).font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
                        Text("\(forecastPace(forecast.seconds, kilometers: selectedForecastDistance.kilometers))/km")
                            .font(.subheadline.bold()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    forecastChangeLabel(trend)
                }

                if trend.count > 1 {
                    Chart(trend) { point in
                        LineMark(x: .value("Fecha", point.date), y: .value("Rendimiento", -point.seconds))
                            .foregroundStyle(Color.blue.gradient).interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Fecha", point.date), y: .value("Rendimiento", -point.seconds))
                            .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.20), .clear], startPoint: .top, endPoint: .bottom))
                        if point.id == trend.last?.id {
                            PointMark(x: .value("Fecha", point.date), y: .value("Rendimiento", -point.seconds))
                                .foregroundStyle(.blue).symbolSize(70)
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.gray.opacity(0.18))
                            if let inverse = value.as(Double.self) { AxisValueLabel(raceTime(-inverse)) }
                        }
                    }
                    .frame(height: 165)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Evolución de la previsión para \(selectedForecastDistance.fullName)")
                    .accessibilityValue("De \(raceTime(trend.first?.seconds ?? 0)) a \(raceTime(trend.last?.seconds ?? 0)) durante los últimos \(forecastWindowDays) días")
                } else {
                    ContentUnavailableView("Aún sin evolución", systemImage: "chart.xyaxis.line", description: Text("Hace falta más historial de carreras para reconstruir la tendencia."))
                        .frame(height: 145)
                }

                Picker("Periodo", selection: $forecastWindowDays) {
                    Text("1M").tag(30); Text("3M").tag(90); Text("6M").tag(180)
                }.pickerStyle(.segmented)

                HStack(spacing: 10) {
                    forecastDetail(title: "Rango probable", value: "\(raceTime(forecast.optimisticSeconds))–\(raceTime(forecast.conservativeSeconds))")
                    forecastDetail(title: "Objetivo", value: forecastTargetText(forecast))
                }
                Text(forecastGoalGap(forecast)).font(.caption.bold()).foregroundStyle(forecastGoalColor(forecast))
                Divider()
                Text(forecast.basis).font(.caption.bold()).foregroundStyle(forecast.confidence.color)
                if selectedForecastDistance == .marathon {
                    // Riegel is well-validated for extrapolating between
                    // reasonably close distances, but it can't model the
                    // glycogen-depletion fade that shows up specifically past
                    // ~30-32km — projecting a marathon from 5K/10K/HM efforts
                    // alone tends to read optimistic versus what actually
                    // happens on race day. Worth saying explicitly here,
                    // not just leaving it implied by a wide range.
                    Text("El maratón es la distancia menos fiable de las cuatro: Riegel tiende a ser optimista al extrapolar tan lejos, porque no modela la caída de rendimiento que aparece a partir de los 30-32 km. Trátalo como una referencia orientativa, no como una previsión firme.")
                        .font(.caption2).foregroundStyle(EterTheme.warning).lineSpacing(2)
                }
            } else {
                ContentUnavailableView("Previsión no disponible", systemImage: "figure.run", description: Text("Necesitamos al menos una carrera con distancia y duración válidas."))
            }
        }.cardStyle()
    }

    private func selectedRaceForecast(_ running: RunningPerformanceSummary) -> RaceForecast? {
        switch selectedForecastDistance {
        case .fiveK: return running.fiveK
        case .tenK: return running.tenK
        case .halfMarathon: return running.halfMarathon
        case .marathon: return running.marathon
        }
    }

    private func forecastDetail(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder private func forecastChangeLabel(_ trend: [RaceForecastTrendPoint]) -> some View {
        if let first = trend.first, let last = trend.last {
            let change = first.seconds - last.seconds
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    abs(change) < 5 ? "Estable" : shortDuration(abs(change)),
                    systemImage: abs(change) < 5 ? "equal.circle.fill" : change > 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                )
                .font(.headline).foregroundStyle(abs(change) < 5 ? Color.secondary : change > 0 ? EterTheme.positive : EterTheme.negative)
                Text("en \(forecastWindowDays) días").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func forecastPace(_ seconds: Double, kilometers: Double) -> String {
        let pace = Int((seconds / max(kilometers, 0.1)).rounded())
        return String(format: "%d:%02d", pace / 60, pace % 60)
    }

    private func shortDuration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return value >= 60 ? String(format: "%d:%02d", value / 60, value % 60) : "\(value)s"
    }

    private func forecastGoalSeconds() -> Double? {
        switch selectedForecastDistance {
        case .fiveK: return goals.goal(.fiveK)?.targetValue.map { $0 * 60 }
        case .tenK: return goals.goal(.tenK)?.targetValue.map { $0 * 60 }
        case .halfMarathon: return goals.goal(.halfMarathon)?.targetValue.map { $0 * 60 }
        case .marathon: return goals.goal(.marathon)?.targetValue.map { $0 * 60 }
        }
    }

    private func forecastTargetText(_ forecast: RaceForecast) -> String {
        forecastGoalSeconds().map(raceTime) ?? "Sin objetivo"
    }

    private func forecastGoalGap(_ forecast: RaceForecast) -> String {
        guard let target = forecastGoalSeconds() else { return "Añade un objetivo para medir la distancia que falta." }
        let difference = forecast.seconds - target
        if abs(difference) < 5 { return "La predicción coincide con tu objetivo." }
        return difference > 0 ? "Faltan \(shortDuration(difference)) para el objetivo." : "Predicción \(shortDuration(abs(difference))) por delante del objetivo."
    }

    private func forecastGoalColor(_ forecast: RaceForecast) -> Color {
        guard let target = forecastGoalSeconds() else { return .secondary }
        return forecast.seconds <= target ? EterTheme.positive : EterTheme.negative
    }

    private func runningIntensityCard(_ running: RunningPerformanceSummary, coverage: RunningCoverageSummary, block: TrainingBlock) -> some View {
        let target = RunningPerformanceEngine.hardIntensityTarget(for: block)
        let status = runningIntensityStatus(running.hardPercentage, target: target)
        let color = runningIntensityColor(status)
        // Lactate-test boundaries are measured, not estimated — even more so
        // than a manually entered max HR — so they also clear the "estimado" caption.
        let configuredZones = goals.profile.maximumHeartRate != nil || goals.profile.manualHeartRateZones != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Distribución fácil / duro").font(.headline)
                Spacer()
                Text(status).font(.caption2.bold()).foregroundStyle(color)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(color.opacity(0.12)).clipShape(Capsule())
            }
            HStack {
                Text("Solo running · 10 días").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Objetivo duro \(Int(target.lowerBound))–\(Int(target.upperBound))%")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(.blue).frame(width: proxy.size.width * running.easyPercentage / 100)
                    Rectangle().fill(.orange).frame(width: proxy.size.width * running.hardPercentage / 100)
                }.clipShape(Capsule())
            }.frame(height: 13)
                .accessibilityHidden(true)
            HStack { Text("Fácil Z1–Z2 · \(Int(running.easyPercentage.rounded()))%").foregroundStyle(.blue); Spacer(); Text("Duro Z3–Z5 · \(Int(running.hardPercentage.rounded()))%").foregroundStyle(.orange) }.font(.caption.bold())
            VStack(alignment: .leading, spacing: 5) {
                Label(runningIntensityHeadline(running.hardPercentage, target: target), systemImage: running.hardPercentage > target.upperBound ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption.bold()).foregroundStyle(color)
                Text(runningIntensityAdvice(running.hardPercentage, target: target, easyTarget: coverage.easyTarget))
                    .font(.caption).lineSpacing(3)
            }
            .padding(11).background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 11))
            if running.hardPercentage > target.upperBound {
                Label("Este desvío es el que genera el ajuste «Reducir intensidad» en el equilibrio global del plan.", systemImage: "arrow.triangle.branch")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
            }
            if !configuredZones {
                Label("Juicio provisional: las zonas usan una FC máxima estimada por edad. Una prueba de lactato en laboratorio mide tus zonas reales a partir de tu curva de lactato y es la referencia más fiable — puedes introducir sus resultados en Plan del gemelo → Calibración cardíaca.", systemImage: "waveform.path.ecg")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
            Divider()
            Text("El desacople ritmo–pulso aún no se calcula: necesita comparar las muestras de la primera y segunda mitad de cada carrera. Se mostrará cuando incorporemos esa lectura intrasesión.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func runningIntensityStatus(_ hard: Double, target: ClosedRange<Double>) -> String {
        if target.contains(hard) { return "ALINEADO" }
        if hard > target.upperBound * 1.5 { return "MUY INTENSO" }
        if hard > target.upperBound { return "INTENSIDAD ALTA" }
        return "POCA CALIDAD"
    }

    private func runningIntensityColor(_ status: String) -> Color {
        switch status { case "ALINEADO": return EterTheme.positive; case "POCA CALIDAD": return .blue; case "INTENSIDAD ALTA": return EterTheme.negative; default: return EterTheme.danger }
    }

    private func runningIntensityHeadline(_ hard: Double, target: ClosedRange<Double>) -> String {
        if hard > target.upperBound { return "Demasiado tiempo en Z3–Z5 para la fase actual" }
        if hard < target.lowerBound { return "Falta el estímulo de calidad previsto" }
        return "El reparto de intensidad encaja con la fase actual"
    }

    private func runningIntensityAdvice(_ hard: Double, target: ClosedRange<Double>, easyTarget: ClosedRange<Double>) -> String {
        if hard > target.upperBound {
            return "Prioriza las próximas carreras en Z1–Z2 y no añadas otra sesión exigente hasta recuperar. El objetivo actual es acumular aproximadamente \(Int(easyTarget.lowerBound))–\(Int(easyTarget.upperBound))% fácil, no perseguir intensidad cada día."
        }
        if hard < target.lowerBound {
            return "Si la recuperación lo permite y el calendario pide calidad, reserva una única sesión controlada en Z3–Z5; el resto debe seguir siendo fácil."
        }
        return "Mantén una sesión de calidad bien separada y concentra el resto del volumen en Z1–Z2. No hace falta corregir el reparto ahora."
    }

    private func recentRunsCard(_ running: RunningPerformanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Últimas carreras").font(.headline)
            ForEach(running.sessions.suffix(5).reversed()) { run in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.bold())
                        Text("\(run.kilometers, specifier: "%.2f") km · \(paceText(run.pace))/km").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let heart = run.averageHeartRate { Text("\(Int(heart.rounded())) ppm").font(.caption.bold()) }
                        if let elevation = run.elevationMeters { Text("+\(Int(elevation.rounded())) m").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if run.id != running.sessions.last?.id { Divider() }
            }
        }.cardStyle()
    }

    private func paceText(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes > 0 else { return "—" }
        let seconds = Int((minutes * 60).rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func raceTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600):\(String(format: "%02d", (total % 3600) / 60)): \(String(format: "%02d", total % 60))".replacingOccurrences(of: ": ", with: ":") }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
