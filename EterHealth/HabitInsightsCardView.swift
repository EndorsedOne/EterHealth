import SwiftUI

// What the twin has actually learned about this person — caffeine timing,
// cold exposure, supplements — used to live as a caption2-sized afterthought
// at the bottom of LifestyleHistoryCardView's event log, capped at 4 of the
// ~14 habits the engine can track, with zero visual weight of its own. This
// is the same data given an actual card: a real header, a trust badge that
// matches every other confidence indicator in the app, and room for 6.
struct HabitInsightsCardView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var lifestyle: LifestyleFactorStore
    @EnvironmentObject private var travel: TravelEpisodeStore

    var body: some View {
        let associations = HabitAssociationEngine.analyze(
            events: lifestyle.events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory,
            sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory,
            deepShare: SleepArchitectureEngine.dailyDeepShareSeries(health.sleepStagesHistory),
            remShare: SleepArchitectureEngine.dailyRemShareSeries(health.sleepStagesHistory),
            sleepSchedule: health.sleepScheduleHistory,
            travelEpisodes: travel.episodes
        )
        let travelProfile = TravelLearningEngine.profile(episodes: travel.episodes)
        let learned = associations.filter { $0.confidence.level != .low }.count
        let observing = associations.count - learned
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                // Same header shape as every other card on this page
                // (longevityIndexCard, biologicalAgeCard, BodyComposition,
                // LifestyleHistoryCardView) — plain headline + caption
                // subtitle, no eyebrow. This card first used
                // EterSectionHeader's eyebrow+title3 look instead, which
                // stood out against its own neighbors rather than fitting in.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lo que Éter aprende de ti").font(.headline)
                    Text("Patrones personales que ya usa —o todavía está comprobando—").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DataTrustBadge(trust: DataTrust(
                    nature: .inferred, source: "Éter · mañanas emparejadas con hábitos declarados",
                    measuredAt: lifestyle.events.first?.date,
                    samples: associations.reduce(0) { $0 + $1.samples } + travelProfile.measuredOutcomes.count,
                    level: bestConfidenceLevel(among: associations),
                    explanation: "Cada asociación compara tus mañanas después de un hábito contra tus mañanas habituales — solo se muestra cuando hay suficientes mañanas emparejadas.",
                    limitations: "Son asociaciones personales, no causalidad. Entrenamiento, enfermedad, viajes y factores simultáneos pueden explicar parte del cambio."
                ))
            }
            HStack(spacing: 9) {
                learningSummary("Aprendidos", value: learned + (travelProfile.hasLearnedAnything ? 1 : 0), color: EterTheme.positive)
                learningSummary("Observando", value: observing, color: EterTheme.warning)
                learningSummary("Viajes medidos", value: travelProfile.measuredOutcomes.count, color: .blue)
            }
            if associations.isEmpty {
                Text("Todavía no hay suficientes mañanas emparejadas. Cada hábito necesita al menos 2 registros con HRV, pulso, sueño, respiración o temperatura de muñeca al día siguiente; las conclusiones empiezan a ser útiles a partir de 4–6.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(associations.prefix(8)) { association in
                        associationRow(association)
                        if association.id != associations.prefix(8).last?.id { Divider() }
                    }
                }
            }
            if !travel.episodes.isEmpty {
                Divider()
                travelLearning(profile: travelProfile)
            }
        }.cardStyle()
    }

    private func associationRow(_ association: HabitAssociation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    associationTitle(association); Spacer()
                    learningState(association)
                }
                VStack(alignment: .leading, spacing: 4) {
                    associationTitle(association); learningState(association)
                }
            }
            Text(association.headline).font(.caption).lineSpacing(2)
            if association.kind == .lateCaffeine, let exposure = association.averageExposureLevel {
                Text("Exposición media observada: ~\(Int(exposure.rounded())) mg estimados al dormir.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    ForEach(association.effects) { effect in effectBadge(effect) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(association.effects) { effect in effectBadge(effect) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(association.effects.map {
                "\($0.name), \($0.changePercent >= 0 ? "más" : "menos") \(Int(abs($0.changePercent).rounded())) por ciento favorable"
            }.joined(separator: ". "))
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(association.confidence.level.color.opacity(0.78))
                            .frame(width: proxy.size.width * min(1, max(0, Double(association.confidence.score) / 100)))
                    }
                }.frame(height: 6)
                Text("\(association.samples) mañanas · \(association.confidence.score)%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(association.confidence.level == .low
                 ? "Aporta contexto, pero todavía no modifica tu disponibilidad."
                 : "Éter ya puede usar este patrón con un impacto prudente y acotado.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func learningSummary(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.title3.bold()).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(EterTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
    }

    private func learningState(_ association: HabitAssociation) -> some View {
        let label: String
        let color: Color
        if association.confidence.level == .low {
            label = association.samples < 4 ? "OBSERVANDO" : "INDICIO"
            color = EterTheme.warning
        } else if association.direction == .neutral {
            label = "INCIERTO"
            color = .secondary
        } else {
            label = "APRENDIDO"
            color = EterTheme.positive
        }
        return Text(label).font(.caption2.bold()).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.10)).clipShape(Capsule())
    }

    private func travelLearning(profile: TravelResponseProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Respuesta a viajes", systemImage: "airplane").font(.subheadline.bold())
                Spacer()
                Text(profile.hasLearnedAnything ? "APRENDIDO" : "OBSERVANDO")
                    .font(.caption2.bold())
                    .foregroundStyle(profile.hasLearnedAnything ? EterTheme.positive : EterTheme.warning)
            }
            if profile.measuredOutcomes.isEmpty {
                Text("Los viajes están registrados, pero aún falta confirmar cuándo recuperaste estabilidad para aprender tu ritmo de adaptación.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                if let advance = profile.advance { travelRateRow(advance) }
                if let delay = profile.delay { travelRateRow(delay) }
                if !profile.hasLearnedAnything {
                    let pendingDirections = [
                        profile.outcomes.contains(where: { $0.isAdvance }) ? "este" : nil,
                        profile.outcomes.contains(where: { !$0.isAdvance }) ? "oeste" : nil
                    ].compactMap { $0 }.joined(separator: " y ")
                    Text("Hay \(profile.measuredOutcomes.count) tramo\(profile.measuredOutcomes.count == 1 ? "" : "s") medido\(profile.measuredOutcomes.count == 1 ? "" : "s") hacia el \(pendingDirections). Éter necesita dos válidos por dirección antes de sustituir la referencia poblacional.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
        }
    }

    private func travelRateRow(_ rate: LearnedReentrainmentRate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(rate.direction.capitalized).font(.caption.bold())
                Spacer()
                Text("\(rate.hoursPerDay.formatted(.number.precision(.fractionLength(1)))) h/día")
                    .font(.caption.bold()).monospacedDigit()
            }
            GeometryReader { proxy in
                let maximum = max(rate.hoursPerDay, rate.priorHoursPerDay, 0.1) * 1.2
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.blue.opacity(0.75))
                        .frame(width: proxy.size.width * rate.hoursPerDay / maximum)
                    Rectangle().fill(Color.secondary).frame(width: 2, height: 10)
                        .offset(x: proxy.size.width * rate.priorHoursPerDay / maximum)
                }
            }.frame(height: 10)
            Text("\(rate.episodesUsed) tramos válidos · referencia poblacional \(rate.priorHoursPerDay.formatted(.number.precision(.fractionLength(1)))) h/día · confianza \(rate.confidence.level.rawValue.lowercased())")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func effectBadge(_ effect: HabitMetricEffect) -> some View {
        Text("\(effect.name) \(effect.changePercent >= 0 ? "+" : "")\(Int(effect.changePercent.rounded()))%")
            .font(.caption2.bold())
            .foregroundStyle(effect.changePercent >= 2 ? EterTheme.positive : effect.changePercent <= -2 ? EterTheme.negative : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(EterTheme.raisedSurface).clipShape(Capsule())
    }

    private func associationTitle(_ association: HabitAssociation) -> some View {
        Label(association.kind.title, systemImage: association.kind.icon).font(.subheadline.bold())
    }

    private func bestConfidenceLevel(among associations: [HabitAssociation]) -> TrustLevel {
        let rank: (TrustLevel) -> Int = { $0 == .high ? 2 : $0 == .medium ? 1 : 0 }
        return associations.map(\.confidence.level).max(by: { rank($0) < rank($1) }) ?? .low
    }

}
