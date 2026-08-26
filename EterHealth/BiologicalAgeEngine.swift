import Foundation

/// An approximate PhenoAge (Levine ME et al., "An epigenetic biomarker of aging
/// for lifespan and healthspan", Aging (Albany NY) 2018;10(4):573-591) — NOT a
/// clinically validated biological age. Coefficients, canonical units, and the
/// age-indexed population defaults/uncertainty used when a marker isn't
/// available are verified against the CC0 reference implementation
/// ajsteele/bioage (config/models/phenoage.json, defaults.csv, uncertainty.csv)
/// rather than re-derived independently. This mirrors the equivalent feature
/// already shipped on the web dashboard (endorsed.one/salud-…), ported into
/// éter itself so it lives alongside the rest of your data.
/// One term of the Levine linear combination (`xb`): a marker's own value, the
/// model's published coefficient for it, and whether that value is really
/// yours or a population-average stand-in. Deliberately NOT expressed as "N
/// years" per marker — xb feeds a nonlinear Gompertz transform to reach an
/// age, so attributing a fixed number of years to any single term would
/// misstate how the formula actually works. What's honest to show is the
/// coefficient itself (how strongly the model weighs that input) next to your
/// own value for it.
struct BiomarkerContribution: Identifiable {
    var id: String { name }
    let name: String
    let value: Double
    let unit: String
    let coefficient: Double
    let isImputed: Bool
}

struct BiologicalAgeEstimate {
    let estimatedAge: Double
    let chronologicalAge: Int
    let delta: Double
    let uncertainty: Double
    let drawDate: Date
    let imputedMarkers: [String]
    let confidence: TrustLevel
    let contributions: [BiomarkerContribution]
}

enum BiologicalAgeEngine {
    struct DrawMarkers: Equatable {
        let date: Date
        let glucoseMgDl: Double
        let creatinineMgDl: Double
        let wbc: Double
        let lymphocytePct: Double
        let mcv: Double
        let rdw: Double
    }

    private struct AgeDefaults { let albumin: Double; let crp: Double; let alkalinePhosphatase: Double }

    // Only ages 40-45 are populated — the range that actually matters today —
    // rather than guessing values for the full lifespan. Extend this table
    // (from ajsteele/bioage's defaults.csv/uncertainty.csv) if this ever needs
    // to cover a wider age range.
    private static let defaultsByAge: [Int: AgeDefaults] = [
        40: AgeDefaults(albumin: 41.6245, crp: 0.3152, alkalinePhosphatase: 81.9148),
        41: AgeDefaults(albumin: 41.5841, crp: 0.3172, alkalinePhosphatase: 82.4268),
        42: AgeDefaults(albumin: 41.5428, crp: 0.3195, alkalinePhosphatase: 82.9672),
        43: AgeDefaults(albumin: 41.5000, crp: 0.3221, alkalinePhosphatase: 83.5427),
        44: AgeDefaults(albumin: 41.4557, crp: 0.3250, alkalinePhosphatase: 84.1559),
        45: AgeDefaults(albumin: 41.4100, crp: 0.3279, alkalinePhosphatase: 84.8015)
    ]
    private static let uncertaintyByAge: [Int: AgeDefaults] = [
        40: AgeDefaults(albumin: 1.3542, crp: 0.6658, alkalinePhosphatase: 0.5339),
        41: AgeDefaults(albumin: 1.3425, crp: 0.6704, alkalinePhosphatase: 0.5391),
        42: AgeDefaults(albumin: 1.3318, crp: 0.6757, alkalinePhosphatase: 0.5449),
        43: AgeDefaults(albumin: 1.3219, crp: 0.6815, alkalinePhosphatase: 0.5509),
        44: AgeDefaults(albumin: 1.3128, crp: 0.6877, alkalinePhosphatase: 0.5571),
        45: AgeDefaults(albumin: 1.3047, crp: 0.6940, alkalinePhosphatase: 0.5632)
    ]

    private static let imputedMarkerNames = ["Albúmina", "Proteína C reactiva", "Fosfatasa alcalina"]

    // The one PhenoAge input éter's PDF parser has never captured in any form —
    // lymphocyte PERCENTAGE, distinct from the absolute count it already parses
    // as "Leucocitos"/"Linfocitos" — for the one draw already on disk. Read by
    // hand once from the same 26/01/2026 PDF used for ImportStore.supplementalLabs
    // and the web dashboard's PHENOAGE_DRAW. `mostRecentConsistentDraw` prefers a
    // value parsed from `labs` (via the new "Linfocitos %" pattern in
    // ImportStore.parseLabPDF) and only falls back to this for that specific date.
    private static let knownLymphocytePercentages: [Date: Double] = [
        ImportStoreDates.jan26_2026: 35.30
    ]

    /// Picks the most recent lab date that has every required marker together,
    /// so the estimate never silently mixes biomarkers from two different blood
    /// draws — the exact bug caught while building this same feature for the
    /// web dashboard (éter's own parser can date two markers from separate
    /// draws to the same "latest" label).
    nonisolated static func mostRecentConsistentDraw(in labs: [LabResult]) -> DrawMarkers? {
        let byDay = Dictionary(grouping: labs) { Calendar.current.startOfDay(for: $0.date) }
        func value(_ name: String, on day: Date) -> Double? {
            byDay[day]?.first { $0.name == name }?.value
        }
        for day in byDay.keys.sorted(by: >) {
            guard let glucose = value("Glucosa", on: day),
                  let creatinine = value("Creatinina", on: day),
                  let wbc = value("Leucocitos", on: day),
                  let mcv = value("Volumen Corpuscular Medio (MCV)", on: day),
                  let rdw = value("Amplitud distribución eritrocitaria (RDW)", on: day)
            else { continue }
            guard let lymphocytePct = value("Linfocitos %", on: day) ?? knownLymphocytePercentages[day] else { continue }
            return DrawMarkers(date: day, glucoseMgDl: glucose, creatinineMgDl: creatinine, wbc: wbc,
                                lymphocytePct: lymphocytePct, mcv: mcv, rdw: rdw)
        }
        return nil
    }

    /// Returns nil whenever a birth date isn't configured or no internally
    /// consistent draw exists yet — never a guessed number.
    nonisolated static func calculate(labs: [LabResult], birthDate: Date?, now: Date = Date()) -> BiologicalAgeEstimate? {
        guard let birthDate, let draw = mostRecentConsistentDraw(in: labs) else { return nil }
        let chronoAge = Int((draw.date.timeIntervalSince(birthDate) / (365.2425 * 86_400)).rounded(.down))
        guard chronoAge >= 0 else { return nil }
        let clampedAge = min(45, max(40, chronoAge))
        guard let defaults = defaultsByAge[clampedAge], let uncertainty = uncertaintyByAge[clampedAge] else { return nil }

        let glucoseMmolL = draw.glucoseMgDl * 0.05551
        let creatinineUmolL = draw.creatinineMgDl * 88.4

        let xb = -19.9067
            + 0.0804 * Double(chronoAge)
            + (-0.0336) * defaults.albumin
            + 0.0095 * creatinineUmolL
            + 0.1953 * glucoseMmolL
            + 0.0954 * log(max(defaults.crp, 0.22))
            + 0.0554 * draw.wbc
            + (-0.0120) * draw.lymphocytePct
            + 0.0268 * draw.mcv
            + 0.3306 * draw.rdw
            + 0.0019 * defaults.alkalinePhosphatase

        let gamma = 0.0076927
        let k = (exp(gamma * 120) - 1) / gamma
        let estimatedAge = 141.50225 + (log(0.00553 * k) + xb) / 0.090165
        let totalUncertainty = sqrt(pow(uncertainty.albumin, 2) + pow(uncertainty.crp, 2) + pow(uncertainty.alkalinePhosphatase, 2))

        // 6 of the 9 PhenoAge inputs are real for every draw this can compute
        // (imputedMarkerNames is fixed); "medium" reflects that honestly, and
        // would only reach "high" once albumin/CRP/ALP are captured too.
        let confidence = ConfidenceEngine.level(samples: 6, medium: 4, high: 9)

        let contributions = [
            BiomarkerContribution(name: "Edad", value: Double(chronoAge), unit: "años", coefficient: 0.0804, isImputed: false),
            BiomarkerContribution(name: "Albúmina", value: defaults.albumin, unit: "g/L", coefficient: -0.0336, isImputed: true),
            BiomarkerContribution(name: "Creatinina", value: creatinineUmolL, unit: "µmol/L", coefficient: 0.0095, isImputed: false),
            BiomarkerContribution(name: "Glucosa", value: glucoseMmolL, unit: "mmol/L", coefficient: 0.1953, isImputed: false),
            BiomarkerContribution(name: "Proteína C reactiva", value: defaults.crp, unit: "mg/dL", coefficient: 0.0954, isImputed: true),
            BiomarkerContribution(name: "Leucocitos", value: draw.wbc, unit: "×10⁹/L", coefficient: 0.0554, isImputed: false),
            BiomarkerContribution(name: "Linfocitos", value: draw.lymphocytePct, unit: "%", coefficient: -0.0120, isImputed: false),
            BiomarkerContribution(name: "VCM", value: draw.mcv, unit: "fL", coefficient: 0.0268, isImputed: false),
            BiomarkerContribution(name: "ADE (RDW)", value: draw.rdw, unit: "%", coefficient: 0.3306, isImputed: false),
            BiomarkerContribution(name: "Fosfatasa alcalina", value: defaults.alkalinePhosphatase, unit: "U/L", coefficient: 0.0019, isImputed: true)
        ]

        return BiologicalAgeEstimate(
            estimatedAge: estimatedAge, chronologicalAge: chronoAge, delta: estimatedAge - Double(chronoAge),
            uncertainty: totalUncertainty, drawDate: draw.date, imputedMarkers: imputedMarkerNames,
            confidence: confidence, contributions: contributions
        )
    }
}

/// Shared date constant so the hardcoded lymphocyte-percentage backfill above
/// and ImportStore's supplementalLabs seed can never drift apart from a typo.
/// Local-midnight via Calendar.current, matching every other lab date in the
/// app (ImportStore's firstDate(in:)/dateFromFilename(_:) parse the same way).
enum ImportStoreDates {
    static let jan26_2026: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 26))!
}
