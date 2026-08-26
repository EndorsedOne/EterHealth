import SwiftUI

struct WorkoutReviewView: View {
    @EnvironmentObject private var store: WorkoutReviewStore
    @EnvironmentObject private var planHistory: PlanHistoryStore
    @Environment(\.dismiss) private var dismiss
    let workoutID: String
    let title: String
    let date: Date
    @State private var effort: Int
    @State private var outcome: WorkoutOutcome
    @State private var muscleFeeling: Int
    @State private var repsInReserve: Int
    @State private var pain: Bool
    @State private var note: String
    @State private var purpose: WorkoutPurpose
    private let hasExistingReview: Bool

    init(workoutID: String, title: String, date: Date, existing: WorkoutReview?) {
        self.workoutID = workoutID; self.title = title; self.date = date
        hasExistingReview = existing != nil
        _effort = State(initialValue: existing?.effort ?? 6)
        _outcome = State(initialValue: existing?.outcome ?? .asPlanned)
        _muscleFeeling = State(initialValue: existing?.muscleFeeling ?? 3)
        _repsInReserve = State(initialValue: existing?.repsInReserve ?? 2)
        _pain = State(initialValue: existing?.pain ?? false)
        _note = State(initialValue: existing?.note ?? "")
        _purpose = State(initialValue: existing?.purpose ?? .training)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline)
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Section("Plan frente a realidad") {
                    if let snapshot = planHistory.snapshot(for: date) {
                        Text(planHistory.alignment(sessionTitle: title, snapshot: snapshot)).font(.subheadline.bold())
                        Text("Recomendación guardada antes de entrenar · \(snapshot.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No hay una recomendación previa fiable guardada para esta sesión.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Esfuerzo percibido") {
                    Stepper("RPE: \(effort)/10", value: $effort, in: 1...10)
                    Text(effort <= 3 ? "Muy suave" : effort <= 6 ? "Controlado" : effort <= 8 ? "Exigente" : "Máximo o casi máximo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cómo salió") {
                    Picker("Tipo de sesión", selection: $purpose) {
                        ForEach(WorkoutPurpose.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Resultado", selection: $outcome) { ForEach(WorkoutOutcome.allCases) { Text($0.rawValue).tag($0) } }
                    Stepper("Sensación muscular: \(muscleFeeling)/5", value: $muscleFeeling, in: 1...5)
                    Stepper("Repeticiones en reserva: \(repsInReserve)", value: $repsInReserve, in: 0...6)
                    Text("En running, usa este valor como cuánto margen sentías que conservabas al terminar.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Molestias") {
                    Toggle("Dolor o molestia durante la sesión", isOn: $pain)
                    TextField("Nota opcional", text: $note, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle("Valorar entrenamiento")
            .safeAreaInset(edge: .bottom) {
                if hasExistingReview {
                    Button(role: .destructive) { store.delete(workoutID: workoutID); dismiss() } label: {
                        Label("Eliminar valoración", systemImage: "trash").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).padding(.horizontal).padding(.bottom, 6).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        store.save(WorkoutReview(workoutID: workoutID, workoutDate: date, effort: effort,
                            outcome: outcome, muscleFeeling: muscleFeeling, repsInReserve: repsInReserve,
                            pain: pain, note: note, purpose: purpose, recordedAt: Date()))
                        dismiss()
                    }.bold()
                }
            }
        }
    }
}
