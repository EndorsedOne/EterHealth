import SwiftUI

struct BodyCompositionView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var inBody: InBodyStore
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var bodyFat = ""
    @State private var leanMass = ""
    // Campos InBody (los que Apple Salud no modela como tipo propio).
    @State private var skeletalMuscle = ""
    @State private var bodyFatMass = ""
    @State private var visceralFat = ""
    @State private var basalRate = ""
    @State private var fatFreeMass = ""
    @State private var totalBodyWater = ""
    @State private var date = Date()
    @State private var didLoadInBody = false
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
                    TextField("Masa muscular esquelética (kg)", text: $skeletalMuscle).keyboardType(.decimalPad)
                    TextField("Masa libre de grasa · FFM (kg)", text: $fatFreeMass).keyboardType(.decimalPad)
                    TextField("Grasa corporal (kg)", text: $bodyFatMass).keyboardType(.decimalPad)
                    TextField("Agua corporal total · TBW (kg)", text: $totalBodyWater).keyboardType(.decimalPad)
                    TextField("Grasa visceral (nivel)", text: $visceralFat).keyboardType(.numberPad)
                    TextField("Metabolismo basal (kcal)", text: $basalRate).keyboardType(.numberPad)
                } header: {
                    Text("InBody · opcional")
                } footer: {
                    Text("Datos de un escaneo InBody que Apple Salud no guarda. Peso, % de grasa y masa magra sí van a Salud; estos se guardan en Éter y se muestran por fecha.")
                }
                Section {
                    Text("La composición de básculas domésticas es una estimación: interesa más la tendencia bajo condiciones similares que una lectura aislada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Composición corporal")
            // No se puede prellenar InBody en init (el store llega por entorno):
            // se carga aquí, una sola vez, según la fecha de la medición.
            .onAppear {
                guard !didLoadInBody else { return }
                didLoadInBody = true
                if let record = inBody.measurement(on: date) {
                    skeletalMuscle = record.skeletalMuscleMassKg.map { String(format: "%.1f", $0) } ?? ""
                    bodyFatMass = record.bodyFatMassKg.map { String(format: "%.1f", $0) } ?? ""
                    visceralFat = record.visceralFatLevel.map(String.init) ?? ""
                    basalRate = record.basalMetabolicRateKcal.map { String(Int($0.rounded())) } ?? ""
                    fatFreeMass = record.fatFreeMassKg.map { String(format: "%.1f", $0) } ?? ""
                    totalBodyWater = record.totalBodyWaterKg.map { String(format: "%.1f", $0) } ?? ""
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let existing {
                    Button(role: .destructive) {
                        Task {
                            if await health.deleteBodyMeasurement(existing) {
                                inBody.removeMeasurement(on: existing.date)
                                dismiss()
                            }
                        }
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
                            if success {
                                inBody.upsert(InBodyMeasurement(
                                    date: date,
                                    skeletalMuscleMassKg: number(skeletalMuscle),
                                    bodyFatMassKg: number(bodyFatMass),
                                    visceralFatLevel: intNumber(visceralFat),
                                    basalMetabolicRateKcal: number(basalRate),
                                    fatFreeMassKg: number(fatFreeMass),
                                    totalBodyWaterKg: number(totalBodyWater)
                                ))
                                dismiss()
                            }
                        }
                    }.bold().disabled(number(weight) == nil || (existing != nil && existing?.isOwnedByEter == false))
                }
            }
        }
    }

    private func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    private func intNumber(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
}
