import Foundation

/// Una medición de composición corporal tipo InBody. Guarda SÓLO lo que Apple
/// Salud no modela como tipo propio: masa muscular esquelética, grasa en kg,
/// nivel de grasa visceral y metabolismo basal. El peso, el % de grasa y la
/// masa magra siguen viviendo en Salud (ver BodyCompositionView), así que no se
/// duplican aquí; esta medición los complementa por fecha.
struct InBodyMeasurement: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    /// Masa muscular esquelética (kg) — la métrica de músculo de InBody.
    var skeletalMuscleMassKg: Double?
    /// Masa de grasa corporal (kg). El % de grasa va a Apple Salud.
    var bodyFatMassKg: Double?
    /// Nivel de grasa visceral (escala InBody, entero).
    var visceralFatLevel: Int?
    /// Metabolismo basal (kcal).
    var basalMetabolicRateKcal: Double?
    /// Masa magra segmental como % vs ideal por zona (InBody da "% vs ideal",
    /// no kg). Sirve para asimetrías L/R y distribución del músculo por región.
    var armLeanLeftPercent: Double?
    var armLeanRightPercent: Double?
    var legLeanLeftPercent: Double?
    var legLeanRightPercent: Double?
    var trunkLeanPercent: Double?

    /// Verdadero si tiene al menos un valor: una medición vacía no se guarda.
    var hasAnyValue: Bool {
        [skeletalMuscleMassKg, bodyFatMassKg, basalMetabolicRateKcal,
         armLeanLeftPercent, armLeanRightPercent, legLeanLeftPercent,
         legLeanRightPercent, trunkLeanPercent]
            .contains(where: { $0 != nil }) || visceralFatLevel != nil
    }

    /// Verdadero si hay al menos un valor segmental (para pintar la sección).
    var hasSegmental: Bool {
        [armLeanLeftPercent, armLeanRightPercent, legLeanLeftPercent,
         legLeanRightPercent, trunkLeanPercent]
            .contains(where: { $0 != nil })
    }
}

/// Persistencia local de las mediciones InBody. Sin singleton a propósito
/// (mismo patrón que TravelEpisodeStore / WorkoutEnrichmentStore): se crea como
/// @StateObject en EterHealthApp y se inyecta por el entorno.
@MainActor
final class InBodyStore: ObservableObject {
    @Published private(set) var measurements: [InBodyMeasurement] = []

    /// La más reciente, para la tarjeta de composición.
    var latest: InBodyMeasurement? { measurements.first }

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inbody-measurements.json")
    }

    init() { load() }

    /// Devuelve la medición registrada el mismo día natural, si existe.
    func measurement(on date: Date) -> InBodyMeasurement? {
        measurements.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    /// Inserta o reemplaza la medición del mismo día. Una sola por día: un
    /// escaneo InBody es puntual y evita duplicados al reeditar la fecha.
    func upsert(_ measurement: InBodyMeasurement) {
        measurements.removeAll { Calendar.current.isDate($0.date, inSameDayAs: measurement.date) }
        if measurement.hasAnyValue { measurements.append(measurement) }
        sortAndPersist()
    }

    /// Borra la medición del mismo día natural (al eliminar la medición de Salud
    /// correspondiente, para no dejar una InBody huérfana).
    func removeMeasurement(on date: Date) {
        let before = measurements.count
        measurements.removeAll { Calendar.current.isDate($0.date, inSameDayAs: date) }
        if measurements.count != before { sortAndPersist() }
    }

    /// Restauración desde backup (mismo contrato que otros stores).
    func restore(_ restored: [InBodyMeasurement]) {
        for measurement in restored { upsert(measurement) }
    }

    private func sortAndPersist() {
        measurements.sort { $0.date > $1.date }
        try? JSONEncoder().encode(measurements).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([InBodyMeasurement].self, from: data) else { return }
        measurements = decoded.sorted { $0.date > $1.date }
    }
}
