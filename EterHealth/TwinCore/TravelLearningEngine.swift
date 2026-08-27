import Foundation

// PR16. La respuesta individual a los viajes, aprendida de los episodios ya
// medidos. Cierra el bucle que PR15 dejó abierto: allí las tasas de
// re-sincronización eran un prior de literatura que las señales podían acortar
// para el episodio en curso, pero nada se acumulaba entre viajes.
//
// QUÉ SE APRENDE, y por qué exactamente eso: una TASA en horas de
// desplazamiento de fase por día, no una duración. El prior ya es una tasa
// (≈1 h/día al este, ≈1.5 al oeste), así que aprender la misma magnitud es una
// sustitución limpia que se propaga sola a todo lo que depende de ella — la
// longitud de las fases, el decaimiento del desajuste, el paso de step().
//
// Y aprender una tasa en vez de "días hasta estabilizar" tiene una segunda
// consecuencia que mejora la propia idea de "viajes comparables": una tasa
// normaliza la magnitud del desplazamiento. Un Madrid–Nueva York de 6 h y un
// Madrid–Tokio de 8 h no son comparables en días, pero sí en h/día, así que los
// dos entran en la misma estimación. La restricción de "±2 h de diferencia
// horaria" que parecía necesaria al diseñar esto sobra: lo que tiene que
// coincidir es la DIRECCIÓN, porque adelantar y retrasar fase son fisiologías
// distintas, no dos versiones del mismo número.
//
// Puro y sin stores: lee sólo `TravelEpisode.measuredOutcome`, que es la
// medición ya persistida. No necesita las series de HealthKit —y por eso
// funciona con episodios de hace dos años, cuando esas series ya no existen.

enum TravelLeg: String, Codable, CaseIterable, Identifiable {
    case outbound = "Ida"
    case homeReturn = "Vuelta"
    var id: String { rawValue }
}

/// Un tramo medido: lo que el prior predijo frente a lo que de verdad pasó.
struct TravelLegOutcome: Equatable, Identifiable {
    let episodeID: UUID
    let title: String
    let leg: TravelLeg
    /// Con signo, como en todo el modelo: + este, − oeste.
    let shiftHours: Double
    let arrival: Date
    /// Los días que el prior de la literatura predijo para este tramo.
    let priorDays: Double
    /// Los días reales hasta estabilidad sostenida. nil = nunca se confirmó
    /// dentro del episodio, que es información distinta de "tardó mucho" y por
    /// eso no se sustituye por un número grande.
    let actualDays: Double?
    let confounders: TravelConfounders

    var id: String { "\(episodeID.uuidString)-\(leg.rawValue)" }
    var isAdvance: Bool { shiftHours > 0 }

    /// La tasa observada. Sin desplazamiento no hay tasa que medir, y con
    /// `actualDays` a 0 tampoco (dividir por cero daría infinito, no una
    /// re-sincronización instantánea).
    var observedHoursPerDay: Double? {
        guard let actualDays, actualDays > 0, shiftHours != 0 else { return nil }
        return abs(shiftHours) / actualDays
    }

    /// Un tramo entra en la estimación sólo si hay tasa observada Y ningún
    /// confusor. Con muestras de dos o tres episodios, ponderar un episodio
    /// confundido en vez de excluirlo sería precisión falsa: no hay datos para
    /// estimar cuánto pesa una gripe.
    var isUsableForLearning: Bool { observedHoursPerDay != nil && confounders.isEmpty }

    /// Para la pantalla: si fue más rápido o más lento que el prior.
    var deltaVersusPriorDays: Double? { actualDays.map { $0 - priorDays } }
}

struct LearnedReentrainmentRate: Equatable {
    /// true = adelanto de fase (este), false = retraso (oeste).
    let isAdvance: Bool
    /// La tasa que se va a usar, ya acotada contra el prior.
    let hoursPerDay: Double
    let priorHoursPerDay: Double
    /// La mediana cruda, antes de acotar. Se conserva para poder decir en la
    /// UI "tu mediana es X pero se aplica Y porque el tope no deja más".
    let medianHoursPerDay: Double
    let episodesUsed: Int
    let episodesExcluded: Int
    let confidence: ConfidenceAssessment

    var isBounded: Bool { abs(hoursPerDay - medianHoursPerDay) > 0.001 }
    var isFasterThanPrior: Bool { hoursPerDay > priorHoursPerDay }
    var direction: String { isAdvance ? "hacia el este" : "hacia el oeste" }
}

struct TravelResponseProfile: Equatable {
    let outcomes: [TravelLegOutcome]
    let advance: LearnedReentrainmentRate?
    let delay: LearnedReentrainmentRate?

    static let empty = TravelResponseProfile(outcomes: [], advance: nil, delay: nil)

    /// Listas para inyectar. Cada dirección cae al prior por separado: se puede
    /// haber aprendido el oeste y no el este, y mezclar una tasa medida con un
    /// prior es correcto — lo que sería incorrecto es esperar a tener las dos.
    var rates: ReentrainmentRates {
        ReentrainmentRates(
            advanceHoursPerDay: advance?.hoursPerDay ?? ReentrainmentRates.prior.advanceHoursPerDay,
            delayHoursPerDay: delay?.hoursPerDay ?? ReentrainmentRates.prior.delayHoursPerDay
        )
    }

    var hasLearnedAnything: Bool { advance != nil || delay != nil }
    var measuredOutcomes: [TravelLegOutcome] { outcomes.filter { $0.actualDays != nil } }
}

enum TravelLearningEngine {
    /// Mínimo para afirmar algo. DOS, y no las 8 semanas que exige
    /// VolumeLandmarkLearning, porque las unidades no son comparables: allí una
    /// semana de volumen llega cada siete días, aquí un viaje intercontinental
    /// llega tres o cuatro veces al año. Exigir ocho episodios por dirección
    /// significaría no aprender nunca, y un aprendiz que nunca aprende es peor
    /// que no tenerlo: da la impresión de que el sistema se adapta cuando no.
    ///
    /// Dos episodios son poca evidencia y por eso el resultado va acotado
    /// contra el prior y su confianza es baja hasta el tercero. La honestidad
    /// aquí no está en el umbral, está en decir cuánta evidencia hay.
    static let minimumEpisodesPerDirection = 2
    static let confidentEpisodesPerDirection = 3

    /// El aprendizaje no puede alejarse arbitrariamente del prior. Una tasa
    /// personal la mitad o el doble de la poblacional es plausible; diez veces
    /// no lo es, y con dos muestras un error de medición basta para producirlo.
    /// Mismos topes en espíritu que VolumeLandmarkLearning (0.6×/2.0×).
    static let minimumPriorMultiple = 0.5
    static let maximumPriorMultiple = 2.0

    /// Los tramos medidos de un historial de episodios. Un episodio aporta
    /// hasta dos: la ida y la vuelta, que son fases distintas con tasas
    /// distintas y por tanto observaciones independientes.
    nonisolated static func outcomes(from episodes: [TravelEpisode]) -> [TravelLegOutcome] {
        var result: [TravelLegOutcome] = []
        for episode in episodes {
            // Un viaje cancelado no ocurrió, y uno con horario de origen
            // mantenido nunca intentó adaptarse: medir su "tasa" daría un
            // número que no describe ninguna re-sincronización.
            guard !episode.isCancelled, episode.resolvedStayPolicy == .adaptToDestination else { continue }
            let measured = episode.measuredOutcome
            let confounders = measured?.confounders ?? .none
            if let arrival = episode.destinationArrival {
                result.append(TravelLegOutcome(
                    episodeID: episode.id, title: episode.title, leg: .outbound,
                    shiftHours: episode.outboundShiftHours, arrival: arrival,
                    // El prior SIEMPRE, no las tasas aprendidas: la comparación
                    // que la pantalla muestra es "lo que la literatura predijo
                    // frente a lo que te pasó", y usar aquí lo aprendido la
                    // convertiría en un espejo de sí misma.
                    priorDays: CircadianReentrainment.daysToRealign(offsetHours: episode.outboundShiftHours),
                    actualDays: measured?.destinationStabilityDays,
                    confounders: confounders))
            }
            if let homeArrival = episode.homeArrival {
                result.append(TravelLegOutcome(
                    episodeID: episode.id, title: episode.title, leg: .homeReturn,
                    shiftHours: episode.returnShiftHours, arrival: homeArrival,
                    priorDays: CircadianReentrainment.daysToRealign(offsetHours: episode.returnShiftHours),
                    actualDays: measured?.homeStabilityDays,
                    confounders: confounders))
            }
        }
        return result.sorted { $0.arrival > $1.arrival }
    }

    nonisolated static func profile(episodes: [TravelEpisode]) -> TravelResponseProfile {
        let all = outcomes(from: episodes)
        return TravelResponseProfile(
            outcomes: all,
            advance: rate(isAdvance: true, from: all),
            delay: rate(isAdvance: false, from: all)
        )
    }

    /// La tasa de una dirección. Mediana y no media, por la misma razón que
    /// VolumeLandmarkLearning usa mediana: con dos o tres muestras, una sola
    /// mala arrastra la media y no la mediana.
    nonisolated static func rate(isAdvance: Bool, from outcomes: [TravelLegOutcome]) -> LearnedReentrainmentRate? {
        let direction = outcomes.filter { $0.isAdvance == isAdvance }
        let usable = direction.filter(\.isUsableForLearning)
        let excluded = direction.filter { $0.actualDays != nil && !$0.confounders.isEmpty }.count
        guard usable.count >= minimumEpisodesPerDirection,
              let median = median(usable.compactMap(\.observedHoursPerDay)) else { return nil }

        let prior = isAdvance ? ReentrainmentRates.prior.advanceHoursPerDay : ReentrainmentRates.prior.delayHoursPerDay
        let bounded = min(prior * maximumPriorMultiple, max(prior * minimumPriorMultiple, median))
        var confidence = ConfidenceEngine.samples(usable.count,
                                                  medium: minimumEpisodesPerDirection,
                                                  high: confidentEpisodesPerDirection,
                                                  label: "tramo medido \(isAdvance ? "hacia el este" : "hacia el oeste")")
        if excluded > 0 {
            confidence = ConfidenceAssessment(
                score: confidence.score, level: confidence.level,
                reason: confidence.reason + " \(excluded) tramo\(excluded == 1 ? "" : "s") más quedó fuera por episodio potencialmente confundido."
            )
        }
        return LearnedReentrainmentRate(
            isAdvance: isAdvance, hoursPerDay: bounded, priorHoursPerDay: prior,
            medianHoursPerDay: median, episodesUsed: usable.count,
            episodesExcluded: excluded, confidence: confidence
        )
    }

    private nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
