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

    var body: some View {
        let associations = HabitAssociationEngine.analyze(
            events: lifestyle.events, alcohol: health.alcoholHistory,
            hrv: health.hrvHistory, restingHeartRate: health.restingHeartRateHistory,
            sleep: health.sleepHistory,
            respiratoryRate: health.respiratoryRateHistory, wristTemperature: health.wristTemperatureHistory
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                // Same header shape as every other card on this page
                // (longevityIndexCard, biologicalAgeCard, BodyComposition,
                // LifestyleHistoryCardView) — plain headline + caption
                // subtitle, no eyebrow. This card first used
                // EterSectionHeader's eyebrow+title3 look instead, which
                // stood out against its own neighbors rather than fitting in.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lo que aprende tu gemelo").font(.headline)
                    Text("Cómo cambian tu HRV, pulso y sueño según lo que haces").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DataTrustBadge(trust: DataTrust(
                    nature: .inferred, source: "Éter · mañanas emparejadas con hábitos declarados",
                    measuredAt: lifestyle.events.first?.date,
                    samples: associations.reduce(0) { $0 + $1.samples },
                    level: bestConfidenceLevel(among: associations),
                    explanation: "Cada asociación compara tus mañanas después de un hábito contra tus mañanas habituales — solo se muestra cuando hay suficientes mañanas emparejadas.",
                    limitations: "Son asociaciones personales, no causalidad. Entrenamiento, enfermedad, viajes y factores simultáneos pueden explicar parte del cambio."
                ))
            }
            if associations.isEmpty {
                Text("Todavía no hay suficientes mañanas emparejadas. Cada hábito necesita al menos 2 registros con HRV, pulso, sueño, respiración o temperatura de muñeca al día siguiente; las conclusiones empiezan a ser útiles a partir de 4–6.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(associations.prefix(6)) { association in
                        associationRow(association)
                        if association.id != associations.prefix(6).last?.id { Divider() }
                    }
                }
            }
        }.cardStyle()
    }

    private func associationRow(_ association: HabitAssociation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    associationTitle(association); Spacer()
                    confidenceLabel(association)
                }
                VStack(alignment: .leading, spacing: 4) {
                    associationTitle(association); confidenceLabel(association)
                }
            }
            Text(association.headline).font(.caption).lineSpacing(2)
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

    private func confidenceLabel(_ association: HabitAssociation) -> some View {
        HStack(spacing: 4) {
            Circle().fill(association.confidence.level.color).frame(width: 6, height: 6)
            Text("\(association.samples) mañanas · confianza \(association.confidence.level.rawValue.lowercased())")
        }.font(.caption2).foregroundStyle(.secondary)
            .accessibilityLabel("\(association.samples) mañanas, confianza \(association.confidence.level.rawValue)")
    }
}
