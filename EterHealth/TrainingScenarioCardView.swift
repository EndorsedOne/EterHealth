import SwiftUI
import Charts

// "Simulador, no receta — pero cuando eliges Agresivo, deja de ser solo
// simulador." See TrainingScenarioEngine's own header for why the pace-
// change band stays a generic, capped reference never confused with this
// app's own personal race forecasts. The honesty boundary this card
// itself owns: Agresivo genuinely crosses into elevated real injury risk
// (see ProgressionPace) — never presented as risk-free, never switched
// to silently. Picking it requires an explicit confirmation here, and
// every real day its extra margin actually gets used carries its own
// warning in the plan (TrainingPlanEngine.aggressiveRiskDisclosure).
struct TrainingScenarioCardView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var goals: GoalStore
    @State private var pendingAggressiveConfirmation = false

    // Direct read/write on the real profile — this IS the "elegir un
    // futuro" action the card previously had no way to perform. Choosing
    // here changes TrainingPlanEngine.status()/weekAhead's real
    // day-to-day recovery gating today, not just which line is
    // highlighted below. Switching TO Agresivo doesn't commit immediately
    // — see confirmationDialog in body.
    private var paceBinding: Binding<ProgressionPace> {
        Binding(
            get: { goals.profile.effectiveProgressionPace },
            set: { newPace in
                if newPace == .aggressive {
                    pendingAggressiveConfirmation = true
                } else {
                    commit(newPace)
                }
            }
        )
    }

    private func commit(_ pace: ProgressionPace) {
        var updated = goals.profile
        updated.progressionPace = pace
        goals.save(updated)
    }

    var body: some View {
        let currentPace = goals.profile.effectiveProgressionPace
        let scenarios = TrainingScenarioEngine.simulate(health: health, imports: imports, currentPace: currentPace)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ritmo de progresión").font(.headline)
                Text("Tres futuros a 8 semanas con la misma carga de hoy — elige el que usa tu plan").font(.caption).foregroundStyle(.secondary)
            }
            // The actual "elegir un futuro" control — previously this card
            // was pure lectura, with no way to act on what it showed.
            Picker("Ritmo de progresión", selection: paceBinding) {
                ForEach(ProgressionPace.allCases) { pace in Text(pace.rawValue).tag(pace) }
            }.pickerStyle(.segmented)
            Text(currentPace.explanation).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            if currentPace == .aggressive {
                // Antes describía sólo el techo de carga, que era también lo
                // único que el ritmo movía. Ahora Agresivo baja además el
                // umbral de disponibilidad, así que el aviso dice las dos
                // vías por las que puede ponerte al límite — y el día
                // concreto en que lo hace lo dice el rationale del plan, no
                // sólo este aviso general.
                Label("Ritmo Agresivo activo: el plan entrena al límite por dos vías — carga por encima de 1.55 y disponibilidad hasta \(ProgressionPace.aggressive.readinessFloor) (Óptimo pararía en \(ProgressionPace.optimal.readinessFloor)). Riesgo de lesión real; cada día que ocurra te lo dirá la recomendación.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.bold()).foregroundStyle(EterTheme.danger).lineSpacing(2)
            }
            if scenarios.isEmpty {
                Text("Necesitamos al menos 8 días de carga real registrada para proyectar un bloque completo.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Comparación compacta de los tres ritmos de un vistazo (crecimiento
                // semanal + semanas en riesgo); debajo, el detalle solo del ritmo
                // elegido — en vez de tres bloques largos con una gráfica cada uno.
                HStack(spacing: 8) {
                    ForEach(scenarios) { scenario in
                        VStack(spacing: 4) {
                            Text(scenario.name).font(.caption2.bold())
                                .foregroundStyle(scenario.isCurrentPace ? EterTheme.primary : .secondary)
                            Text("+\(Int((scenario.weeklyGrowthRate * 100).rounded()))%/sem")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Text(scenario.weeksAtRisk == 0 ? "sin riesgo" : "\(scenario.weeksAtRisk) sem. riesgo")
                                .font(.caption2.bold()).foregroundStyle(riskColor(scenario))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9).padding(.horizontal, 6)
                        .background(scenario.isCurrentPace ? EterTheme.primary.opacity(0.10) : EterTheme.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: EterTheme.controlRadius)
                                .stroke(scenario.isCurrentPace ? EterTheme.primary.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                    }
                }
                if let current = scenarios.first(where: { $0.isCurrentPace }) {
                    scenarioRow(current, isCurrent: false)
                }
                Text("La banda de ritmo es una referencia genérica de la literatura (Banister 1975 · Busso 2003); el riesgo (ratio de carga aguda/habitual) sí es tu historial real proyectado. El ritmo elegido es el que usa tu plan: decide cuándo tocar descansar y cuánto puede crecer por semana tu tirada larga.")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
        }.cardStyle()
            .confirmationDialog("Ritmo Agresivo", isPresented: $pendingAggressiveConfirmation, titleVisibility: .visible) {
                Button("Sí, entiendo el riesgo", role: .destructive) { commit(.aggressive) }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Tolera carga hasta 1.80 — por encima de 1.55 la evidencia (Gabbett 2016; Blanch & Gabbett 2016) asocia un riesgo de lesión claramente mayor. El plan te avisará cada vez que use ese margen extra, pero la decisión de operar ahí es tuya.")
            }
    }

    private func scenarioRow(_ scenario: TrainingScenario, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    scenarioTitle(scenario, isCurrent: isCurrent); Spacer(); riskBadge(scenario)
                }
                VStack(alignment: .leading, spacing: 3) {
                    scenarioTitle(scenario, isCurrent: isCurrent); riskBadge(scenario)
                }
            }
            Chart(scenario.weeks) { week in
                LineMark(x: .value("Semana", week.weekIndex + 1), y: .value("Ratio", week.loadRatio))
                    .foregroundStyle(riskColor(scenario)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Semana", week.weekIndex + 1), y: .value("Ratio", week.loadRatio))
                    .foregroundStyle(week.isDeloadWeek ? EterTheme.primary : riskColor(scenario))
                    .symbolSize(week.isDeloadWeek ? 45 : 18)
                RuleMark(y: .value("Sobrecarga", 1.55))
                    .foregroundStyle(EterTheme.danger.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis { AxisMarks(values: .stride(by: 1)) { _ in AxisValueLabel() } }
            .chartYAxis(.hidden)
            .frame(height: 56)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trayectoria de riesgo, \(scenario.name)")
            .accessibilityValue(scenario.summary)
            Text(scenario.summary).font(.caption).foregroundStyle(.secondary).lineSpacing(2)
            Label(paceRangeText(scenario), systemImage: "figure.run")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(isCurrent ? 10 : 0)
        .background(isCurrent ? EterTheme.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
    }

    private func scenarioTitle(_ scenario: TrainingScenario, isCurrent: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(scenario.name).font(.subheadline.bold())
            Text("+\(Int((scenario.weeklyGrowthRate * 100).rounded()))%/semana").font(.caption2).foregroundStyle(.secondary)
            if isCurrent {
                Text("TU RITMO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(EterTheme.primary)
            }
        }
    }

    private func riskBadge(_ scenario: TrainingScenario) -> some View {
        Text(scenario.weeksAtRisk == 0 ? "Sin riesgo detectado" : "\(scenario.weeksAtRisk) sem. pidiendo absorber")
            .font(.caption2.bold()).foregroundStyle(riskColor(scenario))
    }

    private func riskColor(_ scenario: TrainingScenario) -> Color {
        scenario.weeks.contains { $0.guidance == .overload } ? EterTheme.danger
            : scenario.weeksAtRisk > 0 ? EterTheme.negative : EterTheme.positive
    }

    private func paceRangeText(_ scenario: TrainingScenario) -> String {
        let low = scenario.projectedPaceChangePercent.lowerBound
        let high = scenario.projectedPaceChangePercent.upperBound
        if low == 0 && high == 0 { return "Sin carga real suficiente para estimar cambio de ritmo." }
        return "Ritmo: entre \(abs(high).formatted(.number.precision(.fractionLength(1))))% y \(abs(low).formatted(.number.precision(.fractionLength(1))))% más rápido (referencia genérica)"
    }
}
