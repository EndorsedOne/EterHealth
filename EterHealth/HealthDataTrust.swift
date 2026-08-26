import Foundation

@MainActor
enum HealthDataTrust {
    static func sleep(_ health: HealthStore) -> DataTrust {
        let samples = health.sleepHistory.count
        return DataTrust(
            nature: .measured,
            source: "Apple Salud · fuente de sueño seleccionada",
            measuredAt: health.sleepHistory.last?.date ?? health.lastUpdated,
            samples: samples,
            level: ConfidenceEngine.level(samples: samples, medium: 5, high: 14),
            explanation: "Se usa el sueño sincronizado con Apple Salud y una única fuente prioritaria por noche para reducir duplicados.",
            limitations: "Las fases REM, esencial y profundo son estimaciones del dispositivo; no equivalen a una polisomnografía."
        )
    }

    static func trend(title: String, points: [TrendPoint], health: HealthStore) -> DataTrust {
        let calculated = title.localizedCaseInsensitiveContains("vo₂")
        return DataTrust(
            nature: calculated ? .calculated : .measured,
            source: calculated ? "Apple Salud · estimación de Apple Watch" : "Apple Salud",
            measuredAt: points.last?.date ?? health.lastUpdated,
            samples: points.count,
            level: ConfidenceEngine.level(samples: points.count, medium: 7, high: 21),
            explanation: calculated ? "Apple Watch estima el VO₂ máximo en actividades exteriores compatibles; la tendencia es más útil que una lectura aislada." : "La serie contiene las observaciones disponibles en Apple Salud y se compara a lo largo del tiempo.",
            limitations: calculated ? "No es una prueba de laboratorio y puede variar con terreno, temperatura, fatiga y calidad de la señal." : "La frecuencia y el momento de muestreo no son uniformes; una sola lectura no define tu estado."
        )
    }

}
