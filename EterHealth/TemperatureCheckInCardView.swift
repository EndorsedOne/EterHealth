import SwiftUI

// Detects a real, today-fresh wrist-temperature rise — the same 2%-of-
// habitual dead zone PhysiologicalHealthView's extendedSignalRow already
// uses to decide "worth coloring" — and, instead of leaving it uncolored
// and unexplained the way that card's deliberate favorableHigh: nil
// treatment always has (there's no single settled direction for WHY
// wrist temperature rose), asks the one thing this app cannot infer on
// its own: what's actually going on. Every answer becomes ground truth
// TemperatureDeviationInsightEngine tallies into a real personal
// frequency — never a guessed correlation.
struct TemperatureCheckInCardView: View {
    let points: [TrendPoint]
    @EnvironmentObject private var store: TemperatureDeviationStore
    @State private var reasons: Set<TemperatureDeviationReason> = []
    @State private var note: String = ""
    @State private var isEditing = false

    init(points: [TrendPoint]) {
        self.points = points
        if let last = points.last, Calendar.current.isDateInToday(last.date),
           let existing = TemperatureDeviationStore.shared.existingLog(for: last.date) {
            _reasons = State(initialValue: existing.reasons)
            _note = State(initialValue: existing.note)
        }
    }

    // Needs the same >=14-real-days floor as extendedSignalRow before
    // "your habitual mean" means anything, and only fires for a reading
    // from TODAY — a deviation from three days ago isn't something to
    // still be asking about now.
    private var todaysDeviation: (delta: Double, mean: Double, date: Date)? {
        guard let last = points.last, Calendar.current.isDateInToday(last.date) else { return nil }
        let recentValues = Array(points.suffix(56)).map(\.value)
        guard recentValues.count >= 14 else { return nil }
        let mean = recentValues.reduce(0, +) / Double(recentValues.count)
        return (last.value - mean, mean, last.date)
    }

    var body: some View {
        let deviation = todaysDeviation
        let significantToday = deviation.map { TemperatureDeviationInsightEngine.isSignificantRise(delta: $0.delta, mean: $0.mean) } ?? false
        let headline = TemperatureDeviationInsightEngine.headline(store.logs)
        if significantToday || headline != nil {
            VStack(alignment: .leading, spacing: 13) {
                header
                if let deviation, significantToday {
                    todaySection(deviation)
                }
                if let headline {
                    if significantToday { Divider() }
                    Label(headline, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).lineSpacing(2)
                }
            }.cardStyle()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Temperatura de muñeca").font(.headline)
                Text("Qué suele explicar tus subidas, según tus propias respuestas").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder private func todaySection(_ deviation: (delta: Double, mean: Double, date: Date)) -> some View {
        let existing = store.existingLog(for: deviation.date)
        HStack(spacing: 7) {
            Image(systemName: "thermometer.sun.fill").foregroundStyle(EterTheme.warning)
            Text("Hoy +\(deviation.delta.formatted(.number.precision(.fractionLength(1)))) °C sobre tu media habitual.")
                .font(.subheadline.bold())
        }
        if let existing, !existing.reasons.isEmpty, !isEditing {
            VStack(alignment: .leading, spacing: 6) {
                Text("Registraste: \(existing.reasons.map(\.rawValue).sorted().joined(separator: ", ").lowercased())")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Editar respuesta") { isEditing = true }.font(.caption.bold())
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("¿Te está pasando algo de esto?").font(.subheadline.bold())
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(TemperatureDeviationReason.allCases) { reason in reasonChip(reason) }
                }
                TextField("Nota opcional", text: $note).textFieldStyle(.roundedBorder).font(.subheadline)
                HStack {
                    Button("Guardar") { save(deviation) }
                        .font(.subheadline.bold()).disabled(reasons.isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty)
                    if existing != nil {
                        Spacer()
                        Button("Cancelar") { reasons = existing?.reasons ?? []; note = existing?.note ?? ""; isEditing = false }
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reasonChip(_ reason: TemperatureDeviationReason) -> some View {
        let isSelected = reasons.contains(reason)
        return Button {
            if isSelected { reasons.remove(reason) } else { reasons.insert(reason) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: reason.icon).font(.caption2)
                Text(reason.rawValue).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(isSelected ? EterTheme.primary.opacity(0.18) : Color.primary.opacity(0.06))
            .foregroundStyle(isSelected ? EterTheme.primary : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).eterTouchTarget()
        .accessibilityLabel(reason.rawValue)
        .accessibilityValue(isSelected ? "Seleccionado" : "No seleccionado")
    }

    private func save(_ deviation: (delta: Double, mean: Double, date: Date)) {
        store.save(TemperatureDeviationLog(
            id: store.existingLog(for: deviation.date)?.id ?? UUID(),
            date: deviation.date, deviationC: deviation.delta, reasons: reasons, note: note
        ))
        isEditing = false
    }
}
