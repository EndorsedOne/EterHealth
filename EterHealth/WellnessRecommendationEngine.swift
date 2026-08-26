import Foundation

// General, well-established LIFESTYLE guidance for values genuinely
// outside a broadly-agreed optimal range — never a diagnosis, never a
// treatment plan, always pointing to a professional for anything
// clinical or persistent. Deliberately limited to metrics with clear,
// public-health-consensus directionality (blood pressure, LDL/HDL/
// triglycerides, glucose/HbA1c, VO2 max, body fat percentage).
//
// HRV, resting heart rate, respiratory rate, wrist temperature and blood
// oxygen are deliberately excluded — PhysiologicalHealthView's own
// extendedHealthSignalsCard already treats those as "compare to your own
// trend, let the person judge" on purpose (see its own comment there):
// higher/lower isn't simply good/bad for them the way it is for the
// metrics below, so forcing a recommendation onto them would contradict
// a design decision already made deliberately, not fill a real gap.
enum WellnessRecommendationEngine {
    // Same bands LongevityEngine.bloodPressureScore already scores
    // against, so "not optimal" means the same thing in both places.
    static func bloodPressure(systolic: Double, diastolic: Double) -> String? {
        if systolic < 90 || diastolic < 55 {
            return "Tensión baja: hidratación, sal suficiente y levantarte con calma ayudan. Si notas mareo o es persistente, coméntalo con tu médico."
        }
        if systolic >= 140 || diastolic >= 90 {
            return "Tensión elevada: menos sodio, actividad aeróbica regular y controlar el peso son las palancas con más evidencia. Sostenida en este rango merece seguimiento médico, no solo cambios de hábito."
        }
        if systolic >= 120 || diastolic >= 80 {
            return "Tensión algo por encima de tu rango ideal: reducir sodio y mantener actividad aeróbica regular suele bajarla. Confírmalo con mediciones repetidas, no una lectura aislada."
        }
        return nil
    }

    // `name` lets one entry point cover every lab this app already
    // imports without hardcoding units or numeric thresholds itself —
    // `status` ("Alto"/"Bajo") already comes from that lab's own reported
    // reference range (LabResult.status), which is more correct than any
    // fixed number this app could invent.
    static func lab(name: String, status: String) -> String? {
        guard status != "En rango" else { return nil }
        let normalized = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        // Checked before the plain "hdl" branch below — "no-hdl" contains
        // "hdl" as a substring and would otherwise be misread as the HDL
        // entry (wrong direction: no-HDL is scored high-is-bad, like LDL).
        if normalized.contains("no-hdl") || normalized.contains("no hdl") {
            return status == "Alto"
                ? "Colesterol no-HDL alto: suma todo el colesterol aterogénico, no solo el LDL — las mismas palancas (fibra soluble, menos grasa saturada, actividad aeróbica regular) aplican, y conviene comentarlo con tu médico si se mantiene elevado."
                : nil
        }
        if normalized.contains("apolipoprote") || normalized.contains("apo b") || normalized.contains("apo-b") {
            return status == "Alto"
                ? "ApoB alto: cada partícula de LDL/VLDL lleva una — muchos cardiólogos lo consideran hoy un mejor predictor de riesgo que el LDL aislado. Mismas palancas de estilo de vida; si se mantiene elevado, coméntalo con tu médico."
                : nil
        }
        if normalized.contains("lipoproteina") || normalized.contains("lp(a)") || normalized.contains("lp (a)") {
            // Deliberately different framing from every other lipid tip
            // here: Lp(a) is overwhelmingly determined genetically, and no
            // lifestyle change reliably lowers it — saying otherwise would
            // be inventing an actionable lever that doesn't exist.
            return status == "Alto"
                ? "Lipoproteína(a) alta: a diferencia del resto del panel lipídico, esta es mayormente genética — la dieta y el ejercicio apenas la modifican. Vale la pena comentarlo con tu médico para contextualizar el riesgo cardiovascular global, no para buscar bajarla con hábitos."
                : nil
        }
        if normalized.contains("magnesio") {
            return status == "Bajo"
                ? "Magnesio bajo: frutos secos, legumbres, verduras de hoja verde y cereales integrales son las fuentes más fiables — una carencia mantenida puede afectar sueño y calambres musculares."
                : nil
        }
        if normalized.contains("proteina c reactiva") {
            return status == "Alto"
                ? "PCR alta: puede reflejar inflamación pasajera (un resfriado, una sesión muy dura reciente) tanto como un patrón mantenido — si sigue elevada en una analítica posterior sin causa evidente, coméntalo con tu médico."
                : nil
        }
        if normalized.contains("homocisteina") {
            return status == "Alto"
                ? "Homocisteína alta: suele responder a un aporte adecuado de B12, B6 y fólico — revisa esos tres en la misma analítica antes de asumir que hace falta suplementar a ciegas."
                : nil
        }
        if normalized.contains("ldl") {
            return status == "Alto"
                ? "LDL alto: más fibra soluble, menos grasa saturada y actividad aeróbica regular son las palancas con más respaldo — coméntalo con tu médico si se mantiene muy elevado."
                : nil
        }
        if normalized.contains("hdl") {
            // Framed as risk context, not a target to chase: raising HDL
            // pharmacologically hasn't shown the cardiovascular benefit its
            // correlation once suggested — a low reading is a signal that
            // the rest of the lipid panel deserves more attention, not an
            // independent number worth optimizing on its own.
            return status == "Bajo"
                ? "HDL bajo: por sí solo no es el objetivo a perseguir, pero suele acompañar un contexto metabólico que conviene cuidar en conjunto — actividad aeróbica regular, dejar de fumar (si aplica) y grasas saludables (aceite de oliva, frutos secos, pescado azul) son las palancas con más respaldo."
                : nil
        }
        if normalized.contains("triglic") {
            return status == "Alto"
                ? "Triglicéridos altos: menos azúcares simples y alcohol, más actividad aeróbica regular, son las palancas con más evidencia."
                : nil
        }
        if normalized.contains("hba1c") || normalized.contains("glicada") || normalized.contains("glucosa") {
            return status == "Alto"
                ? "Fuera de tu rango: menos azúcares simples y ultraprocesados, más actividad física regular, y control periódico — coméntalo con tu médico si se mantiene."
                : nil
        }
        return nil
    }

    static func vo2Max(_ value: Double) -> String? {
        guard value < 35 else { return nil }
        return "Entrenamiento aeróbico sostenido en Zona 2, con 1–2 sesiones de mayor intensidad por semana, es la vía con más evidencia para subir el VO₂ máx. de forma progresiva."
    }

    static func bodyFatPercentage(_ value: Double) -> String? {
        if value > 30 {
            return "Un déficit calórico moderado y sostenido junto con entrenamiento de fuerza regular es la combinación con más evidencia para reducir grasa corporal sin perder masa magra."
        }
        if value < 7 {
            return "Un porcentaje muy bajo de grasa corporal puede afectar a hormonas y recuperación — si es sostenido, coméntalo con un profesional, no solo con ajustes de dieta."
        }
        return nil
    }
}
