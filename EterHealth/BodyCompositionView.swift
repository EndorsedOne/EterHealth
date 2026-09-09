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
    // Masa magra segmental (kg) por zona.
    @State private var armLeanLeft = ""
    @State private var armLeanRight = ""
    @State private var legLeanLeft = ""
    @State private var legLeanRight = ""
    @State private var trunkLean = ""
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
                    TextField("Grasa corporal (kg)", text: $bodyFatMass).keyboardType(.decimalPad)
                    TextField("Grasa visceral (nivel)", text: $visceralFat).keyboardType(.numberPad)
                    TextField("Metabolismo basal (kcal)", text: $basalRate).keyboardType(.numberPad)
                } header: {
                    Text("InBody · opcional")
                } footer: {
                    Text("Datos de un escaneo InBody que Apple Salud no guarda. Peso, % de grasa y masa magra sí van a Salud; estos se guardan en Éter y se muestran por fecha.")
                }
                Section {
                    HStack {
                        TextField("Brazo izq (% vs ideal)", text: $armLeanLeft).keyboardType(.decimalPad)
                        TextField("Brazo der (% vs ideal)", text: $armLeanRight).keyboardType(.decimalPad)
                    }
                    HStack {
                        TextField("Pierna izq (% vs ideal)", text: $legLeanLeft).keyboardType(.decimalPad)
                        TextField("Pierna der (% vs ideal)", text: $legLeanRight).keyboardType(.decimalPad)
                    }
                    TextField("Tronco (% vs ideal)", text: $trunkLean).keyboardType(.decimalPad)
                } header: {
                    Text("Segmental · masa magra por zona · opcional")
                } footer: {
                    Text("El % de masa magra (FFM) vs ideal de cada zona, tal cual lo da InBody (ej. tronco 112,4%). Usa las tarjetas de \"Fat free mass % … compared to ideal\", no las de grasa. Sirve para ver asimetrías izquierda/derecha y la distribución del músculo por región.")
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
                    armLeanLeft = record.armLeanLeftPercent.map { String(format: "%.1f", $0) } ?? ""
                    armLeanRight = record.armLeanRightPercent.map { String(format: "%.1f", $0) } ?? ""
                    legLeanLeft = record.legLeanLeftPercent.map { String(format: "%.1f", $0) } ?? ""
                    legLeanRight = record.legLeanRightPercent.map { String(format: "%.1f", $0) } ?? ""
                    trunkLean = record.trunkLeanPercent.map { String(format: "%.1f", $0) } ?? ""
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
                                    armLeanLeftPercent: number(armLeanLeft),
                                    armLeanRightPercent: number(armLeanRight),
                                    legLeanLeftPercent: number(legLeanLeft),
                                    legLeanRightPercent: number(legLeanRight),
                                    trunkLeanPercent: number(trunkLean)
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
