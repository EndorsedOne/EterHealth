import Foundation
import PDFKit
import Vision
import UIKit

struct ImportedWorkout: Codable, Identifiable, Sendable {
    var id: String { "\(title)|\(start.timeIntervalSince1970)" }
    let title: String
    let start: Date
    let end: Date
    let exercises: [ImportedExercise]
    // Weighted, not a raw set count: a synergist muscle (biceps on a row,
    // triceps on a bench press) gets half credit, not the same credit as
    // the muscle the exercise actually targets — see MuscleMap.involvement.
    // Kept for Codable/backward compatibility and as a last-resort
    // fallback only — every real consumer should read effectiveMuscleSets
    // below instead, never this field directly.
    let muscleSets: [String: Double]

    // The single canonical source for "how much did this session actually
    // work each muscle" — recomputed from exercises/setDetails using
    // whatever MuscleMap's weighting and the warm-up filter currently say,
    // never the stored muscleSets above. That field is frozen at whatever
    // logic existed when the session was saved; a session logged before a
    // refinement (the secondary-mover discount, warm-up filtering) kept
    // its old numbers forever otherwise — exactly what let the radar show
    // corrected figures while the fatigue model driving the actual plan
    // (TwinEngine.calculateMuscles) kept reading pre-discount, warm-up-
    // inclusive ones for the same session. One canonical property means
    // every future refinement applies to a workout's whole history at
    // once, and every consumer — radar, fatigue, leg-involvement checks —
    // agrees with the others by construction instead of by convention.
    var effectiveMuscleSets: [String: Double] {
        var result: [String: Double] = [:]
        for exercise in exercises {
            // Effort-weighted, not a flat set count: a set logged far from
            // failure (real RPE/RIR data, when present) contributes less
            // stimulus than one taken close to it — see
            // StrengthProgressEngine.effortWeight.
            let workingCount = exercise.setDetails.map { StrengthProgressEngine.effectiveSetCount($0) } ?? Double(exercise.sets)
            for (muscle, weight) in MuscleMap.involvement(for: exercise.name) {
                result[muscle, default: 0] += workingCount * weight
            }
        }
        return result
    }
}

struct ImportedExercise: Codable, Sendable {
    let name: String
    let sets: Int
    let volume: Double
    let totalReps: Int?
    let averageWeight: Double?
    let setDetails: [ImportedSet]?
}

struct ImportedSet: Codable, Sendable {
    var weight: Double
    var reps: Int
    var type: String
    var rpe: Double?
    // PR5: Hevy exporta `duration_seconds` para los ejercicios que se miden
    // en tiempo (trineo, wall balls, remo, ski…), y el parser lo ignoraba.
    // Opcional y sin valor por defecto en el decode: la mayoría de series son
    // de peso × reps y no tienen duración, y los JSON ya guardados tampoco
    // traen el campo. nil significa "no medido", nunca cero.
    var durationSeconds: Double?
}

struct LabResult: Codable, Identifiable, Sendable {
    var id: String { "\(date.timeIntervalSince1970)|\(name)" }
    let date: Date
    let name: String
    let value: Double
    let unit: String
    let low: Double?
    let high: Double?
    let previous: Double?

    var status: String {
        if let low, value < low { return "Bajo" }
        if let high, value > high { return "Alto" }
        return "En rango"
    }
}

@MainActor
final class ImportStore: ObservableObject {
    @Published private(set) var workouts: [ImportedWorkout] = []
    @Published private(set) var labs: [LabResult] = []
    @Published var message: String?
    @Published private(set) var isImporting = false

    // Production behavior is unchanged: init() always loads and every
    // mutation persists. EngineTests uses persistToDisk: false for
    // scenarios that need real control over exactly which workouts exist —
    // the default ImportStore() otherwise reads whatever this machine's
    // real Hevy import history happens to be, which is fine for tests that
    // only add one workout on top of it, but was silently deciding the
    // outcome of a few multi-day weekAhead tests that need a genuinely
    // empty or fully-controlled history to mean anything.
    private let persistsToDisk: Bool
    init() { persistsToDisk = true; load() }
    init(persistToDisk: Bool) { persistsToDisk = persistToDisk }

    func importFiles(_ urls: [URL]) {
        guard !isImporting else { return }
        isImporting = true
        message = nil
        Task {
            defer { isImporting = false }
            let parsed = await Task.detached(priority: .userInitiated) {
                var workouts: [ImportedWorkout] = []
                var labs: [LabResult] = []
                var errors: [String] = []
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        switch url.pathExtension.lowercased() {
                        case "csv": workouts.append(contentsOf: try Self.parseHevyCSV(url))
                        case "pdf": labs.append(contentsOf: try Self.parseLabPDF(url))
                        default: errors.append("Formato no compatible: \(url.lastPathComponent)")
                        }
                    } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                return (workouts, labs, errors)
            }.value

            let existingWorkouts = Set(workouts.map(\.id))
            let newWorkouts = parsed.0.filter { !existingWorkouts.contains($0.id) }
            let enrichedWorkouts = parsed.0.filter { existingWorkouts.contains($0.id) }.count
            // Replace workouts present in the CSV as well as adding new ones. This
            // lets a re-import enrich older saved sessions with reps and weights.
            let parsedWorkoutIDs = Set(parsed.0.map(\.id))
            workouts.removeAll { parsedWorkoutIDs.contains($0.id) }
            workouts.append(contentsOf: parsed.0)
            workouts.sort { $0.start > $1.start }
            let existingLabs = Set(labs.map(\.id))
            let newLabs = parsed.1.filter { !existingLabs.contains($0.id) }
            let updatedLabs = parsed.1.count - newLabs.count
            let parsedIDs = Set(parsed.1.map(\.id))
            labs.removeAll { parsedIDs.contains($0.id) }
            labs.append(contentsOf: parsed.1)
            labs.sort { $0.date > $1.date }
            save()
            if parsed.2.isEmpty {
                message = "Importación terminada: \(newWorkouts.count) entrenamientos nuevos, \(enrichedWorkouts) enriquecidos, \(newLabs.count) resultados clínicos nuevos y \(updatedLabs) actualizados. Totales: \(workouts.count) entrenamientos y \(labs.count) resultados clínicos."
            } else {
                message = "Importados \(newWorkouts.count) entrenamientos y \(newLabs.count) resultados nuevos. Totales: \(workouts.count) y \(labs.count). Problemas: \(parsed.2.joined(separator: "; "))"
            }
        }
    }

    var latestLabs: [LabResult] { Array(labs.sorted { $0.date > $1.date }.prefix(8)) }
    var workoutCount: Int { workouts.count }
    var labCount: Int { labs.count }

    func addStrengthWorkout(title: String, start: Date, end: Date, exercises: [ImportedExercise]) {
        var muscles: [String: Double] = [:]
        for exercise in exercises {
            for (muscle, weight) in MuscleMap.involvement(for: exercise.name) { muscles[muscle, default: 0] += Double(exercise.sets) * weight }
        }
        let workout = ImportedWorkout(title: title, start: start, end: end, exercises: exercises, muscleSets: muscles)
        workouts.removeAll { $0.id == workout.id }
        workouts.append(workout)
        workouts.sort { $0.start > $1.start }
        save()
    }

    func deleteStrengthWorkout(near date: Date, tolerance: TimeInterval = 10 * 60) {
        guard let match = workouts.min(by: { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }),
              abs(match.start.timeIntervalSince(date)) <= tolerance else { return }
        workouts.removeAll { $0.id == match.id }
        save()
    }

    func deleteWorkout(id: String) {
        workouts.removeAll { $0.id == id }
        save()
    }

    /// A strength session created in Éter is stored here with its sets and also in
    /// HealthKit with heart rate/calories. Treat both records as one session.
    func isHealthKitMirror(_ workout: HealthWorkout, startTolerance: TimeInterval = 3 * 60,
                           durationTolerance: TimeInterval = 8 * 60) -> Bool {
        guard workout.activity == "Fuerza" || workout.activity == "Fuerza funcional" else { return false }
        return workouts.contains { imported in
            let importedDuration = imported.end.timeIntervalSince(imported.start)
            let healthDuration = workout.durationMinutes * 60
            return abs(imported.start.timeIntervalSince(workout.date)) <= startTolerance &&
                   abs(importedDuration - healthDuration) <= durationTolerance
        }
    }

    func restore(workouts restoredWorkouts: [ImportedWorkout], labs restoredLabs: [LabResult]) {
        let workoutIDs = Set(restoredWorkouts.map(\.id)); workouts.removeAll { workoutIDs.contains($0.id) }; workouts.append(contentsOf: restoredWorkouts)
        let labIDs = Set(restoredLabs.map(\.id)); labs.removeAll { labIDs.contains($0.id) }; labs.append(contentsOf: restoredLabs)
        workouts.sort { $0.start > $1.start }; labs.sort { $0.date > $1.date }; save()
    }

    // Deliberately recomputed from exercises/setDetails here rather than
    // reading workout.muscleSets — that field is computed once and
    // persisted at import/save time, so any session logged before a
    // refinement to warm-up filtering or muscle-involvement weighting
    // keeps its old, stale numbers forever; nothing ever revisits it. A
    // real session logged the day the secondary-mover discount shipped
    // still showed its pre-discount, full-credit "23 sets" of bíceps in
    // the stored field — recomputing live is what makes every future
    // refinement apply to a workout's whole history, not just new imports.
    func muscleDistribution(from start: Date, to end: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        for workout in workouts where workout.start >= start && workout.start < end {
            for (muscle, sets) in workout.effectiveMuscleSets { result[Self.bucket(muscle), default: 0] += sets }
        }
        return result
    }

    func weeklyVolume(weeks: Int = 12) -> [TrendPoint] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .weekOfYear, value: -weeks, to: Date())!
        var totals: [Date: Double] = [:]
        for workout in workouts where workout.start >= start {
            let week = calendar.dateInterval(of: .weekOfYear, for: workout.start)?.start ?? workout.start
            totals[week, default: 0] += workout.exercises.reduce(0) { $0 + $1.volume }
        }
        return totals.map { TrendPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    func labSeries() -> [(String, [TrendPoint], String, Double?, Double?)] {
        Dictionary(grouping: labs, by: \.name).map { name, items in
            let sorted = items.sorted { $0.date < $1.date }
            let latest = sorted.last
            return (name, sorted.map { TrendPoint(date: $0.date, value: $0.value) }, latest?.unit ?? "", latest?.low, latest?.high)
        }.sorted { $0.0 < $1.0 }
    }

    private static func bucket(_ muscle: String) -> String {
        switch muscle {
        case "Cuádriceps", "Glúteos", "Isquios", "Gemelos": return "Piernas"
        case "Bíceps", "Tríceps": return "Brazos"
        default: return muscle
        }
    }

    nonisolated private static func parseHevyCSV(_ url: URL) throws -> [ImportedWorkout] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = CSV.parse(text)
        guard let header = rows.first else { return [] }
        // Some CSV exports contain repeated or empty header names. Keep the first
        // occurrence instead of trapping on a duplicate dictionary key.
        let index = header.enumerated().reduce(into: [String: Int]()) { result, item in
            let key = item.element.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{feff}", with: "")
            if result[key] == nil { result[key] = item.offset }
        }
        func field(_ row: [String], _ name: String) -> String {
            guard let i = index[name], i < row.count else { return "" }; return row[i]
        }
        let formatters: [DateFormatter] = ["d MMM yyyy, HH:mm", "dd MMM yyyy, HH:mm", "d MMM yyyy, H:mm"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            return formatter
        }
        func date(_ value: String) -> Date? { formatters.lazy.compactMap { $0.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) }.first }

        struct ExerciseAccumulator { var sets = 0; var volume = 0.0; var reps = 0; var details: [ImportedSet] = [] }
        struct WorkoutAccumulator {
            let title: String
            let start: Date
            let end: Date
            var exercises: [String: ExerciseAccumulator] = [:]
            var exerciseOrder: [String] = []
        }
        var grouped: [String: WorkoutAccumulator] = [:]
        for row in rows.dropFirst() {
            guard let start = date(field(row, "start_time")),
                  let end = date(field(row, "end_time")) else { continue }
            let title = field(row, "title")
            let key = "\(title)|\(start.timeIntervalSince1970)"
            let exercise = field(row, "exercise_title")
            let weight = Double(field(row, "weight_kg")) ?? 0
            let reps = Double(field(row, "reps")) ?? 0
            let setType = field(row, "set_type").isEmpty ? "normal" : field(row, "set_type")
            let rpe = Double(field(row, "rpe"))
            var workout = grouped[key] ?? WorkoutAccumulator(title: title, start: start, end: end)
            if workout.exercises[exercise] == nil { workout.exerciseOrder.append(exercise) }
            var item = workout.exercises[exercise] ?? ExerciseAccumulator()
            item.sets += 1
            item.volume += weight * reps
            item.reps += Int(reps.rounded())
            item.details.append(ImportedSet(weight: weight, reps: Int(reps.rounded()), type: setType, rpe: rpe,
                                            durationSeconds: Double(field(row, "duration_seconds"))))
            workout.exercises[exercise] = item
            grouped[key] = workout
        }

        let imported = grouped.values.map { item -> ImportedWorkout in
            let exercises = item.exerciseOrder.compactMap { name -> ImportedExercise? in
                guard let value = item.exercises[name] else { return nil }
                // Counted sets/volume/reps/averageWeight reflect only the
                // working sets — a warm-up ramp (tagged, or inferred from
                // its own ascending weight) shouldn't inflate the set count
                // muscle-fatigue tracking uses, or drag the suggested
                // working weight toward the warm-up average. setDetails
                // itself stays the full raw list, so nothing is lost.
                let working = StrengthProgressEngine.workingSets(value.details)
                let workingReps = working.reduce(0) { $0 + $1.reps }
                let workingVolume = working.reduce(0.0) { $0 + $1.weight * Double($1.reps) }
                return ImportedExercise(
                    name: name,
                    sets: working.count,
                    volume: workingVolume,
                    totalReps: workingReps,
                    averageWeight: workingReps > 0 && workingVolume > 0 ? workingVolume / Double(workingReps) : nil,
                    setDetails: value.details
                )
            }
            var muscles: [String: Double] = [:]
            for exercise in exercises {
                for (muscle, weight) in MuscleMap.involvement(for: exercise.name) { muscles[muscle, default: 0] += Double(exercise.sets) * weight }
            }
            return ImportedWorkout(title: item.title, start: item.start, end: item.end, exercises: exercises, muscleSets: muscles)
        }
        return imported
    }

    // Internal (not private) seam so EterHealthTests can drive the real regex
    // parser against real lab PDFs via @testable import, without widening the
    // parser's own access level beyond what production code needs.
    nonisolated static func parseLabPDFForTesting(_ url: URL) throws -> [LabResult] { try parseLabPDF(url) }

    // Testing-only: exposes the exact assembled text (native + OCR) the regex
    // table matches against, so a broken pattern can be fixed against the
    // real text instead of a guess at it.
    nonisolated static func rawParsedTextForTesting(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        if document.isLocked && !document.unlock(withPassword: "") { throw ImportError.lockedPDF }
        let nativeText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        var text = nativeText
        let visualText = try recognizeText(in: document)
        if !visualText.isEmpty { text += "\n" + visualText }
        return text
    }

    nonisolated private static func parseLabPDF(_ url: URL) throws -> [LabResult] {
        guard let document = PDFDocument(url: url) else { return [] }
        if document.isLocked && !document.unlock(withPassword: "") { throw ImportError.lockedPDF }
        let nativeText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        var text = nativeText
        // Many laboratory PDFs expose a long but scrambled text layer. Append a
        // visual OCR pass so table rows can still be reconstructed correctly.
        let visualText = try recognizeText(in: document)
        if !visualText.isEmpty { text += "\n" + visualText }
        let date = firstDate(in: text) ?? dateFromFilename(url) ?? Date()
        return extractLabResults(from: text, nativeText: nativeText, date: date)
    }

    // Internal (not private) seam so EterHealthTests can drive the regex
    // table directly against synthetic text — no PDF, no OCR, no fixture
    // files on disk — which is what actually lets a new pattern's exact
    // match/no-match behavior (and its handling of the lab's own inline
    // reference range) be covered by a fast unit test instead of only the
    // slow, machine-local real-PDF suite in LabImportRealPDFTests.
    nonisolated static func extractLabResultsForTesting(from text: String, nativeText: String? = nil, date: Date) -> [LabResult] {
        extractLabResults(from: text, nativeText: nativeText ?? text, date: date)
    }

    nonisolated private static func extractLabResults(from text: String, nativeText: String, date: Date) -> [LabResult] {
        let patterns: [(String, String, Double?, Double?, String)] = [
            ("Hemoglobina", "g/dL", 13.0, 17.5, #"(?m)^\s*HEMOGLOBINA(?:\s+\(HGB\))?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Hematocrito", "%", 40.0, 52.0, #"(?m)^\s*HEMATOCRITO(?:\s+\(HCT\))?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Glucosa", "mg/dL", 75, 100, #"(?m)^\s*GLUCOSA\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Hemoglobina glicada A1c", "%", 4.5, 5.6, #"(?m)^\s*HEMOGLOBINA\s+GLICADA\s+A1c\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Ácido úrico", "mg/dL", 2, 7, #"(?m)^\s*[ÁA]CIDO\s+[ÚU]RICO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Colesterol total", "mg/dL", nil, 200, #"(?m)^\s*COLESTEROL\s+TOTAL\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Colesterol HDL", "mg/dL", 40, nil, #"(?m)^\s*-?\s*COLESTEROL\s+HDL\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Colesterol LDL", "mg/dL", nil, 115, #"(?m)^\s*-?\s*(?:COLESTEROL\s+LDL|LDL\s+COLESTEROL)\s*\*?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Triglicéridos", "mg/dL", nil, 150, #"(?m)^\s*TRIGLIC[ÉE]RIDOS\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Cortisol matutino", "mcg/dL", 5, 25, #"(?m)^\s*CORTISOL.*?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Sodio", "mEq/L", 135, 150, #"(?m)^\s*SODIO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Potasio", "mEq/L", 3.5, 5.5, #"(?m)^\s*POTASIO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Calcio", "mg/dL", 8.5, 10.5, #"(?m)^\s*CALCIO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Fósforo", "mg/dL", 2.5, 4.5, #"(?m)^\s*F[ÓO]SFORO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Hierro", "mcg/dL", 60, 170, #"(?m)^\s*HIERRO\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Transferrina", "mg/dL", 200, 360, #"(?m)^\s*TRANSFERRINA\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Saturación transferrina", "%", 20, 45, #"(?m)^\s*[ÍI]NDICE\s+SATUR\.?\s+TRANSFERRINA\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Ferritina", "ng/mL", 30, 400, #"(?m)^\s*FERRITINA\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Folato (vitamina B9)", "ng/mL", 3.89, 20, #"(?m)^\s*FOLATO(?:\s+\(VITAMINA\s+B9\))?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Vitamina B12", "pg/mL", 191, 943, #"(?m)^\s*VITAMINA\s+B12\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Vitamina D", "ng/mL", 20, 100, #"(?m)^\s*VITAMINA\s+D(?:\s+TOTAL)?(?:\s+\(25-HIDROXI\))?\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("TSH", "mcU/mL", 0.30, 4.70, #"(?m)^\s*TIROTROPINA\s+\(TSH\)\s+([0-9]+(?:[,.][0-9]+)?)"#),
            ("Testosterona", "ng/mL", 2.49, 8.36, #"(?m)^\s*TESTOSTERONA(?:\s+\d{2}/\d{2}/\d{4})?\s+(?:TESTOSTERONA\s+LIBRE\s+)?([0-9]+(?:[,.][0-9]+)?)\s+ng/mL"#),
            ("Testosterona libre", "pg/mL", 3.6, 25.7, #"(?is)TESTOSTERONA\s+LIBRE(?:(?!MARCADORES\s+TUMORALES).){0,1400}?\b([0-9]+(?:[,.][0-9]+)?)\s+pg/mL"#),
            ("PSA total", "ng/mL", 0, 4, #"(?m)^\s*P\.?S\.?A\.?\s+TOTAL\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Hematíes", "mill/µL", 4, 6, #"(?m)^\s*HEMAT[IÍ]ES\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Plaquetas", "mil/µL", 135, 450, #"(?m)^\s*PLAQUETAS(?:\s*\(PLT\))?\s*\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Leucocitos", "mil/µL", 4, 11, #"(?m)^\s*LEUCOCITOS\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Neutrófilos", "mil/µL", 2, 5, #"(?m)^\s*NEUTR[ÓO]FILOS\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)\s+(?:X\s*)?MIL"#)
            ,("Linfocitos", "mil/µL", 1.3, 2.9, #"(?m)^\s*LINFOCITOS\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)\s+(?:X\s*)?MIL"#)
            ,("Creatinina", "mg/dL", 0.5, 1.33, #"(?m)^\s*CREATININA\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Filtrado glomerular", "mL/min/1.73m²", 60, nil, #"(?m)^\s*FILTRADO\s+GLOMERULAR(?:\s+\(ESTIMADO\))?\s+>?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Colesterol VLDL", "mg/dL", 15, 35, #"(?m)^\s*COLESTEROL\s+VLDL\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Riesgo aterogénico", "índice", 0, 5, #"(?m)^\s*RIESGO\s+ATEROG[ÉE]NICO\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("GOT", "U/L", 7, 47, #"(?m)^\s*GOT\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("GPT", "U/L", 7, 47, #"(?m)^\s*GPT\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("GGT", "U/L", 0, 50, #"(?m)^\s*GGT\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Peso", "kg", nil, nil, #"(?im)\bPESO\s*:?\s*([0-9]+(?:[,.][0-9]+)?)\s*KG"#)
            ,("IMC", "kg/m²", 18.5, 24.9, #"(?im)\bI\.?M\.?C\.?\s*:?[^0-9]{0,20}([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Presión sistólica", "mmHg", nil, 140, #"(?im)TENSI[ÓO]N\s+ARTERIAL\s*-?\s*M[ÁA]XIMA\s*:?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Presión diastólica", "mmHg", nil, 90, #"(?im)TENSI[ÓO]N\s+ARTERIAL.*?M[ÍI]NIMA\s*:?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Pulso", "ppm", 50, 100, #"(?im)PULSACIONES\s*:?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            // Added so future analíticas capture these automatically — previously
            // present in some lab PDFs but never matched by any pattern here
            // (found by hand once while building BiologicalAgeEngine's PhenoAge
            // estimate; see ImportStore.supplementalLabs for that one-time backfill).
            ,("Volumen Corpuscular Medio (MCV)", "fL", 80, 99, #"(?m)^\s*VOLUMEN\s+CORPUSCULAR\s+MEDIO(?:\s*\(V\.?C\.?M\.?\))?\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Amplitud distribución eritrocitaria (RDW)", "%", 11.5, 15.0, #"(?m)^\s*(?:AMPLITUD\s+(?:DE\s+)?DISTRIBUCI[ÓO]N\s+ERITROCITARIA|[ÁA]REA\s+DE\s+DISTRIBUCI[ÓO]N\s+ERITROCITARIA)\s*(?:\(R\.?D\.?W\.?\))?\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Hemoglobina Corpuscular Media (MCH)", "pg", 27, 32, #"(?m)^\s*HEMOGLOBINA\s+CORPUSCULAR\s+MEDIA(?:\s*\(H\.?C\.?M\.?\))?\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            // Word order and punctuation for MCHC/Linfocitos% vary by lab: IMQ's OCR'd
            // text puts MEDIA after CORPUSCULAR ("Concentración Hemoglobina
            // Corpuscular Me[dia]" — Vision OCR actually truncates it to "Me",
            // confirmed against the real page render, hence a generic trailing
            // word instead of matching "MEDIA" literally) and Axpe abbreviates
            // with no spaces ("Conc.hemogl.corpuscular media"); Linfocitos% has
            // "%" both right after the label name and again as the trailing
            // unit. Made tolerant of all of this after checking against the
            // actual OCR'd text (see LabImportRealPDFTests).
            ,("Conc. Hemoglobina Corpuscular (MCHC)", "g/dL", 32, 36, #"(?m)^\s*CONC(?:ENTRACI[ÓO]N)?\.?\s*(?:MEDIA\s+)?(?:DE\s+)?HEMOGL(?:OBINA)?\.?\s*CORPUSCULAR(?:\s+[A-ZÁÉÍÓÚa-záéíóú]{1,10}\.?)?(?:\s*\(?\s*C\.?H\.?C\.?M\.?\)?)?\s*[:\*]?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Urea", "mg/dL", 10, 50, #"(?m)^\s*UREA\s+\*?\s*([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Linfocitos %", "%", nil, nil, #"(?m)^\s*LINFOCITOS\s*%?\s*\*?\s*[:]?\s*([0-9]+(?:[,.][0-9]+)?)\s*%"#)
            // Added after comparing against Bevel's biomarker list — GOT/GPT/GGT/
            // Creatinina/Filtrado glomerular were already covered above; these six
            // weren't. ApoB/Lp(a)/no-HDL extend WellnessRecommendationEngine's
            // existing cardiovascular tips with the markers modern guidance
            // increasingly treats as better risk predictors than LDL alone.
            ,("Apolipoproteína B", "mg/dL", nil, 90, #"(?m)^\s*(?:APOLIPOPROTE[ÍI]NA\s+B|APO\s*-?\s*B)\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Lipoproteína (a)", "mg/dL", nil, 30, #"(?m)^\s*(?:LIPOPROTE[ÍI]NA\s*\(?\s*A\s*\)?|LP\s*\(?\s*A\s*\)?)\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Colesterol no-HDL", "mg/dL", nil, 130, #"(?m)^\s*-?\s*COLESTEROL\s+NO\s*-?\s*HDL\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Magnesio", "mg/dL", 1.7, 2.2, #"(?m)^\s*MAGNESIO\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Proteína C reactiva", "mg/L", nil, 5, #"(?m)^\s*PROTE[ÍI]NA\s+C\s+REACTIVA(?:\s+ULTRASENSIBLE)?\s*(?:\(?\s*PCR\s*\)?)?\s+([0-9]+(?:[,.][0-9]+)?)"#)
            ,("Homocisteína", "µmol/L", 5, 15, #"(?m)^\s*HOMOCISTE[ÍI]NA\s+([0-9]+(?:[,.][0-9]+)?)"#)
        ]
        var found: [LabResult] = []
        for (name, unit, defaultLow, defaultHigh, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func number(_ group: Int) -> Double? {
                guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
                return Double(text[range].replacingOccurrences(of: ",", with: "."))
            }
            guard let value = number(1) else { continue }
            var low = defaultLow
            var high = defaultHigh
            if let fullRange = Range(match.range(at: 0), in: text) {
                let lineEnd = text[fullRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
                let line = String(text[fullRange.lowerBound..<lineEnd])
                if let rangeRegex = try? NSRegularExpression(pattern: #"[\[\(]\s*([0-9]+(?:[,.][0-9]+)?)\s*-\s*([0-9]+(?:[,.][0-9]+)?)\s*[\]\)]"#),
                   let rangeMatch = rangeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let lowRange = Range(rangeMatch.range(at: 1), in: line),
                   let highRange = Range(rangeMatch.range(at: 2), in: line) {
                    low = Double(line[lowRange].replacingOccurrences(of: ",", with: "."))
                    high = Double(line[highRange].replacingOccurrences(of: ",", with: "."))
                }
            }
            found.append(LabResult(date: date, name: name, value: value, unit: unit, low: low, high: high, previous: nil))
        }
        // Axpe sometimes exposes the hormone table out of visual order. Parse its
        // native text separately so OCR cannot attach historical values to the wrong label.
        let hormonePatterns: [(String, String, Double, Double, String)] = [
            ("Testosterona", "ng/mL", 2.49, 8.36, #"(?m)^\s*TESTOSTERONA(?:\s+\d{2}/\d{2}/\d{4})?\s+(?:TESTOSTERONA\s+LIBRE\s+)?([0-9]+(?:[,.][0-9]+)?)\s+ng/mL"#),
            ("Testosterona libre", "pg/mL", 3.6, 25.7, #"(?is)TESTOSTERONA\s+LIBRE(?:(?!MARCADORES\s+TUMORALES).){0,1400}?\b([0-9]+(?:[,.][0-9]+)?)\s+pg/mL"#)
        ]
        for (name, unit, low, high, pattern) in hormonePatterns {
            guard let value = firstNumber(pattern: pattern, in: nativeText) else { continue }
            found.removeAll { $0.name == name }
            found.append(LabResult(date: date, name: name, value: value, unit: unit, low: low, high: high, previous: nil))
        }
        return found
    }

    nonisolated private static func firstNumber(pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    nonisolated private static func recognizeText(in document: PDFDocument) throws -> String {
        var lines: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let image = page.thumbnail(of: CGSize(width: 1800, height: 2500), for: .mediaBox)
            guard let cgImage = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es-ES", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let observations = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (text, observation.boundingBox)
            }.sorted {
                abs($0.1.midY - $1.1.midY) > 0.008 ? $0.1.midY > $1.1.midY : $0.1.minX < $1.1.minX
            }
            var rows: [[(String, CGRect)]] = []
            for item in observations {
                if let index = rows.indices.last, let reference = rows[index].first, abs(reference.1.midY - item.1.midY) < 0.012 {
                    rows[index].append(item)
                } else {
                    rows.append([item])
                }
            }
            lines.append(contentsOf: rows.map { row in
                row.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ")
            })
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func firstDate(in text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)(?:Fecha\s+(?:de\s+)?obtenci[oó]n(?:\s+de\s+muestra)?|Fecha\s+muestra|Fecha\s+(?:de\s+)?extracci[oó]n|Fecha\s+recon\.?)\s*:?\s*(\d{2}[/-]\d{2}[/-]\d{4})"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_ES_POSIX"); formatter.dateFormat = "dd/MM/yyyy"
        return formatter.date(from: String(text[range]).replacingOccurrences(of: "-", with: "/"))
    }

    nonisolated private static func dateFromFilename(_ url: URL) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(20\d{2})(\d{2})(\d{2})"#),
              let match = regex.firstMatch(in: url.lastPathComponent, range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)),
              let range = Range(match.range(at: 0), in: url.lastPathComponent) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(url.lastPathComponent[range]))
    }

    private var storageURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("eter-imports.json") }
    private struct Storage: Codable { let workouts: [ImportedWorkout]; let labs: [LabResult] }
    private func save() {
        guard persistsToDisk else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Storage(workouts: workouts, labs: labs)).write(to: storageURL, options: .atomic)
    }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL), let value = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        workouts = value.workouts; labs = value.labs
    }
}

// Not private: EterHealthTests references this case via @testable import to
// assert that a password-protected PDF throws rather than silently dropping data.
enum ImportError: LocalizedError, Equatable {
    case lockedPDF
    var errorDescription: String? { "El PDF está protegido con contraseña. Usa una copia sin protección." }
}

enum MuscleMap {
    static func groups(for raw: String) -> [String] {
        let name = raw.lowercased()
        if name.contains("squat") || name.contains("leg press") || name.contains("leg extension") || name.contains("lunge") || name.contains("bulgarian") || name.contains("wall ball") || name.contains("goblet") { return ["Cuádriceps", "Glúteos"] }
        if name.contains("deadlift") || name.contains("leg curl") { return ["Isquios", "Glúteos", "Espalda"] }
        if name.contains("hip thrust") || name.contains("glute bridge") || name.contains("hip abduction") { return ["Glúteos"] }
        if name.contains("calf") { return ["Gemelos"] }
        if name.contains("bench") || name.contains("chest press") || name.contains("chest fly") || name.contains("cable fly") || name.contains("push up") || name.contains("dip") { return ["Pecho", "Tríceps"] }
        if name.contains("shoulder") || name.contains("military") || name.contains("lateral raise") || name.contains("landmine press") { return ["Hombros", "Tríceps"] }
        if name.contains("row") || name.contains("pulldown") || name.contains("pull up") || name.contains("chin up") || name.contains("pullover") || name.contains("face pull") { return ["Espalda", "Bíceps"] }
        if name.contains("curl") { return ["Bíceps"] }
        if name.contains("triceps") || name.contains("skullcrusher") { return ["Tríceps"] }
        if name.contains("crunch") || name.contains("plank") || name.contains("knee raise") || name.contains("leg raise") || name.contains("dead bug") || name.contains("pallof") || name.contains("dragon") || name.contains("bird dog") { return ["Core"] }
        return ["Cuerpo completo"]
    }

    // Weighted involvement for set-counting toward hypertrophy volume —
    // deliberately separate from groups(for:) above (which stays a plain
    // membership list for every other caller: injury restrictions,
    // exercise-alternative matching, display). Full credit (1.0) for the
    // muscle a movement actually targets; half credit (0.5, the standard
    // treatment for "indirect" sets in hypertrophy volume-counting) for a
    // real but secondary/synergist mover. Giving every synergist full
    // credit — the previous behavior — is what let two ordinary sessions
    // read as "219% brazos": nearly every push or pull exercise touches
    // triceps or biceps as a synergist, and counting each of those the
    // same as a dedicated curl or extension set overstates real arm
    // volume substantially.
    static func involvement(for raw: String) -> [String: Double] {
        let name = raw.lowercased()
        if name.contains("squat") || name.contains("leg press") || name.contains("leg extension") || name.contains("lunge") || name.contains("bulgarian") || name.contains("wall ball") || name.contains("goblet") {
            return ["Cuádriceps": 1.0, "Glúteos": 0.6]
        }
        if name.contains("deadlift") || name.contains("leg curl") {
            return ["Isquios": 1.0, "Glúteos": 0.75, "Espalda": 0.5]
        }
        if name.contains("hip thrust") || name.contains("glute bridge") || name.contains("hip abduction") {
            return ["Glúteos": 1.0]
        }
        if name.contains("calf") {
            return ["Gemelos": 1.0]
        }
        if name.contains("bench") || name.contains("chest press") || name.contains("chest fly") || name.contains("cable fly") || name.contains("push up") || name.contains("dip") {
            return ["Pecho": 1.0, "Tríceps": 0.5]
        }
        // A lateral raise is close to pure shoulder isolation — the elbow
        // barely moves, so triceps gets no real credit, unlike an actual
        // pressing movement.
        if name.contains("lateral raise") {
            return ["Hombros": 1.0]
        }
        if name.contains("shoulder") || name.contains("military") || name.contains("landmine press") {
            return ["Hombros": 1.0, "Tríceps": 0.5]
        }
        if name.contains("row") || name.contains("pulldown") || name.contains("pull up") || name.contains("chin up") || name.contains("pullover") || name.contains("face pull") {
            return ["Espalda": 1.0, "Bíceps": 0.5]
        }
        if name.contains("curl") {
            return ["Bíceps": 1.0]
        }
        if name.contains("triceps") || name.contains("skullcrusher") {
            return ["Tríceps": 1.0]
        }
        if name.contains("crunch") || name.contains("plank") || name.contains("knee raise") || name.contains("leg raise") || name.contains("dead bug") || name.contains("pallof") || name.contains("dragon") || name.contains("bird dog") {
            return ["Core": 1.0]
        }
        return ["Cuerpo completo": 1.0]
    }
}

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let row = parseLine(String(rawLine))
            return row.allSatisfy(\.isEmpty) ? nil : row
        }
    }

    private static func parseLine(_ line: String) -> [String] {
        var row: [String] = [], field = "", quoted = false
        let chars = Array(line); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else if quoted { quoted = false }
                else if field.isEmpty { quoted = true }
                else { field.append("\"") }
            } else if c == "," && !quoted { row.append(field); field = "" }
            else { field.append(c) }
            i += 1
        }
        row.append(field)
        return row
    }
}
