import Foundation

// Groups the ~40 individual lab markers ImportStore can extract into the
// same sections a real lab report already uses (hemograma, bioquímica
// general, perfil lipídico...) instead of one long list ordered only by
// whatever order the PDF happened to yield or plain alphabetization —
// "cómo va mi hierro" or "cómo va mi metabólico" becomes a scan of one
// small group instead of the whole page. The groupings themselves are
// standard Spanish clinical-lab sectioning, not something invented for
// this app; a marker not yet in `membership` (a name added to
// ImportStore's patterns but not mapped here) falls into `.otros` rather
// than silently vanishing or being mis-filed into a category it doesn't
// belong in.
enum LabCategory: String, CaseIterable, Identifiable {
    case hemograma = "Hemograma"
    case bioquimica = "Bioquímica general"
    case lipidico = "Perfil lipídico"
    case hepatico = "Función hepática"
    case renal = "Función renal"
    case hierro = "Hierro y anemia"
    case vitaminas = "Vitaminas"
    case hormonal = "Hormonal"
    case inflamacion = "Inflamación"
    case tumorales = "Marcadores tumorales"
    case vitales = "Constantes vitales"
    case otros = "Otros"

    var id: String { rawValue }

    // A clinician's read order — blood count and core chemistry first,
    // anthropometrics/vitals and the catch-all last — not alphabetical.
    static let displayOrder: [LabCategory] = [
        .hemograma, .bioquimica, .lipidico, .hepatico, .renal,
        .hierro, .vitaminas, .hormonal, .inflamacion, .tumorales, .vitales, .otros
    ]

    private static let membership: [String: LabCategory] = [
        "Hemoglobina": .hemograma, "Hematocrito": .hemograma, "Hematíes": .hemograma,
        "Plaquetas": .hemograma, "Leucocitos": .hemograma, "Neutrófilos": .hemograma,
        "Linfocitos": .hemograma, "Linfocitos %": .hemograma,
        "Volumen Corpuscular Medio (MCV)": .hemograma,
        "Amplitud distribución eritrocitaria (RDW)": .hemograma,
        "Hemoglobina Corpuscular Media (MCH)": .hemograma,
        "Conc. Hemoglobina Corpuscular (MCHC)": .hemograma,

        "Glucosa": .bioquimica, "Hemoglobina glicada A1c": .bioquimica, "Ácido úrico": .bioquimica,
        "Sodio": .bioquimica, "Potasio": .bioquimica, "Calcio": .bioquimica, "Fósforo": .bioquimica,
        "Magnesio": .bioquimica,

        "Colesterol total": .lipidico, "Colesterol HDL": .lipidico, "Colesterol LDL": .lipidico,
        "Triglicéridos": .lipidico, "Colesterol VLDL": .lipidico, "Riesgo aterogénico": .lipidico,
        "Apolipoproteína B": .lipidico, "Lipoproteína (a)": .lipidico, "Colesterol no-HDL": .lipidico,

        "GOT": .hepatico, "GPT": .hepatico, "GGT": .hepatico,

        "Creatinina": .renal, "Filtrado glomerular": .renal, "Urea": .renal,

        "Hierro": .hierro, "Transferrina": .hierro, "Saturación transferrina": .hierro, "Ferritina": .hierro,

        "Folato (vitamina B9)": .vitaminas, "Vitamina B12": .vitaminas, "Vitamina D": .vitaminas,

        "Cortisol matutino": .hormonal, "TSH": .hormonal, "Testosterona": .hormonal, "Testosterona libre": .hormonal,

        "Proteína C reactiva": .inflamacion, "Homocisteína": .inflamacion,

        "PSA total": .tumorales,

        "Peso": .vitales, "IMC": .vitales, "Presión sistólica": .vitales, "Presión diastólica": .vitales, "Pulso": .vitales,
    ]

    static func of(_ labName: String) -> LabCategory {
        membership[labName] ?? .otros
    }

    // Shared grouping logic for anything keyed by a lab name — used for
    // both the flat `latestLabs` list and `labSeries()`'s per-marker
    // series, so the two sections of ClinicalHealthSectionView can never
    // group the same marker differently by accident.
    static func grouped<T>(_ items: [T], name: (T) -> String) -> [(LabCategory, [T])] {
        let byCategory = Dictionary(grouping: items, by: { of(name($0)) })
        return displayOrder.compactMap { category in
            guard let group = byCategory[category], !group.isEmpty else { return nil }
            return (category, group)
        }
    }
}
