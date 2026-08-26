import SwiftUI

enum DataNature: String {
    case measured = "Medido"
    case calculated = "Calculado"
    case inferred = "Inferido"
    case declared = "Declarado"
    case imported = "Importado"

    var icon: String {
        switch self {
        case .measured: return "sensor.fill"
        case .calculated: return "function"
        case .inferred: return "wand.and.stars"
        case .declared: return "person.fill"
        case .imported: return "square.and.arrow.down"
        }
    }
}

enum TrustLevel: String, Equatable {
    case high = "Alta"
    case medium = "Media"
    case low = "Baja"

    var color: Color { self == .high ? EterTheme.positive : self == .medium ? EterTheme.negative : EterTheme.danger }
}

struct DataTrust {
    let nature: DataNature
    let source: String
    let measuredAt: Date?
    let samples: Int
    let level: TrustLevel
    let explanation: String
    let limitations: String?

    var freshness: String {
        guard let measuredAt else { return "Fecha no disponible" }
        let seconds = Date().timeIntervalSince(measuredAt)
        if seconds < 3600 { return "Actualizado hace menos de una hora" }
        if seconds < 86_400 { return "Actualizado hoy" }
        if seconds < 172_800 { return "Actualizado ayer" }
        return "Actualizado el \(measuredAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct DataTrustBadge: View {
    let trust: DataTrust
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 4) {
                Circle().fill(trust.level.color).frame(width: 6, height: 6)
                Text(trust.nature.rawValue).font(.caption2.bold())
                Image(systemName: "info.circle").font(.caption2)
            }
            .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 5)
            .background(EterTheme.raisedSurface).clipShape(Capsule())
        }.buttonStyle(.plain).eterTouchTarget()
        .sheet(isPresented: $showDetail) { DataTrustDetail(trust: trust) }
    }
}

private struct DataTrustDetail: View {
    @Environment(\.dismiss) private var dismiss
    let trust: DataTrust

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: trust.nature.icon).font(.title2).foregroundStyle(trust.level.color)
                    VStack(alignment: .leading) {
                        Text(trust.nature.rawValue).font(.title3.bold())
                        Text("Confianza \(trust.level.rawValue.lowercased())").font(.caption).foregroundStyle(trust.level.color)
                    }
                }
                trustRow("Fuente", trust.source)
                trustRow("Actualidad", trust.freshness)
                trustRow("Historial", trust.samples == 1 ? "1 observación" : "\(trust.samples) observaciones")
                Divider()
                Text("Por qué tiene esta confianza").font(.headline)
                Text(trust.explanation).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                if let limitations = trust.limitations {
                    Text("Limitaciones").font(.headline)
                    Text(limitations).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                }
                Spacer()
            }.padding(20)
            .background(EterTheme.canvas)
            .navigationTitle("Calidad del dato")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }

    private func trustRow(_ name: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) { Text(name).foregroundStyle(.secondary).frame(minWidth: 82, alignment: .leading); Text(value); Spacer() }
            VStack(alignment: .leading, spacing: 3) { Text(name).foregroundStyle(.secondary); Text(value) }
        }.font(.subheadline)
    }
}
