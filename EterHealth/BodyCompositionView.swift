import SwiftUI

struct BodyCompositionView: View {
    @EnvironmentObject private var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var bodyFat = ""
    @State private var leanMass = ""
    @State private var date = Date()
    private let existing: BodyMeasurement?

    init(existing: BodyMeasurement? = nil) {
        self.existing = existing
        _weight = State(initialValue: existing?.weightKg.map { String(format: "%.1f", $0) } ?? "")
        _bodyFat = State(initialValue: existing?.bodyFatPercent.map { String(format: "%.1f", $0) } ?? "")
        _leanMass = State(initialValue: existing?.leanMassKg.map { String(format: "%.1f", $0) } ?? "")
        _date = State(initialValue: existing?.date ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Medición") {
                    TextField("Peso (kg)", text: $weight).keyboardType(.decimalPad)
                    TextField("Grasa corporal % · opcional", text: $bodyFat).keyboardType(.decimalPad)
                    TextField("Masa magra (kg) · opcional", text: $leanMass).keyboardType(.decimalPad)
                    DatePicker("Fecha", selection: $date)
                }
                Section {
                    Text("Peso, grasa y masa magra se guardan en Apple Salud. La composición de básculas domésticas es una estimación: interesa más la tendencia bajo condiciones similares que una lectura aislada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Composición corporal")
            .safeAreaInset(edge: .bottom) {
                if let existing {
                    Button(role: .destructive) {
                        Task { if await health.deleteBodyMeasurement(existing) { dismiss() } }
                    } label: { Label("Eliminar medición", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(!existing.isOwnedByEter)
                    .padding(.horizontal).padding(.bottom, 6).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        guard let kg = number(weight), kg > 0 else { return }
                        Task {
                            let success: Bool
                            if let existing {
                                success = await health.replaceBodyComposition(existing, weightKg: kg, bodyFatPercent: number(bodyFat), leanMassKg: number(leanMass), date: date)
                            } else {
                                success = await health.saveBodyComposition(weightKg: kg, bodyFatPercent: number(bodyFat), leanMassKg: number(leanMass), date: date)
                            }
                            if success { dismiss() }
                        }
                    }.bold().disabled(number(weight) == nil || (existing != nil && existing?.isOwnedByEter == false))
                }
            }
        }
    }

    private func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
}
