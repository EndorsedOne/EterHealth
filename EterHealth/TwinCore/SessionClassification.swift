import Foundation

// PR4. Había DOS definiciones de "esto fue una sesión de calidad":
// TrainingPlanEngine.isQualityRun y una copia inline dentro de
// RunningPerformanceEngine.summarize (con un umbral de RPE distinto, 8 en vez
// de 7). Las dos se apoyaban en el mismo proxy: kcal/min >= 10 y duración
// <= 50 min. Ese proxy confunde calor con intensidad — un rodaje suave y
// largo en agosto quema muchas calorías por minuto sin ser calidad — y
// descarta intervalos cortos que no llegan a ese gasto.
//
// Ahora una sola función, con una escalera de evidencia: se usa la primera
// que baste, y lo que dependa del último peldaño queda marcado como poco
// fiable en vez de pasar por medición.
enum RunQualityBasis: String, Equatable {
    case review          // lo dijo el atleta
    case pace            // ritmo contra su propio forecast
    case heartRate       // pulso medio de ESA sesión
    case legacyCalories  // el proxy de siempre, sin nada mejor
    case insufficient    // no hay con qué juzgar

    // La confianza no es decorativa: es lo que permite que el resto de la app
    // sepa que una clasificación por kcal/min no vale lo mismo que un RPE
    // declarado. El pulso medio va a media porque es una media de sesión, no
    // la fracción real en Z4–Z5 (que HealthKit no nos da por workout aquí).
    var trust: TrustLevel {
        switch self {
        case .review, .pace: return .high
        case .heartRate: return .medium
        case .legacyCalories, .insufficient: return .low
        }
    }
}

struct RunQualityVerdict: Equatable {
    let isQuality: Bool
    let basis: RunQualityBasis
    var trust: TrustLevel { basis.trust }
}

enum SessionClassification {
    // Daniels: el ritmo umbral (T) está unos 10–15 s/km por encima del ritmo
    // de 10k para la mayoría de corredores. 15 es el extremo permisivo del
    // rango a propósito: preferimos incluir una sesión de umbral real antes
    // que descartarla por unos segundos. Heurística documentada, no un número
    // clínico.
    static let thresholdMarginOverTenKSecondsPerKm = 15.0
    // Sin 10k, el 5k sirve de ancla peor: el umbral queda claramente más
    // lento que el ritmo de 5k, así que el margen es mayor.
    static let thresholdMarginOverFiveKSecondsPerKm = 30.0

    // El ritmo por encima del cual una sesión ya no es de calidad, derivado
    // del forecast del propio atleta. nil = no hay forecast, y entonces NO se
    // inventa un ritmo umbral: se baja al siguiente peldaño de evidencia.
    static func thresholdPaceSecondsPerKm(fiveK: RaceForecast?, tenK: RaceForecast?) -> Double? {
        if let tenK { return tenK.seconds / 10 + thresholdMarginOverTenKSecondsPerKm }
        if let fiveK { return fiveK.seconds / 5 + thresholdMarginOverFiveKSecondsPerKm }
        return nil
    }

    static func paceSecondsPerKm(_ workout: HealthWorkout) -> Double? {
        guard let km = workout.distanceKilometers, km >= 1, workout.durationMinutes > 0 else { return nil }
        return workout.durationMinutes * 60 / km
    }

    // La única definición. `review` es la de ESTA sesión (nil si no la hay);
    // `thresholdPace`/`thresholdHeartRate` los calcula el llamante una vez y
    // los reparte — pasarlos en vez de derivarlos aquí dentro evita además la
    // recursión obvia: RunningPerformanceEngine.summarize cuenta sesiones de
    // calidad y es quien produce el forecast del que sale el umbral.
    static func runQuality(_ workout: HealthWorkout, review: WorkoutReview?,
                           thresholdPace: Double?, thresholdHeartRate: Double?) -> RunQualityVerdict {
        // 1. Lo que dijo el atleta manda sobre cualquier proxy.
        if let review {
            let declaredQuality = review.purpose == .quality || review.purpose == .test || review.purpose == .race
            if declaredQuality || review.effort >= 7 { return RunQualityVerdict(isQuality: true, basis: .review) }
            // Un "suave" declarado también es evidencia, y es la que corrige
            // el falso positivo del rodaje caluroso: no seguimos bajando la
            // escalera buscando una razón para llamarlo calidad.
            if review.purpose == .easy || review.effort <= 4 { return RunQualityVerdict(isQuality: false, basis: .review) }
        }
        // 2. Ritmo contra el forecast propio. Vale igual para intervalos de
        //    20 min que para 40: el criterio es el ritmo, no la duración.
        if let thresholdPace, let pace = paceSecondsPerKm(workout) {
            return RunQualityVerdict(isQuality: pace <= thresholdPace, basis: .pace)
        }
        // 3. Pulso medio de esta sesión contra el suelo de Z4 del atleta.
        //    Media de sesión, no fracción en zona: es lo que hay por workout,
        //    y por eso su confianza es media. Nunca zonas agregadas de la
        //    semana, que no dicen nada de ESTA sesión.
        if let thresholdHeartRate, let averageHeartRate = workout.averageHeartRate, averageHeartRate > 0 {
            return RunQualityVerdict(isQuality: averageHeartRate >= thresholdHeartRate, basis: .heartRate)
        }
        // 4. El proxy de siempre, sólo si no hubo nada mejor, y marcado.
        if let calories = workout.calories, workout.durationMinutes > 0 {
            let legacy = workout.durationMinutes <= 50 && calories / workout.durationMinutes >= 10
            return RunQualityVerdict(isQuality: legacy, basis: .legacyCalories)
        }
        return RunQualityVerdict(isQuality: false, basis: .insufficient)
    }

    // Los sitios que sólo necesitan un predicado (hoursSinceLastCompleted,
    // filtros de conteo) reciben uno ya configurado, en vez de que cada uno
    // rearme los umbrales por su cuenta y puedan divergir.
    static func qualityRunPredicate(reviews: [WorkoutReview], thresholdPace: Double?,
                                    thresholdHeartRate: Double?) -> (HealthWorkout) -> Bool {
        let reviewsByID = Dictionary(reviews.map { ($0.workoutID, $0) }, uniquingKeysWith: { first, _ in first })
        return { workout in
            guard workout.activity == "Carrera" else { return false }
            return runQuality(workout, review: reviewsByID["health-\(workout.id.uuidString)"],
                              thresholdPace: thresholdPace, thresholdHeartRate: thresholdHeartRate).isQuality
        }
    }
}
