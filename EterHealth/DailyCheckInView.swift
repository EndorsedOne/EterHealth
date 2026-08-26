import SwiftUI

struct DailyCheckInView: View {
    @EnvironmentObject private var store: DailyCheckInStore
    @Environment(\.dismiss) private var dismiss
    @State private var entry: DailyCheckIn
    private let hasExistingEntry: Bool

    private let muscleAreas = ["Piernas", "Glúteos", "Pecho", "Espalda", "Hombros", "Brazos", "Core"]
    private let painAreas = ["Rodilla", "Tobillo", "Cadera", "Lumbar", "Hombro", "Codo", "Muñeca", "Otro"]

    init(existing: DailyCheckIn?) {
        hasExistingEntry = existing != nil
        _entry = State(initialValue: existing ?? .empty())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Responde por sensación, sin pensarlo demasiado. No hay respuestas buenas o malas.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)

                    VStack(spacing: 15) {
                        scale("Energía", value: $entry.energy, low: "Vacío", high: "A tope", icon: "bolt.fill", reversed: false)
                        scale("Fatiga", value: $entry.fatigue, low: "Fresco", high: "Agotado", icon: "battery.25", reversed: true)
                        scale("Estrés", value: $entry.stress, low: "Calmado", high: "Muy alto", icon: "brain.head.profile", reversed: true)
                        scale("Motivación", value: $entry.motivation, low: "Ninguna", high: "Muy alta", icon: "flame.fill", reversed: false)
                        scale("Sensación del sueño", value: $entry.sleepFeeling, low: "Mala", high: "Excelente", icon: "moon.fill", reversed: false)
                    }.checkInCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("AGUJETAS").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        Text("Toca una zona para indicar intensidad: sin agujetas → leves → medias → fuertes.")
                            .font(.caption2).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(muscleAreas, id: \.self) { area in
                                Button { cycleSoreness(area) } label: {
                                    HStack { Text(area); Spacer(); Text(sorenessLabel(entry.soreness[area] ?? 0)).font(.caption2.bold()) }
                                        .font(.caption).padding(10).background(sorenessColor(entry.soreness[area] ?? 0)).clipShape(RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).eterTouchTarget()
                                    .accessibilityLabel("Agujetas en \(area)")
                                    .accessibilityValue(sorenessLabel(entry.soreness[area] ?? 0))
                            }
                        }
                    }.checkInCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("DOLOR O MOLESTIAS").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        FlowLayout(spacing: 7) {
                            ForEach(painAreas, id: \.self) { area in
                                Button { togglePain(area) } label: {
                                    Text(area).font(.caption.bold()).padding(.horizontal, 11).padding(.vertical, 8)
                                        .background(entry.painAreas.contains(area) ? EterTheme.danger.opacity(0.16) : Color.primary.opacity(0.08))
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain).eterTouchTarget()
                                    .accessibilityLabel("Dolor o molestias en \(area)")
                                    .accessibilityValue(entry.painAreas.contains(area) ? "Seleccionado" : "No seleccionado")
                            }
                        }
                        Toggle("¿Notas síntomas de enfermedad?", isOn: $entry.illness).font(.subheadline)
                        TextField("Nota opcional", text: $entry.note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        Text("Dolor agudo, dolor torácico, dificultad respiratoria o síntomas preocupantes no deben resolverse con una puntuación: detén el ejercicio y busca valoración profesional.")
                            .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                    }.checkInCard()
                }.padding(18)
            }
            .background(EterTheme.canvas)
            .navigationTitle("Check-in de hoy")
            .safeAreaInset(edge: .bottom) {
                if hasExistingEntry {
                    Button(role: .destructive) { store.delete(for: entry.day); dismiss() } label: {
                        Label("Eliminar check-in", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).padding(.horizontal).padding(.bottom, 6).background(.bar)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { store.save(entry); dismiss() }.bold() }
            }
        }
    }

    private func scale(_ title: String, value: Binding<Int>, low: String, high: String, icon: String, reversed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Label(title, systemImage: icon).font(.subheadline.bold()); Spacer(); Text("\(value.wrappedValue)/5").font(.subheadline.monospacedDigit().bold()) }
            HStack(spacing: 7) {
                ForEach(1...5, id: \.self) { number in
                    Button { value.wrappedValue = number } label: {
                        Circle().fill(number <= value.wrappedValue ? scaleColor(value.wrappedValue, reversed: reversed) : Color.primary.opacity(0.11))
                            .frame(height: 24).overlay(Text("\(number)").font(.caption2.bold()).foregroundStyle(number <= value.wrappedValue ? .white : .secondary))
                    }.buttonStyle(.plain).eterTouchTarget()
                        .accessibilityLabel("\(title), \(number) de 5")
                        .accessibilityAddTraits(number == value.wrappedValue ? .isSelected : [])
                }
            }
            HStack { Text(low); Spacer(); Text(high) }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func scaleColor(_ value: Int, reversed: Bool) -> Color {
        let favorable = reversed ? 6 - value : value
        return favorable >= 4 ? EterTheme.positive : favorable >= 3 ? EterTheme.negative : EterTheme.danger
    }
    private func cycleSoreness(_ area: String) { entry.soreness[area] = ((entry.soreness[area] ?? 0) + 1) % 4 }
    private func togglePain(_ area: String) { entry.painAreas.contains(area) ? entry.painAreas.removeAll { $0 == area } : entry.painAreas.append(area) }
    private func sorenessLabel(_ value: Int) -> String { ["No", "Leves", "Medias", "Fuertes"][max(0, min(3, value))] }
    private func sorenessColor(_ value: Int) -> Color { value == 0 ? Color.primary.opacity(0.08) : value == 1 ? .yellow.opacity(0.18) : value == 2 ? EterTheme.negative.opacity(0.2) : EterTheme.danger.opacity(0.18) }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension View {
    // Used to be its own near-clone of cardStyle() (16pt padding, no
    // stroke/shadow) — drifted from the shared one over time. Same
    // container everywhere now.
    func checkInCard() -> some View { cardStyle() }
}
