import XCTest
@testable import EterHealth

// Exercises ImportStore's real PDF parser against the actual lab reports on
// disk (iCloud Drive "Salud" folder) instead of synthetic text. This is how
// the hardcoded `supplementalLabs` seed was verified and then removed: every
// marker it used to stand in for must now come out of the regex parser on
// the real documents, and markers spanning several years' documents must
// group under one identical `name` so ClinicalHealthSectionView's evolution
// chart (Dictionary(grouping: labs, by: \.name) in ImportStore.labSeries())
// actually connects them into a single line instead of splitting into
// several one-point series.
//
// Skips itself (XCTSkip) if the Salud folder isn't present — e.g. CI, or any
// machine other than the one with this iCloud Drive — rather than failing.
@MainActor
final class LabImportRealPDFTests: XCTestCase {
    // Points at a plain /tmp copy, not the live iCloud Drive folder directly:
    // reading straight from "~/Library/Mobile Documents/com~apple~CloudDocs/…"
    // from inside the Simulator's test-runner process blocked indefinitely
    // (near-zero CPU, no progress after 10+ minutes) — consistent with a TCC
    // consent prompt for Files/iCloud access that nothing was there to click
    // in a headless run. A plain /tmp copy carries no such prompt.
    private var saludFolder: URL {
        URL(fileURLWithPath: "/tmp/eter-lab-pdfs")
    }

    private func requireSaludFolder() throws -> URL {
        let folder = saludFolder
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("Salud folder not present on this machine — skipping real-PDF import test.")
        }
        return folder
    }

    // Fast, single-file smoke test run first to confirm Vision OCR actually
    // completes inside the Simulator's test-runner process at all (and how
    // long one document takes) before committing to the full multi-file run.
    func testSmokeSingleFileParses() throws {
        let folder = try requireSaludFolder()
        let url = folder.appendingPathComponent("2026.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("File not present.") }
        let start = Date()
        let results = try ImportStore.parseLabPDFForTesting(url)
        print("SMOKE[2026.pdf]: \(results.count) markers in \(Date().timeIntervalSince(start))s")
        for r in results.sorted(by: { $0.name < $1.name }) { print("  \(r.name) = \(r.value) \(r.unit)") }
        XCTAssertFalse(results.isEmpty)
    }

    // 2019.pdf parsed far fewer markers (5) than every other year (13-29) in
    // the full suite — checking whether that's a genuinely thinner panel or a
    // gap in the regex table worth closing.
    func testDump2019PDFFullText() throws {
        let folder = try requireSaludFolder()
        let url = folder.appendingPathComponent("2019.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("File not present.") }
        let text = try ImportStore.rawParsedTextForTesting(url)
        print("=== 2019.pdf full text (\(text.count) chars) ===")
        print(text)
    }

    func testDumpRawTextAround2026PDFCorpuscularLines() throws {
        let folder = try requireSaludFolder()
        let url = folder.appendingPathComponent("2026.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("File not present.") }
        let text = try ImportStore.rawParsedTextForTesting(url)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let upper = line.uppercased()
            if upper.contains("CORPUSCULAR") || upper.contains("CONC") {
                print("LINE: \(line)")
            }
        }
    }

    func testAllLabPDFsParseWithoutCrashingAndReportPerFileCounts() throws {
        let folder = try requireSaludFolder()
        // Real lab reports only — excludes the water-fasting guide (not a lab
        // report), the password-protected duplicate of 2026.pdf (expected to
        // throw .lockedPDF, asserted separately below), and non-PDF files.
        let labPDFs = ["2019.pdf", "2023.pdf", "2024.pdf", "2024_2.pdf", "2025.pdf", "2025_2.pdf", "2026.pdf", "2026_2.pdf", "analitica cortisol.pdf"]
        var allResults: [LabResult] = []
        var perFile: [String: Int] = [:]
        for name in labPDFs {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let results = try ImportStore.parseLabPDFForTesting(url)
            perFile[name] = results.count
            allResults.append(contentsOf: results)
        }
        for (name, count) in perFile.sorted(by: { $0.key < $1.key }) {
            print("PARSE[\(name)]: \(count) markers")
        }
        XCTAssertFalse(allResults.isEmpty, "Expected at least some markers parsed across all real lab PDFs.")

        // The five markers that used to be hardcoded must now come from the
        // real parser, on the exact draws confirmed by hand against the PDFs.
        let byName = Dictionary(grouping: allResults, by: \.name)
        func value(_ name: String, on isoDate: String) -> Double? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = formatter.date(from: isoDate) else { return nil }
            return byName[name]?.first { Calendar.current.isDate($0.date, inSameDayAs: day) }?.value
        }
        XCTAssertEqual(value("Volumen Corpuscular Medio (MCV)", on: "2026-01-26"), 88.70, "MCV should now be parsed from 2026.pdf directly.")
        XCTAssertEqual(value("Amplitud distribución eritrocitaria (RDW)", on: "2026-01-26"), 12.20, "RDW should now be parsed from 2026.pdf directly.")
        XCTAssertEqual(value("Hemoglobina Corpuscular Media (MCH)", on: "2026-01-26"), 29.70, "MCH should now be parsed from 2026.pdf directly.")
        XCTAssertEqual(value("Conc. Hemoglobina Corpuscular (MCHC)", on: "2026-01-26"), 33.50, "MCHC should now be parsed from 2026.pdf directly — this is the word-order regex fix.")
        XCTAssertEqual(value("Urea", on: "2025-01-29"), 48, "Urea should be parsed from 2025_2.pdf (Axpe), not 2025.pdf (IMQ, which has no Urea line at all).")
        XCTAssertEqual(value("Linfocitos %", on: "2026-01-26"), 35.30, "Linfocitos % should now be parsed from 2026.pdf — this is the percent-sign-placement regex fix.")

        // Markers present in more than one year's document must share the
        // exact same `name` so ImportStore.labSeries() groups them into one
        // multi-point evolution series instead of several single-point ones.
        let multiYearNames = ["Volumen Corpuscular Medio (MCV)", "Amplitud distribución eritrocitaria (RDW)",
                               "Hemoglobina Corpuscular Media (MCH)", "Conc. Hemoglobina Corpuscular (MCHC)",
                               "Hemoglobina", "Glucosa", "Colesterol total", "Creatinina"]
        for name in multiYearNames {
            let distinctDays = Set((byName[name] ?? []).map { Calendar.current.startOfDay(for: $0.date) })
            print("SERIES[\(name)]: \(distinctDays.count) distinct dates")
        }
    }

    func testPasswordProtectedDuplicateThrowsLockedPDFRatherThanSilentlyDroppingData() throws {
        let folder = try requireSaludFolder()
        let url = folder.appendingPathComponent("MARTINEZ CAPILLA_ANGEL_16164803_20260126.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("File not present.") }
        XCTAssertThrowsError(try ImportStore.parseLabPDFForTesting(url)) { error in
            XCTAssertEqual(error as? ImportError, .lockedPDF)
        }
    }
}
