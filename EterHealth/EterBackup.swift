import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct EterBackup: Codable {
    static let currentSchemaVersion = 8

    let format: String
    let schemaVersion: Int
    let createdAt: Date
    let importedWorkouts: [ImportedWorkout]
    let labResults: [LabResult]
    let checkIns: [DailyCheckIn]
    let lifestyleEvents: [LifestyleEvent]
    let workoutReviews: [WorkoutReview]
    let planSnapshots: [PlanSnapshot]
    let strengthRoutines: [String: StrengthRoutine]
    let goalProfile: AthletePlanProfile?
    let injuryRecords: [InjuryRecord]?
    let dailyTwinStates: [TwinDailyState]?
    // Added in schema 5. HealthKit-derived, one-directional (see
    // HealthExportSnapshot) — nil only for backups made before this existed.
    let health: HealthExportSnapshot?
    // Added in schema 6 — the user's own answers to "¿te está pasando algo
    // de esto?" for wrist-temperature deviations (TemperatureDeviationStore).
    // nil only for backups made before this existed.
    let temperatureDeviationLogs: [TemperatureDeviationLog]?
    // Added in schema 7 — los episodios de viaje (TravelEpisodeStore). nil
    // sólo en copias hechas antes de que existieran. Mismo patrón Optional que
    // los dos campos anteriores: una copia vieja tiene que seguir
    // restaurándose sin este dato, no fallar por él.
    let travelEpisodes: [TravelEpisode]?
    // Schema 8: variables de máquina enlazadas a entrenamientos de Apple
    // Salud. Son datos propios de Éter y sí deben poder restaurarse.
    let workoutEnrichments: [WorkoutEnrichment]?

    var totalRecords: Int {
        // Cada término con su tipo explícito y sumados con reduce, en vez de
        // una sola expresión: al añadir el cuarto campo Optional, la cadena de
        // `?.count ?? 0` sumados con `+` dejó de type-checkear en tiempo
        // razonable (el inferidor tiene que probar todas las sobrecargas de
        // `+` y de `??` a la vez). No es un problema de este campo en
        // concreto, es el cuarto que rompe la espalda del camello.
        let counts: [Int] = [
            importedWorkouts.count, labResults.count, checkIns.count, lifestyleEvents.count,
            workoutReviews.count, planSnapshots.count, strengthRoutines.count,
            injuryRecords?.count ?? 0, dailyTwinStates?.count ?? 0,
            temperatureDeviationLogs?.count ?? 0, travelEpisodes?.count ?? 0,
            workoutEnrichments?.count ?? 0
        ]
        return counts.reduce(0, +)
    }

    var summary: String {
        // Misma razón que en totalRecords: una sola concatenación con siete
        // interpolaciones deja de type-checkear al añadir la octava. Un array
        // de partes y un join, que además hace trivial añadir la siguiente.
        let parts = [
            "\(importedWorkouts.count) entrenamientos importados",
            "\(labResults.count) resultados clínicos",
            "\(checkIns.count) check-ins",
            "\(lifestyleEvents.count) factores",
            "\(workoutReviews.count) valoraciones",
            "\(planSnapshots.count) decisiones del plan",
            "\(strengthRoutines.count) rutinas personalizadas",
            "\(injuryRecords?.count ?? 0) registros de lesiones",
            "\(dailyTwinStates?.count ?? 0) estados diarios del gemelo",
            "\(temperatureDeviationLogs?.count ?? 0) respuestas de temperatura de muñeca",
            "\(travelEpisodes?.count ?? 0) viajes registrados",
            "\(workoutEnrichments?.count ?? 0) entrenamientos completados con datos de máquina"
        ]
        return parts.joined(separator: ", ") + "."
    }
}

enum EterBackupError: LocalizedError {
    case unreadableFile
    case invalidFormat
    case unsupportedVersion(Int)
    case automaticFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "El archivo no contiene una copia legible de Éter."
        case .invalidFormat: return "El archivo seleccionado no es una copia de Éter."
        case .unsupportedVersion(let version):
            return "La copia usa la versión \(version), que esta instalación todavía no puede restaurar."
        case .automaticFolderUnavailable:
            return "La carpeta de copia automática ya no está disponible. Selecciónala de nuevo."
        }
    }
}

enum EterBackupCodec {
    static func encode(_ backup: EterBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> EterBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(EterBackup.self, from: data)
        guard backup.format == "eter-health-backup" else { throw EterBackupError.invalidFormat }
        guard backup.schemaVersion <= EterBackup.currentSchemaVersion else {
            throw EterBackupError.unsupportedVersion(backup.schemaVersion)
        }
        return backup
    }
}

struct EterBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let backup: EterBackup

    init(backup: EterBackup) { self.backup = backup }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw EterBackupError.unreadableFile }
        backup = try EterBackupCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try EterBackupCodec.encode(backup))
    }
}

@MainActor
enum EterBackupManager {
    private static let defaults = UserDefaults.standard
    private static let folderBookmarkKey = "eter.automatic-backup.folder-bookmark"
    private static let folderNameKey = "eter.automatic-backup.folder-name"
    private static let lastSuccessKey = "eter.automatic-backup.last-success"
    static let automaticFilename = "EterHealth-copia-automatica.json"

    static var automaticFolderName: String? { defaults.string(forKey: folderNameKey) }
    static var automaticLastSuccess: Date? { defaults.object(forKey: lastSuccessKey) as? Date }
    static var automaticBackupEnabled: Bool { defaults.data(forKey: folderBookmarkKey) != nil }

    // `travel` llega como parámetro y no se lee de un `.shared` como
    // GoalStore/InjuryStore de abajo: TravelEpisodeStore no tiene singleton a
    // propósito (ver su cabecera), así que la inyección es obligatoria y no
    // una preferencia de estilo.
    static func make(imports: ImportStore, checkIns: DailyCheckInStore,
                     lifestyle: LifestyleFactorStore, workoutReviews: WorkoutReviewStore,
                     planHistory: PlanHistoryStore, strengthRoutines: StrengthRoutineStore,
                     health: HealthStore, travel: TravelEpisodeStore,
                     workoutEnrichments: WorkoutEnrichmentStore) -> EterBackup {
        EterBackup(
            format: "eter-health-backup", schemaVersion: EterBackup.currentSchemaVersion,
            createdAt: Date(), importedWorkouts: imports.workouts, labResults: imports.labs,
            checkIns: checkIns.entries, lifestyleEvents: lifestyle.events,
            workoutReviews: workoutReviews.reviews, planSnapshots: planHistory.snapshots,
            strengthRoutines: strengthRoutines.saved, goalProfile: GoalStore.shared.profile,
            injuryRecords: InjuryStore.shared.records, dailyTwinStates: TwinStateStore.shared.states,
            health: HealthExportSnapshot.capture(from: health),
            temperatureDeviationLogs: TemperatureDeviationStore.shared.logs,
            travelEpisodes: travel.episodes,
            workoutEnrichments: workoutEnrichments.enrichments
        )
    }

    static func restore(_ backup: EterBackup, imports: ImportStore, checkIns: DailyCheckInStore,
                        lifestyle: LifestyleFactorStore, workoutReviews: WorkoutReviewStore,
                        planHistory: PlanHistoryStore, strengthRoutines: StrengthRoutineStore,
                        travel: TravelEpisodeStore, workoutEnrichments: WorkoutEnrichmentStore) {
        imports.restore(workouts: backup.importedWorkouts, labs: backup.labResults)
        checkIns.restore(backup.checkIns)
        lifestyle.restore(backup.lifestyleEvents)
        workoutReviews.restore(backup.workoutReviews)
        planHistory.restore(backup.planSnapshots)
        strengthRoutines.restore(backup.strengthRoutines)
        if let goalProfile = backup.goalProfile { GoalStore.shared.restore(goalProfile) }
        if let injuryRecords = backup.injuryRecords { InjuryStore.shared.restore(injuryRecords) }
        if let dailyTwinStates = backup.dailyTwinStates { TwinStateStore.shared.restore(dailyTwinStates) }
        if let temperatureDeviationLogs = backup.temperatureDeviationLogs { TemperatureDeviationStore.shared.restore(temperatureDeviationLogs) }
        if let travelEpisodes = backup.travelEpisodes { travel.restore(travelEpisodes) }
        if let values = backup.workoutEnrichments { workoutEnrichments.restore(values) }
        // backup.health is intentionally not restored: HealthKit itself stays the
        // on-device source of truth, this field only ever flows outward.
    }

    static func configureAutomaticBackup(folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: folderBookmarkKey)
        defaults.set(folder.lastPathComponent, forKey: folderNameKey)
        defaults.removeObject(forKey: lastSuccessKey)
    }

    static func disableAutomaticBackup() {
        defaults.removeObject(forKey: folderBookmarkKey)
        defaults.removeObject(forKey: folderNameKey)
        defaults.removeObject(forKey: lastSuccessKey)
    }

    @discardableResult
    static func writeAutomaticBackupIfNeeded(
        imports: ImportStore, checkIns: DailyCheckInStore,
        lifestyle: LifestyleFactorStore, workoutReviews: WorkoutReviewStore,
        planHistory: PlanHistoryStore, strengthRoutines: StrengthRoutineStore,
        health: HealthStore, travel: TravelEpisodeStore,
        workoutEnrichments: WorkoutEnrichmentStore,
        force: Bool = false, now: Date = Date()
    ) throws -> Bool {
        guard automaticBackupEnabled else { return false }
        if !force, let last = automaticLastSuccess, Calendar.current.isDate(last, inSameDayAs: now) {
            return false
        }
        guard let folder = try automaticFolderURL() else { throw EterBackupError.automaticFolderUnavailable }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let backup = make(
            imports: imports, checkIns: checkIns, lifestyle: lifestyle,
            workoutReviews: workoutReviews, planHistory: planHistory,
            strengthRoutines: strengthRoutines, health: health, travel: travel,
            workoutEnrichments: workoutEnrichments
        )
        let destination = folder.appendingPathComponent(automaticFilename, isDirectory: false)
        try EterBackupCodec.encode(backup).write(to: destination, options: .atomic)
        defaults.set(now, forKey: lastSuccessKey)
        return true
    }

    private static func automaticFolderURL() throws -> URL? {
        guard let bookmark = defaults.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            let refreshed = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(refreshed, forKey: folderBookmarkKey)
        }
        return url
    }
}
