import SwiftUI

// The combinable "¿qué pasa si...?" — see WhatIfSimulatorEngine's own
// header for why this exists alongside (not instead of) the older
// single-choice decisionSimulatorCard: a real evening is rarely just one
// thing, and alcohol here is real dose (NIAAA standard drinks), not a
// bare drink count.
struct WhatIfSimulatorCardView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var checkIns: DailyCheckInStore
    @EnvironmentObject private var travel: TravelEpisodeStore
    @State private var scenario = WhatIfScenario()
    @State private var caffeineHourSelection = 17
    @State private var caffeineDoseMg = 80

    private let drinkStepCap = 4

    var body: some View {
        let projection = scenario.isEmpty ? nil : WhatIfSimulatorEngine.simulate(scenario, health: health, imports: imports, checkIn: checkIns.entry(), travel: travel.currentEpisode(), travelHistory: travel.episodes)
        return VStack(alignment: .leading, spacing: 14) {
            EterSectionHeader("¿Qué pasa si esta noche…?", eyebrow: "Simulador combinable", subtitle: "Marca varias cosas a la vez — una cena de trabajo puede ser vino, cena copiosa y acostarte tarde, todo junto.")
            drinksSection
            caffeineSection
            bedtimeAndDinnerSection
            if let projection {
                Divider()
                projectionSection(projection)
            } else {
                Text("Marca al menos una cosa arriba para ver el efecto proyectado.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }

    // MARK: - Alcohol

    private var drinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ALCOHOL").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(DrinkType.allCases) { type in drinkChip(type) }
            }
            let totalDrinks = StandardDrinkCalculator.totalStandardDrinks(scenario.drinks)
            if totalDrinks > 0 {
                Text("\(totalDrinks.formatted(.number.precision(.fractionLength(0...1)))) bebidas estándar ≈ \(Int((totalDrinks * StandardDrinkCalculator.ethanolGramsPerStandardDrink).rounded())) g de alcohol puro (referencia NIAAA).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func drinkChip(_ type: DrinkType) -> some View {
        let count = scenario.drinks.first { $0.type == type }?.count ?? 0
        return Button {
            let next = (count + 1) > drinkStepCap ? 0 : count + 1
            scenario.drinks.removeAll { $0.type == type }
            if next > 0 { scenario.drinks.append(DrinkSelection(type: type, count: next)) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: type.icon).font(.caption2)
                Text(type.rawValue).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 { Text("×\(count)").font(.caption.bold()) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(count > 0 ? EterTheme.danger.opacity(0.16) : Color.primary.opacity(0.06))
            .foregroundStyle(count > 0 ? EterTheme.danger : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).eterTouchTarget()
        .accessibilityLabel(type.rawValue)
        .accessibilityValue(count > 0 ? "\(count)" : "Ninguna")
        .accessibilityHint("Toca para aumentar la cantidad")
    }

    // MARK: - Caffeine

    private var caffeineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAFEÍNA").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { scenario.caffeineHour != nil },
                set: { enabled in
                    scenario.caffeineHour = enabled ? caffeineHourSelection : nil
                    scenario.caffeineMg = enabled ? caffeineDoseMg : 0
                }
            )) {
                Text("Café o té")
            }
            if scenario.caffeineHour != nil {
                HStack {
                    Text("Hora").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Hora", selection: Binding(
                        get: { caffeineHourSelection },
                        set: { caffeineHourSelection = $0; scenario.caffeineHour = $0 }
                    )) {
                        ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                    }.pickerStyle(.menu)
                }
                Stepper("Dosis: \(caffeineDoseMg) mg", value: Binding(
                    get: { caffeineDoseMg },
                    set: { caffeineDoseMg = $0; scenario.caffeineMg = $0 }
                ), in: 30...400, step: 20)
                .font(.caption)
                Text("Referencia: un espresso ≈ 80 mg, una taza de café filtrado ≈ 150 mg.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bedtime & dinner

    private var bedtimeAndDinnerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HORARIO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { scenario.extraBedtimeMinutes > 0 },
                set: { scenario.extraBedtimeMinutes = $0 ? 60 : 0 }
            )) {
                Text(scenario.extraBedtimeMinutes > 0 ? "Acostarme \(scenario.extraBedtimeMinutes) min tarde" : "Acostarme tarde")
            }
            if scenario.extraBedtimeMinutes > 0 {
                Stepper("", value: $scenario.extraBedtimeMinutes, in: 15...240, step: 15)
                    .labelsHidden()
            }
            Toggle("Cena tardía o copiosa", isOn: $scenario.lateOrHeavyDinner)
        }
    }

    // MARK: - Projection

    private func projectionSection(_ projection: WhatIfProjection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                simulatorMetric("Hoy", "\(projection.baselineReadiness)%")
                simulatorMetric("Mañana proyectado", "\(projection.projectedReadiness)%")
                simulatorMetric("Efecto total", "\(projection.totalReadinessImpact >= 0 ? "+" : "")\(projection.totalReadinessImpact)")
            }
            Text(projection.headline).font(.headline).foregroundStyle(scoreColor(projection.projectedReadiness))

            if projection.projectedDeepShareDeltaPoints != nil || projection.projectedRemShareDeltaPoints != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IMPACTO EN ARQUITECTURA DEL SUEÑO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                    if let deep = projection.projectedDeepShareDeltaPoints {
                        architectureDeltaRow("Sueño profundo", points: deep)
                    }
                    if let rem = projection.projectedRemShareDeltaPoints {
                        architectureDeltaRow("REM", points: rem)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("POR QUÉ").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                ForEach(projection.factorImpacts) { impact in factorRow(impact) }
            }

            ForEach(projection.qualitativeNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle.fill").font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }

            if let caveat = projection.combinationCaveat {
                Label(caveat, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(EterTheme.warning).lineSpacing(2)
            }

            Text("Confianza \(projection.confidence.rawValue.lowercased()) · cada factor usa tu propio historial aprendido cuando hay suficiente, y una estimación general (nunca inventada — dosis reales de alcohol/cafeína) cuando no.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }
    }

    private func factorRow(_ impact: WhatIfFactorImpact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Text(impact.label).font(.subheadline.bold())
                    if impact.isLearned {
                        Text("APRENDIDO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(EterTheme.primary)
                    }
                }
                Spacer()
                Text("\(impact.readinessImpact >= 0 ? "+" : "")\(impact.readinessImpact) pt")
                    .font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(impact.readinessImpact > 0 ? EterTheme.positive : impact.readinessImpact < 0 ? EterTheme.negative : .secondary)
            }
            Text(impact.detail).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }
    }

    private func architectureDeltaRow(_ name: String, points: Double) -> some View {
        HStack {
            Text(name).font(.caption)
            Spacer()
            Text("\(points >= 0 ? "+" : "")\(points.formatted(.number.precision(.fractionLength(1)))) pp")
                .font(.caption.bold()).monospacedDigit()
                .foregroundStyle(points >= 0 ? EterTheme.positive : EterTheme.negative)
        }
    }

    private func simulatorMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 70 ? EterTheme.positive : score >= 45 ? EterTheme.warning : EterTheme.danger
    }
}
