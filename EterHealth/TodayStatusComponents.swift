import SwiftUI

struct PhysiologicalAlertCard: View {
    let alert: PhysiologicalAlert
    let trust: DataTrust
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { alertHeader; Spacer(minLength: 4); DataTrustBadge(trust: trust) }
                VStack(alignment: .leading, spacing: 8) { alertHeader; DataTrustBadge(trust: trust) }
            }
            if !alert.signals.isEmpty {
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 150 : 92), alignment: .leading)], spacing: 12) {
                    ForEach(alert.signals, id: \.name) { signal in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal.name).font(.caption).foregroundStyle(.secondary)
                            Text(signal.value).font(.subheadline.bold()).monospacedDigit()
                            Text(signal.favorableDeviation <= -1.75 ? "Muy fuera de tu rango" : "Fuera de tu rango")
                                .font(.caption2.bold()).foregroundStyle(EterTheme.warning)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Label(alert.action, systemImage: "arrow.right.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(alert.severity == .recover ? EterTheme.danger : EterTheme.primary)
                .lineSpacing(3)
            Text("No es una alerta clínica ni diagnostica enfermedad.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cambio fisiológico. \(alert.title). \(alert.summary). \(alert.action)")
    }

    private var alertHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity == .recover ? "heart.slash.fill" : "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(alert.severity == .recover ? EterTheme.danger : EterTheme.warning)
                .frame(minWidth: 34)
            // Not EterSectionHeader here: alert.summary is deliberately
            // .subheadline (not the header's .caption) — this is an
            // attention card, its explanation carries real weight.
            VStack(alignment: .leading, spacing: 4) {
                Text("CAMBIO FISIOLÓGICO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                Text(alert.title).font(.title3.bold())
                Text(alert.summary).font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
            }
        }
    }
}

struct ReadinessCard: View {
    let assessment: TwinAssessment
    let trust: DataTrust
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack { eyebrow; Spacer(); DataTrustBadge(trust: trust) }
                VStack(alignment: .leading, spacing: 7) { eyebrow; DataTrustBadge(trust: trust) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) { scoreRing; recommendation }
                VStack(alignment: .leading, spacing: 14) { scoreRing; recommendation }
            }
            Divider()
            Text("POR QUÉ").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            // Every signal already carries a plain-language `detail`
            // explaining itself — computed for every factor from alcohol
            // to supplements, but previously never rendered anywhere in
            // the app. This is the reasoning behind the score, not just
            // the number.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(assessment.signals.prefix(4)) { signal in
                    signalRow(signal)
                    if signal.id != assessment.signals.prefix(4).last?.id { Divider() }
                }
            }
            Text("RECUPERACIÓN MUSCULAR").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            ForEach(assessment.muscles) { muscle in muscleRow(muscle) }
            Text("Estimación orientativa basada en tu línea base y en la carga importada. No mide daño muscular ni sustituye sensaciones o criterio profesional.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { personalization; Spacer(); confidenceLabel }
                VStack(alignment: .leading, spacing: 5) { personalization; confidenceLabel }
            }
            .font(.caption2.bold()).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func signalRow(_ signal: TwinSignal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(signal.name).font(.subheadline.bold())
                Text(signal.value).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(signal.impact > 0 ? "+\(signal.impact)" : "\(signal.impact)")
                    .font(.caption.bold())
                    .foregroundStyle(signal.impact > 0 ? EterTheme.positive : signal.impact < 0 ? EterTheme.negative : .secondary)
            }
            if !signal.detail.isEmpty {
                Text(signal.detail).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
        }
    }

    private var eyebrow: some View {
        Text("DISPONIBILIDAD DE HOY").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
    }

    private var scoreRing: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.11), lineWidth: 9)
            Circle().trim(from: 0, to: Double(assessment.score) / 100)
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(assessment.score)").font(.title.bold()).fontDesign(.rounded).monospacedDigit()
                Text("/100").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 112 : 100,
               height: dynamicTypeSize.isAccessibilitySize ? 112 : 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disponibilidad \(assessment.score) de 100")
    }

    private var recommendation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(assessment.state.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(scoreColor)
            Text(assessment.recommendation).font(.title2).fontDesign(.serif)
            Text(assessment.explanation).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func muscleRow(_ muscle: MuscleReadiness) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(muscle.name); Spacer(); Text("\(muscle.readiness)%").monospacedDigit() }
                muscleBar(muscle.readiness)
            }.font(.subheadline)
        } else {
            HStack {
                Text(muscle.name).font(.subheadline)
                Spacer(minLength: 10)
                muscleBar(muscle.readiness).frame(maxWidth: 120)
                Text("\(muscle.readiness)%").font(.caption.monospacedDigit()).frame(minWidth: 38, alignment: .trailing)
            }
        }
    }

    private func muscleBar(_ readiness: Int) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(muscleColor(readiness))
                    .frame(width: proxy.size.width * Double(readiness) / 100)
            }
        }.frame(height: 8).accessibilityHidden(true)
    }

    private var personalization: some View {
        Label("Personalización: \(assessment.baselineConfidence)%", systemImage: "person.crop.circle.badge.checkmark")
    }

    private var confidenceLabel: some View {
        Text(assessment.baselineConfidence >= 70 ? "Alta" : assessment.baselineConfidence >= 40 ? "En aprendizaje" : "Inicial")
    }

    private var scoreColor: Color {
        assessment.score >= 70 ? EterTheme.positive : assessment.score >= 45 ? EterTheme.negative : EterTheme.danger
    }

    private func muscleColor(_ value: Int) -> Color {
        value >= 75 ? EterTheme.positive : value >= 50 ? EterTheme.warning : EterTheme.danger
    }
}
