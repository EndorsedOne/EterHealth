import SwiftUI

private extension PlannedSessionKind {
    var forecastIcon: String {
        switch self {
        case .easyRun: return "figure.run"
        case .qualityRun: return "bolt.fill"
        case .longRun: return "figure.run.circle.fill"
        case .strength: return "dumbbell.fill"
        case .hybrid: return "figure.mixed.cardio"
        case .swim: return "figure.pool.swim"
        case .bike: return "bicycle"
        case .brick: return "arrow.triangle.2.circlepath"
        case .recovery: return "leaf.fill"
        case .raceDay: return "flag.checkered"
        }
    }

    var forecastColor: Color {
        switch self {
        case .recovery: return .gray
        case .easyRun: return EterTheme.positive
        case .qualityRun: return .orange
        case .longRun: return .blue
        case .strength: return .purple
        case .hybrid, .brick: return .pink
        case .swim: return .cyan
        case .bike: return .teal
        case .raceDay: return .red
        }
    }

    var shortLabel: String {
        switch self {
        case .easyRun: return "Suave"
        case .qualityRun: return "Calidad"
        case .longRun: return "Tirada"
        case .strength: return "Fuerza"
        case .hybrid: return "Híbrido"
        case .swim: return "Natación"
        case .bike: return "Bici"
        case .brick: return "Brick"
        case .recovery: return "Descanso"
        case .raceDay: return "Competición"
        }
    }
}

/// A 7-day forward look at what éter would recommend — today plus the
/// next 6 — so a hard day or a rest day shows up before it arrives instead
/// of only ever seeing today in isolation. When a "Simular decisión" result
/// is supplied, a real/simulated toggle lets that hypothetical replace
/// today's session (or, for a lifestyle choice, just tomorrow's readiness)
/// and recompute the rest of the week from it — the two features share one
/// forecast instead of the simulator only ever showing an isolated number.
struct WeekAheadStripView: View {
    let realDays: [TrainingPlanEngine.DayForecast]
    var simulatedDays: [TrainingPlanEngine.DayForecast]? = nil
    var simulatedDecisionLabel: String? = nil
    @State private var showSimulated = false
    @State private var selectedDate: Date?

    private var days: [TrainingPlanEngine.DayForecast] {
        (showSimulated ? simulatedDays : nil) ?? realDays
    }

    private var selected: TrainingPlanEngine.DayForecast? {
        if let selectedDate {
            return days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
        }
        return days.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            EterSectionHeader("Tu semana de entrenamiento", eyebrow: "Próximos 7 días")
            if let simulatedDays, simulatedDays.count == realDays.count {
                Picker("Vista", selection: $showSimulated) {
                    // "Plan real" read as a settled forecast rather than
                    // the live, recalculated-as-you-train projection the
                    // caption below already describes — "condicional"
                    // names what it actually is without a wording change
                    // to the (already honest) explanatory text itself.
                    Text("Plan condicional").tag(false)
                    Text("Simulación").tag(true)
                }.pickerStyle(.segmented)
                if showSimulated, let simulatedDecisionLabel {
                    Text("Mostrando: si hoy haces \"\(simulatedDecisionLabel.lowercased())\" en vez de tu plan real.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 7) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    dayChip(day, isToday: index == 0)
                }
            }
            if let selected {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: selected)).foregroundStyle(color(for: selected))
                        Text("\(dayTitle(selected.date)) · \(label(for: selected))").font(.subheadline.bold())
                        if selected.isDeload {
                            Text("DESCARGA").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(EterTheme.warning)
                        }
                    }
                    // What each kind actually asks of you — duración e
                    // intensidad, no solo la etiqueta del tipo de sesión.
                    // Hoy mismo (el día real, no simulado) ya trae este
                    // dato en "Propuesta de hoy"; esto es lo mismo,
                    // resumido, para el resto de la semana.
                    if !selected.completedSessions.isEmpty {
                        Text("HECHO HOY")
                            .font(.caption2.bold()).tracking(EterTheme.eyebrowTracking)
                            .foregroundStyle(.secondary).padding(.top, 3)
                        ForEach(selected.completedSessions) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(session.title, systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold()).foregroundStyle(.primary)
                                Text(session.detail).font(.caption2).foregroundStyle(.secondary)
                                Text(session.impact).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                            }
                            .padding(.vertical, 3)
                        }
                        if let impact = selected.weeklyImpact {
                            Label(impact, systemImage: "arrow.triangle.branch")
                                .font(.caption).foregroundStyle(EterTheme.positive).lineSpacing(2)
                                .padding(.top, 2)
                        }
                    } else {
                        Label(sessionSummary(selected), systemImage: "gauge.with.dots.needle.50percent")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(selected.prescription)
                            .font(.caption).foregroundStyle(.primary).lineSpacing(2)
                        if !selected.strengthExercises.isEmpty {
                            Divider().padding(.vertical, 3)
                            HStack {
                                Text(selected.strengthTitle ?? "Sesión de fuerza").font(.caption.bold())
                                Spacer()
                                if let duration = selected.strengthDuration {
                                    Text(duration).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(selected.strengthExercises) { exercise in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(exercise.name).font(.caption.bold())
                                    Text(exercise.prescription).font(.caption2).foregroundStyle(.secondary)
                                    Text(exercise.cue).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                }.padding(.vertical, 2)
                            }
                            if !selected.strengthVolumeTargets.isEmpty {
                                Text("VOLUMEN DE ESTA SEMANA")
                                    .font(.caption2.bold()).tracking(EterTheme.eyebrowTracking)
                                    .foregroundStyle(.secondary).padding(.top, 4)
                                ForEach(selected.strengthVolumeTargets) { target in
                                    let after = target.completedSets + target.plannedSets
                                    HStack {
                                        Text(target.muscle).font(.caption2)
                                        Spacer()
                                        Text("\(target.completedSets, specifier: "%.0f") + \(target.plannedSets, specifier: "%.1f") → \(after, specifier: "%.1f") / \(target.targetSets, specifier: "%.0f") series")
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Text(selected.rationale).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EterTheme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: selectedDate)
                .animation(.easeInOut(duration: 0.15), value: showSimulated)
            }
            Text(showSimulated
                ? "Esta vista es hipotética: hoy sustituye tu plan real por la decisión simulada y el resto de la semana se recalcula a partir de ella."
                : "Hoy es tu recomendación real. A partir de mañana, la proyección asume que sigues el plan recomendado cada día —ni reposo indefinido ni el mismo entrenamiento repetido— y mantiene tu disponibilidad de hoy, porque no podemos predecir tu sueño o tu HRV futuros. Se recalcula según entrenas y registras nuevas señales.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    // .recovery covers two genuinely different situations: real rest, and
    // "you already did a real session today — the rest is your choice, not
    // obligatory". This used to only recognize the specific "tren superior,
    // sin piernas" case (string-matching that one rationale phrase), so a
    // completed HIIT session — or any other kind of session that routes
    // into the generic "ya has entrenado hoy" fallback — still showed a
    // plain rest-leaf, as if the plan hadn't noticed. Now driven directly
    // by `alreadyTrainedToday`, the same real flag `status()` computed the
    // decision from, instead of re-deriving it from prose.
    private func icon(for day: TrainingPlanEngine.DayForecast) -> String {
        isCompletedTrainingDay(day) ? "checkmark.circle.fill" : day.kind.forecastIcon
    }
    private func color(for day: TrainingPlanEngine.DayForecast) -> Color {
        isCompletedTrainingDay(day) ? .purple : day.kind.forecastColor
    }
    private func label(for day: TrainingPlanEngine.DayForecast) -> String {
        isCompletedTrainingDay(day) ? "Entrenado hoy" : day.kind.rawValue
    }
    private func isCompletedTrainingDay(_ day: TrainingPlanEngine.DayForecast) -> Bool {
        day.alreadyTrainedToday
    }

    // "Ritmo, nivel de exigencia" the week strip was missing — duration
    // in minutes (when this kind has one; strength/recovery/race day
    // deliberately don't, see DayForecast's own comment) plus the same
    // zone/effort label the daily card already uses. No distance: this
    // app never computes a per-session target distance, real or
    // simulated, only duration + zone.
    private func sessionSummary(_ day: TrainingPlanEngine.DayForecast) -> String {
        guard let minutes = day.targetMinutes else { return day.intensityLabel }
        return "≈\(minutes) min · \(day.intensityLabel)"
    }

    private func dayChip(_ day: TrainingPlanEngine.DayForecast, isToday: Bool) -> some View {
        let isSelected = selected.map { Calendar.current.isDate($0.date, inSameDayAs: day.date) } ?? false
        return Button {
            selectedDate = day.date
        } label: {
            VStack(spacing: 4) {
                Text(isToday ? "HOY" : weekdayLabel(day.date))
                    .font(.caption2.bold()).foregroundStyle(isSelected ? .white : .secondary)
                Image(systemName: icon(for: day))
                    .font(.body).foregroundStyle(isSelected ? .white : color(for: day))
                Text(dayNumber(day.date))
                    .font(.caption2).monospacedDigit().foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(isSelected ? color(for: day) : color(for: day).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if day.isDeload {
                    Circle().fill(Color.orange).frame(width: 7, height: 7).padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .eterTouchTarget()
        .accessibilityLabel("\(isToday ? "Hoy" : weekdayFullLabel(day.date)): \(day.kind.rawValue)\(day.isDeload ? ", descarga" : "")")
        .accessibilityHint(isCompletedTrainingDay(day)
            ? "\(day.completedSessions.count) sesiones completadas. \(day.weeklyImpact ?? day.rationale)"
            : "\(sessionSummary(day)). \(day.prescription). \(day.rationale)")
    }

    private func dayTitle(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Hoy" : weekdayFullLabel(date).capitalized
    }

    private func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func weekdayFullLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }
}
