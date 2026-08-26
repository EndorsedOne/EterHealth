import SwiftUI

struct InjuryHistoryView: View {
    @EnvironmentObject private var store: InjuryStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: InjuryRecord?

    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty {
                    ContentUnavailableView("Sin lesiones registradas", systemImage: "cross.case",
                                           description: Text("Añade solo molestias que deban modificar el entrenamiento."))
                }
                ForEach(store.records) { record in
                    Button { editing = record } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(record.area).font(.headline); Spacer(); Text(record.isActive ? "Activa" : "Resuelta").font(.caption.bold()).foregroundStyle(record.isActive ? EterTheme.negative : EterTheme.positive) }
                            Text("Grado \(record.severity)/5 · \(record.restrictions.map(\.rawValue).sorted().joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                .onDelete { offsets in offsets.map { store.records[$0].id }.forEach(store.delete) }
            }
            .navigationTitle("Lesiones y restricciones")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = InjuryRecord(id: UUID(), area: "", startedAt: Date(), resolvedAt: nil, severity: 2, restrictions: [], note: "") } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { record in InjuryEditor(record: record).environmentObject(store) }
        }
    }
}

private struct InjuryEditor: View {
    @EnvironmentObject private var store: InjuryStore
    @Environment(\.dismiss) private var dismiss
    @State var record: InjuryRecord

    var body: some View {
        NavigationStack {
            Form {
                TextField("Zona o lesión", text: $record.area)
                DatePicker("Inicio", selection: $record.startedAt, displayedComponents: .date)
                Stepper("Impacto actual: \(record.severity)/5", value: $record.severity, in: 1...5)
                Toggle("Resuelta", isOn: Binding(get: { record.resolvedAt != nil }, set: { record.resolvedAt = $0 ? Date() : nil }))
                Section("Restricciones") {
                    ForEach(TrainingRestriction.allCases) { restriction in
                        Toggle(restriction.rawValue, isOn: restrictionBinding(restriction))
                    }
                }
                TextField("Nota opcional", text: $record.note, axis: .vertical).lineLimit(2...5)
            }
            .navigationTitle("Restricción")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { store.save(record); dismiss() }.bold().disabled(record.area.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }

    private func restrictionBinding(_ restriction: TrainingRestriction) -> Binding<Bool> {
        Binding(
            get: { record.restrictions.contains(restriction) },
            set: { enabled in
                if enabled { record.restrictions.insert(restriction) }
                else { record.restrictions.remove(restriction) }
            }
        )
    }
}
