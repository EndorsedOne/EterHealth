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
    let currentEnergy: Int?
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
            if let currentEnergy {
                trainingNowGuidance(energy: currentEnergy)
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
        VStack(alignment: .leading, spacing: 3) {
            Text("PREPARACIÓN PARA ENTRENAR")
                .font(.caption2.bold())
                .tracking(EterTheme.eyebrowTracking)
                .foregroundStyle(.secondary)
            Text("Tu capacidad fisiológica para entrenar hoy")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
        .accessibilityLabel("Preparación para entrenar \(assessment.score) de 100")
    }

    private var recommendation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(assessment.state.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(scoreColor)
            Text(assessment.recommendation).font(.title2).fontDesign(.serif)
            Text(assessment.explanation).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainingNowGuidance(energy: Int) -> some View {
        let guidance = TrainingNowGuidance.evaluate(readiness: assessment.score, energy: energy)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: guidance.systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(guidanceColor(guidance.level))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(guidance.title).font(.subheadline.bold())
                    Spacer(minLength: 8)
                    Text("Energía \(energy)/100")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(guidance.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(guidanceColor(guidance.level).opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func guidanceColor(_ level: TrainingNowGuidance.Level) -> Color {
        switch level {
        case .go: EterTheme.positive
        case .adjust: EterTheme.warning
        case .recover: EterTheme.danger
        }
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

/// Traduce dos señales deliberadamente distintas a una decisión inmediata.
/// La preparación limita cuánto entrenamiento es prudente tolerar; la energía
/// sólo modula si este momento del día es adecuado. Por eso mucha energía no
/// puede anular una preparación baja, pero poca energía sí puede recomendar
/// aplazar una sesión que fisiológicamente sería tolerable.
struct TrainingNowGuidance: Equatable {
    enum Level: Equatable { case go, adjust, recover }

    let title: String
    let detail: String
    let systemImage: String
    let level: Level

    nonisolated static func evaluate(readiness: Int, energy: Int) -> Self {
        if readiness < 55 {
            if energy >= 55 {
                return Self(
                    title: "Tienes energía, pero necesitas recuperar",
                    detail: "La sensación de energía no compensa todavía la carga o recuperación pendiente.",
                    systemImage: "shield.lefthalf.filled",
                    level: .recover
                )
            }
            return Self(
                title: "Prioriza recuperación",
                detail: "Preparación y energía están bajas; hoy conviene reducir o evitar la carga.",
                systemImage: "bed.double.fill",
                level: .recover
            )
        }

        if energy < 35 {
            return Self(
                title: "Preparado, pero con poca energía ahora",
                detail: "Podrías tolerar la sesión, pero es mejor descansar, comer o aplazarla si puedes.",
                systemImage: "clock.badge.exclamationmark",
                level: .adjust
            )
        }

        if readiness < 65 || energy < 50 {
            return Self(
                title: "Entrena con margen",
                detail: "Puedes entrenar, ajustando volumen o intensidad a cómo te encuentres al empezar.",
                systemImage: "gauge.with.dots.needle.50percent",
                level: .adjust
            )
        }

        return Self(
            title: "Buen momento para entrenar",
            detail: "Tu preparación y tu energía actual acompañan la sesión prevista.",
            systemImage: "figure.strengthtraining.traditional",
            level: .go
        )
    }
}
