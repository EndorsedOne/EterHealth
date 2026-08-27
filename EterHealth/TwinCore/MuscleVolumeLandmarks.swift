import Foundation

// MEV/MAV/MRV — Minimum Effective / Maximum Adaptive / Maximum Recoverable
// weekly Volume, en SERIES DIRECTAS por grupo muscular y semana. El concepto
// de landmark de volumen está establecido en la literatura de hipertrofia
// (no es invención de esta app); lo que sí es propio de esta app es a qué
// números concretos se compromete, y por qué son los que son.
//
// ─── De dónde salen los números ────────────────────────────────────────────
//
// Punto de partida: los meta-análisis de dosis-respuesta de volumen
// (Schoenfeld/Ogborn/Krieger 2017 y la línea de trabajo posterior,
// Baz-Valle et al. 2022) sitúan la banda productiva para intermedios en
// torno a 10–20 series directas por músculo y semana, con retornos
// decrecientes —no negativos— hacia el extremo alto. La estructura de tres
// landmarks (MEV/MAV/MRV) viene de la guía tipo Renaissance Periodization,
// que es de donde esta app toma el vocabulario.
//
// PR9 sube la mitad de la tabla porque la anterior no era esa banda: los
// valores de MAV eran, literalmente, los targets por eje que MuscleRadar
// tenía escritos a mano para dibujar un radar retrospectivo, repartidos
// entre los 10 músculos que TwinEngine/MuscleReadiness siguen. Servían para
// que el radar y la prescripción hablaran del mismo número (eso sigue
// siendo cierto y es bueno), pero como landmarks eran incoherentes entre
// sí: Isquios y Gemelos en MAV 4 —que con el ratio 0.5× dejaba el MEV en
// DOS series semanales, por debajo de cualquier umbral de estímulo que la
// literatura reconozca— mientras Espalda estaba en 16 y Pecho en 15, ya
// dentro de la banda. Un tren inferior con landmarks cuatro veces más bajos
// que el superior no describe a ningún atleta; describe el orden en que
// alguien rellenó un diccionario para un gráfico.
//
// ─── Por qué el tren inferior se queda en el extremo BAJO de la banda ─────
//
// Y no en el medio, que es donde la literatura de hipertrofia pura lo
// pondría. Dos razones concretas de esta app, ninguna de ellas "por
// prudencia" en abstracto:
//
//  1. `recentSets` (lo que se compara contra estos landmarks) cuenta series
//     de RESISTENCIA — sale de ImportedWorkout.effectiveMuscleSets, es decir
//     de Hevy. La carrera y la bici cargan cuádriceps, glúteos, isquios y
//     gemelos de verdad (TrainingPlanEngine.cardioMuscleLoad ya lo modela
//     para la fatiga), pero ese estímulo es INVISIBLE para este contador. Un
//     MEV de pierna en el medio de la banda leería "déficit real" en un
//     atleta híbrido que acaba de hacer una tirada larga y una sesión de
//     calidad esa semana.
//  2. `volumeUrgency` sólo mueve QUÉ patrón de fuerza toca, nunca cuántos
//     días de fuerza hay (eso lo deciden goalFocus y los rangos del bloque).
//     Un MEV de pierna alto no añade sesiones: sesga la rotación hacia
//     pierna, que es exactamente lo que la protección de interferencia
//     concurrente (avoidLegs) existe para evitar en semanas con carrera
//     clave. Subir legs al medio de la banda empujaría contra ese mecanismo
//     en vez de cooperar con él.
//
// Por la misma lógica al revés, Bíceps/Tríceps/Core se quedan también en el
// extremo bajo: MuscleMap.involvement ya acredita trabajo indirecto
// ponderado (un remo suma a bíceps, un press a tríceps, una sentadilla a
// core), así que el número de "series directas" que llega aquí no es sólo
// el trabajo aislado. Pedir la banda alta de series directas encima de ese
// crédito indirecto sería contar dos veces.
//
// Pecho (15), Espalda (16) y Hombros (13) se quedan EXACTAMENTE como
// estaban: ya caían dentro de la banda de la literatura, así que moverlos
// sería churn sin evidencia que lo respalde.
//
// ─── Qué son estos números y qué no ──────────────────────────────────────
//
// Son PRIORS. Concretamente:
//
//  · MEV = 0.5 × MAV y MRV = 1.5 × MAV son ratios FIJOS, y eso es una
//    simplificación real: en la literatura el espaciado entre landmarks
//    varía músculo a músculo. Se mantienen porque esta app no tiene datos
//    propios con los que justificar un espaciado por músculo, y fabricar
//    tres números independientes por grupo daría una falsa precisión
//    per-músculo que nada respalda. Documentado como simplificación en vez
//    de disfrazado.
//  · El MRV lo puede SOBRESCRIBIR el aprendizaje real de este atleta
//    (VolumeLandmarkLearning.learnedMRV, que estima la frontera por encima
//    de la cual su e1RM se estanca). Cuando existe, manda el aprendido. El
//    MEV y el MAV no se aprenden: no hay señal en los datos de esta app que
//    permita estimar un "mínimo efectivo" sin experimentar deliberadamente
//    por debajo de él.
//  · El MAV sí admite un ajuste PEQUEÑO Y ACOTADO por el volumen que este
//    atleta sostiene de verdad — ver `landmarks(for:learned:sustained:)`
//    abajo. Es un empujón del prior hacia la realidad medida, no un
//    landmark aprendido.
//
// ─── Limitación conocida, que sigue siéndolo ──────────────────────────────
//
// NO son individuales por experiencia de entrenamiento, edad ni tamaño
// corporal, y no hay intención de derivarlos de esas variables: esta app no
// tiene ninguna forma honesta de medir "años de entrenamiento efectivo", y
// la evidencia para escalar landmarks por edad o antropometría es mucho más
// débil que la que sostiene la banda de 10–20 en sí. La única
// individualización que existe aquí es la que sale de los propios datos de
// entrenamiento: el MRV aprendido y el ajuste de tolerancia del MAV.
struct MuscleVolumeLandmarks {
    let mev: Double
    let mav: Double
    let mrv: Double
}

enum MuscleVolumeLandmarkTable {
    // Same 10 names MuscleReadiness.name already uses. Series directas por
    // semana. Los valores derivados (MEV 0.5×, MRV 1.5×) quedan así:
    //
    //   Músculo      MAV   MEV   MRV     antes de PR9 (MAV/MEV/MRV)
    //   Cuádriceps    12     6    18       8 /  4 / 12
    //   Glúteos       10     5    15       6 /  3 /  9
    //   Isquios       10     5    15       4 /  2 /  6   ← MEV de 2 series
    //   Gemelos       10     5    15       4 /  2 /  6   ← MEV de 2 series
    //   Pecho         15     8    23      sin cambios
    //   Espalda       16     8    24      sin cambios
    //   Hombros       13     7    20      sin cambios
    //   Bíceps        10     5    15       7 /  4 / 11
    //   Tríceps       10     5    15       9 /  5 / 14
    //   Core          10     5    15       8 /  4 / 12
    private static let weeklyMAV: [String: Double] = [
        "Cuádriceps": 12, "Glúteos": 10, "Isquios": 10, "Gemelos": 10,
        "Pecho": 15, "Espalda": 16, "Hombros": 13,
        "Bíceps": 10, "Tríceps": 10, "Core": 10
    ]
    // Falls back to this when a muscle name isn't in the table above —
    // matches MuscleRadar's own prior fallback for the same situation, y
    // sigue estando dentro de la banda de la literatura para un grupo del
    // que no se sabe nada más.
    private static let fallbackMAV = 14.0

    // Topes del ajuste de tolerancia del MAV. ±25% es deliberadamente
    // pequeño: esto NO es un landmark aprendido (para eso está
    // VolumeLandmarkLearning), es un empujón del prior hacia el volumen que
    // este atleta sostiene de verdad, para que el sistema no le pida de
    // golpe 15 series de pecho a alguien cuyas últimas semanas reales son de
    // 5, ni le diga que 20 son "por encima del objetivo" cuando lleva meses
    // haciéndolas y progresando.
    static let minimumToleranceMultiple = 0.75
    static let maximumToleranceMultiple = 1.25

    // PR6: la tabla se queda como PRIOR. Cuando VolumeLandmarkLearning ha
    // podido estimar un MRV real para este músculo, ese manda; el MEV sigue
    // siendo 0.5 × MAV. Sin aprendizaje, exactamente el mismo número que
    // antes.
    //
    // PR9: `sustained` es el volumen semanal que este atleta sostiene de
    // verdad en este músculo (mediana de las semanas con volumen real, ver
    // VolumeLandmarkLearning.sustainedWeeklySets). Cuando llega, el MAV se
    // mueve a medio camino entre el prior y esa realidad, acotado a ±25% del
    // prior — así el MEV y el MRV derivados se mueven con él, que es lo que
    // hace que el ajuste signifique algo y no sea decorativo. Sin `sustained`
    // (el caso por defecto, y el de todos los call sites que existían antes),
    // el resultado es idéntico al de PR6: firma compatible, comportamiento
    // sin cambios.
    nonisolated static func landmarks(for muscle: String,
                                      learned: [String: LearnedVolumeLandmark] = [:],
                                      sustained: [String: Double] = [:]) -> MuscleVolumeLandmarks {
        let prior = priorMAV(for: muscle)
        let mav = adjustedMAV(prior: prior, sustained: sustained[muscle])
        let priorMRV = (mav * 1.5).rounded()
        return MuscleVolumeLandmarks(mev: (mav * 0.5).rounded(), mav: mav,
                                     mrv: learned[muscle]?.mrv ?? priorMRV)
    }

    /// El prior de tabla, sin ajustar por nada. Existe como función propia
    /// porque VolumeLandmarkLearning necesita acotar su MRV aprendido contra
    /// el prior PURO: si lo acotara contra el MAV ya ajustado por tolerancia,
    /// el ajuste y el aprendizaje se amplificarían el uno al otro (más
    /// volumen sostenido → MAV más alto → tope del MRV aprendido más alto →
    /// más volumen tolerado), que es exactamente el bucle que un tope existe
    /// para impedir.
    nonisolated static func priorMAV(for muscle: String) -> Double {
        weeklyMAV[muscle] ?? fallbackMAV
    }

    /// Heurística documentada, no un modelo: el MAV se mueve a medio camino
    /// entre el prior y el volumen sostenido real, y nunca más de ±25% del
    /// prior. `nil` (sin evidencia suficiente) devuelve el prior tal cual —
    /// la misma regla que el resto de la app: sin datos no hay penalización
    /// ni premio, hay el prior y se dice que es un prior.
    nonisolated static func adjustedMAV(prior: Double, sustained: Double?) -> Double {
        guard let sustained, sustained > 0 else { return prior }
        let halfway = (prior + sustained) / 2
        return min(prior * maximumToleranceMultiple,
                   max(prior * minimumToleranceMultiple, halfway)).rounded()
    }

    // Same bucket names MuscleRadar's own radar axes use — its displayed
    // target is the SUM of its constituent muscles' real MAV, instead of a
    // second, separately hand-picked aggregate. Sigue leyendo el PRIOR y no
    // el MAV ajustado: el radar es una vista retrospectiva agregada de 10
    // días y su denominador tiene que ser estable y comparable período a
    // período, no moverse con el ajuste de tolerancia de cada músculo.
    nonisolated static func bucketMAV(_ bucket: String) -> Double {
        switch bucket {
        case "Piernas": return ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"].reduce(0) { $0 + (weeklyMAV[$1] ?? 0) }
        case "Brazos": return ["Bíceps", "Tríceps"].reduce(0) { $0 + (weeklyMAV[$1] ?? 0) }
        default: return weeklyMAV[bucket] ?? fallbackMAV
        }
    }
}
