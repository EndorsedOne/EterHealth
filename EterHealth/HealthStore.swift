import Foundation
import HealthKit
import CoreLocation
import WatchConnectivity

@MainActor
final class HealthStore: ObservableObject {
    @Published var authorizationRequested = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var snapshot = HealthSnapshot.empty
    @Published var vo2MaxHistory: [TrendPoint] = []
    /// Por qué no se abrió la app del reloj, cuando no se abre. nil = todo bien
    /// o nadie lo ha intentado. Antes el fallo era silencioso y no se
    /// distinguía de "esta función no existe".
    @Published var watchStartDiagnostic: String?
    @Published var hrvHistory: [TrendPoint] = []
    @Published var restingHeartRateHistory: [TrendPoint] = []
    @Published var sleepHistory: [TrendPoint] = []
    @Published var sleepScheduleHistory: [NightlySleepSchedule] = []
    @Published var sleepStagesHistory: [NightlySleepStages] = []
    @Published var workoutHistory: [HealthWorkout] = []
    @Published var recentWorkouts: [HealthWorkout] = []
    @Published var heartRateZones: [HeartRateZone] = []
    @Published var runningHeartRateZones: [HeartRateZone] = []
    @Published var sleepStages = SleepStages.empty
    @Published var heartRateRecoveryHistory: [TrendPoint] = []
    @Published var alcoholHistory: [AlcoholSample] = []
    @Published var bodyWeightHistory: [TrendPoint] = []
    @Published var bodyFatHistory: [TrendPoint] = []
    @Published var leanMassHistory: [TrendPoint] = []
    @Published var bodyMeasurements: [BodyMeasurement] = []
    @Published var systolicBloodPressureHistory: [TrendPoint] = []
    @Published var diastolicBloodPressureHistory: [TrendPoint] = []
    @Published var respiratoryRateHistory: [TrendPoint] = []
    @Published var oxygenSaturationHistory: [TrendPoint] = []
    @Published var wristTemperatureHistory: [TrendPoint] = []
    @Published var walkingHeartRateHistory: [TrendPoint] = []
    @Published var stepsHistory: [TrendPoint] = []
    @Published var ecgHistory: [ECGReading] = []
    // Muestras REALES de HRV de HOY (cada una con su hora), para la gráfica de
    // tendencias del día. HealthKit escribe la HRV de forma esporádica —
    // sobre todo de madrugada y a primera hora— así que suelen ser pocos
    // puntos; por eso van como puntos sobre la curva modelada, no como línea.
    // Consulta de hoy y ligera: se resuelve en refresh(), no en el histórico
    // diferido, porque la pestaña Hoy la enseña pronto.
    @Published var todayHRVSamples: [TrendPoint] = []
    @Published private(set) var isHistoryLoading = false
    @Published private(set) var hasLoadedHistory = false

    private let store = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var scheduledRefresh: Task<Void, Never>?
    /// Punto de salida independiente de la UI para consumidores que deben
    /// actualizarse cuando HealthKit despierta la app en segundo plano.
    var didRefresh: (@MainActor () -> Void)?

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let alcohol = HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages) { types.insert(alcohol) }
        [.bodyMass, .bodyFatPercentage, .leanBodyMass].compactMap { HKQuantityType.quantityType(forIdentifier: $0) }.forEach { types.insert($0) }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        let types: [HKObjectType?] = [
            HKQuantityType.quantityType(forIdentifier: .stepCount),
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .vo2Max),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
            HKQuantityType.quantityType(forIdentifier: .appleExerciseTime),
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
            // HealthKit tracks distance separately per discipline — a
            // cycling or swimming workout carries its distance under
            // distanceCycling/distanceSwimming, never distanceWalkingRunning.
            // Without requesting these too, every bike/pool session's
            // distanceKilometers silently came back nil: no personal pace
            // for the triathlon forecast, no recognized "personal" evidence,
            // no real bike speed or swim pace — it fell back to the generic
            // structural estimate for every user, not just ones without history.
            HKQuantityType.quantityType(forIdentifier: .distanceCycling),
            HKQuantityType.quantityType(forIdentifier: .distanceSwimming),
            HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages),
            HKQuantityType.quantityType(forIdentifier: .bodyMass),
            HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage),
            HKQuantityType.quantityType(forIdentifier: .leanBodyMass),
            HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
            HKQuantityType.quantityType(forIdentifier: .respiratoryRate),
            HKQuantityType.quantityType(forIdentifier: .oxygenSaturation),
            HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature),
            HKQuantityType.quantityType(forIdentifier: .walkingHeartRateAverage),
            HKQuantityType.quantityType(forIdentifier: .heartRateRecoveryOneMinute),
            HKQuantityType.quantityType(forIdentifier: .runningPower),
            HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime),
            HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation),
            HKQuantityType.quantityType(forIdentifier: .runningStrideLength),
            HKQuantityType.quantityType(forIdentifier: .cyclingPower),
            HKQuantityType.quantityType(forIdentifier: .cyclingCadence),
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.workoutType(),
            // Classification and date only — never the electrocardiogram voltage
            // signal itself. That would need the separate HKElectrocardiogramQuery
            // per-sample voltage API, which this app never calls.
            HKObjectType.electrocardiogramType(),
            // Route (GPS/barometric altitude) — the only way to see real
            // descent, since HealthKit's own metadata only carries ascent.
            // See loadElevationDescended: only queried for a small recent
            // window, never the full year the rest of this file loads.
            HKSeriesType.workoutRoute()
        ]
        return Set(types.compactMap { $0 })
    }

    private var observedTypes: [HKSampleType] {
        [
            HKObjectType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .vo2Max),
            HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages),
            HKQuantityType.quantityType(forIdentifier: .bodyMass),
            HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage),
            HKQuantityType.quantityType(forIdentifier: .leanBodyMass),
            HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
            HKQuantityType.quantityType(forIdentifier: .respiratoryRate),
            HKQuantityType.quantityType(forIdentifier: .oxygenSaturation),
            HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature),
            HKQuantityType.quantityType(forIdentifier: .walkingHeartRateAverage),
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
        ].compactMap { $0 }
    }

    func prepare() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "Salud no está disponible en este dispositivo."
            return
        }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: shareTypes, read: readTypes)
            authorizationRequested = status == .unnecessary
            if authorizationRequested {
                installObservers()
                enableBackgroundDelivery()
                await refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func authorize() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            authorizationRequested = true
            installObservers()
            enableBackgroundDelivery()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        hasLoadedHistory = false
        let start = Calendar.current.startOfDay(for: Date())
        async let steps = cumulative(.stepCount, unit: .count(), start: start)
        async let energy = cumulative(.activeEnergyBurned, unit: .kilocalorie(), start: start)
        async let exercise = cumulative(.appleExerciseTime, unit: .minute(), start: start)
        async let heartRate = latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let restingHeartRate = latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrv = latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let sleep = sleepBreakdown()
        async let initialWorkouts = loadRecentWorkouts(days: 30)
        async let todayHRV = intradaySamples(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))

        let resolvedSleep = await sleep
        snapshot = await HealthSnapshot(
            steps: Int(steps.rounded()),
            activeEnergy: Int(energy.rounded()),
            exerciseMinutes: Int(exercise.rounded()),
            heartRate: Int(heartRate.rounded()),
            restingHeartRate: Int(restingHeartRate.rounded()),
            hrv: Int(hrv.rounded()),
            sleepHours: resolvedSleep.asleepHours
        )
        sleepStages = resolvedSleep
        todayHRVSamples = await todayHRV
        recentWorkouts = await initialWorkouts
        workoutHistory = recentWorkouts
        // Descent has no HealthKit metadata equivalent to elevationMeters
        // (ascent) — the only way to get it is a per-workout route query,
        // real HealthKit cost on top of everything above. Scoped to just
        // the last 3 days of running/cycling — all TrainingPlanEngine.
        // weekAhead's real-intensity/elevation muscle-load scaling ever
        // looks at is "today's" matched session — rather than the full
        // 30-day recentWorkouts window, so a normal refresh doesn't pay
        // for descent data nothing else reads yet.
        let descentCutoff = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? .distantPast
        let descentCandidates = recentWorkouts.filter { $0.date >= descentCutoff && ($0.activity == "Carrera" || $0.activity == "Ciclismo") }
        let descentByID = await loadElevationDescended(for: descentCandidates)
        if !descentByID.isEmpty {
            for index in recentWorkouts.indices {
                if let descent = descentByID[recentWorkouts[index].id] { recentWorkouts[index].elevationDescendedMeters = descent }
            }
            for index in workoutHistory.indices {
                if let descent = descentByID[workoutHistory[index].id] { workoutHistory[index].elevationDescendedMeters = descent }
            }
        }
        lastUpdated = Date()
        didRefresh?()
    }

    /// Histórico pesado diferido: nunca debe impedir que Hoy responda.
    ///
    /// Dos fases dentro de una misma pasada. La PRIMERA carga exactamente lo
    /// que el gemelo de Hoy lee de verdad (assess + plan): HRV, reposo, sueño,
    /// regularidad de sueño, alcohol, respiración, temperatura, el archivo de
    /// entrenos y las zonas de carrera. En cuanto están, re-sellamos
    /// `lastUpdated` para que la valoración —calculada primero de forma
    /// aproximada sobre los escalares de hoy— se recalcule ya contra las
    /// líneas base reales. La SEGUNDA carga lo que sólo consumen las pestañas
    /// Salud/Datos/Composición (VO2, composición corporal, tensión, oxígeno,
    /// temperatura de sueño por noche, pasos, FC al caminar, ECG): nunca
    /// bloquea al gemelo. Antes esta función se dejaba fuera la mayor parte de
    /// estos históricos, así que esas pestañas quedaban vacías y el gemelo se
    /// congelaba con líneas base vacías.
    func loadExtendedHistory() async {
        guard !hasLoadedHistory, !isHistoryLoading else { return }
        isHistoryLoading = true
        defer { isHistoryLoading = false }

        // ── Fase 1: lo que el gemelo de Hoy necesita ─────────────────────────
        async let workouts = loadRecentWorkouts(days: 365)
        async let hrv = dailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 90)
        async let resting = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), days: 90)
        async let sleep = sleepDurationHistory(days: 90)
        async let sleepSchedule = sleepScheduleHistory(days: 60)
        async let alcohol = loadAlcohol(days: 365)
        async let respiratory = dailyAverage(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), days: 90)
        async let temperature = dailyAverage(.appleSleepingWristTemperature, unit: .degreeCelsius(), days: 90)

        hrvHistory = await hrv
        restingHeartRateHistory = await resting
        sleepHistory = await sleep
        sleepScheduleHistory = await sleepSchedule
        alcoholHistory = await alcohol
        respiratoryRateHistory = await respiratory
        wristTemperatureHistory = await temperature

        var archive = await workouts
        // El descenso real ya se calculó para el subconjunto reciente en
        // refresh(); el archivo de 365 días llega sin él. Lo copiamos por id en
        // vez de volver a consultar las rutas (coste HealthKit real) — el resto
        // del archivo no lo necesita (sólo la sesión de "hoy" lo lee).
        let descentByID = Dictionary(recentWorkouts.compactMap { workout in
            workout.elevationDescendedMeters.map { (workout.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        if !descentByID.isEmpty {
            for index in archive.indices {
                if let descent = descentByID[archive[index].id] { archive[index].elevationDescendedMeters = descent }
            }
        }
        workoutHistory = archive
        heartRateZones = await loadHeartRateZones(workouts: recentWorkouts, days: 10)
        runningHeartRateZones = await loadHeartRateZones(workouts: recentWorkouts.filter { $0.activity == "Carrera" }, days: 10)
        heartRateRecoveryHistory = await loadHeartRateRecovery(workouts: recentWorkouts)

        // El gemelo puede recalcularse ya contra líneas base reales. Este es el
        // único punto donde loadExtendedHistory vuelve a tocar lastUpdated:
        // ContentView lo trata como la señal para recomputar la valoración.
        lastUpdated = Date()
        didRefresh?()
        await Task.yield()

        // ── Fase 2: sólo pestañas Salud/Datos/Composición ────────────────────
        async let vo2 = dailyAverage(.vo2Max, unit: HKUnit(from: "ml/kg*min"), days: 365)
        async let sleepStages = sleepStagesHistory(days: 60)
        async let steps = dailySum(.stepCount, unit: .count(), days: 90)
        async let weight = dailyAverage(.bodyMass, unit: .gramUnit(with: .kilo), days: 365)
        async let fat = dailyAverage(.bodyFatPercentage, unit: .percent(), days: 365)
        async let lean = dailyAverage(.leanBodyMass, unit: .gramUnit(with: .kilo), days: 365)
        async let bodyEntries = loadBodyMeasurements(days: 365)
        async let systolic = dailyAverage(.bloodPressureSystolic, unit: .millimeterOfMercury(), days: 365)
        async let diastolic = dailyAverage(.bloodPressureDiastolic, unit: .millimeterOfMercury(), days: 365)
        async let oxygen = dailyAverage(.oxygenSaturation, unit: .percent(), days: 90)
        async let walkingHeart = dailyAverage(.walkingHeartRateAverage, unit: HKUnit.count().unitDivided(by: .minute()), days: 180)
        async let ecg = loadECGHistory(days: 365)

        vo2MaxHistory = await vo2
        sleepStagesHistory = await sleepStages
        stepsHistory = await steps
        await Task.yield()
        bodyWeightHistory = await weight
        bodyFatHistory = await fat.map { TrendPoint(date: $0.date, value: $0.value * 100) }
        leanMassHistory = await lean
        bodyMeasurements = await bodyEntries
        await Task.yield()
        systolicBloodPressureHistory = await systolic
        diastolicBloodPressureHistory = await diastolic
        oxygenSaturationHistory = await oxygen.map { TrendPoint(date: $0.date, value: $0.value * 100) }
        walkingHeartRateHistory = await walkingHeart
        ecgHistory = await ecg
        hasLoadedHistory = true
    }

    /// Señales de sueño, HRV, pulso en reposo y horario de sueño para una
    /// VENTANA ARBITRARIA (no "últimos N días"). Sirve para inferir la
    /// estabilidad de un viaje PASADO a partir de lo que Apple Salud todavía
    /// guarde de aquellas fechas. Consulta a demanda: no toca las @Published del
    /// arranque, así que no afecta al tiempo de arranque.
    func travelSignalWindow(start: Date, end: Date) async
        -> (sleep: [TrendPoint], hrv: [TrendPoint], resting: [TrendPoint], schedule: [NightlySleepSchedule]) {
        async let hrv = dailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end)
        async let resting = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end)
        async let sleep = sleepDurationHistory(from: start, to: end)
        async let schedule = sleepScheduleHistory(from: start, to: end)
        return await (sleep: sleep, hrv: hrv, resting: resting, schedule: schedule)
    }

    func saveStrengthWorkout(start: Date, end: Date) async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            await refresh()
        } catch {
            errorMessage = "La sesión se guardó en Éter, pero Apple Salud no pudo registrarla: \(error.localizedDescription)"
        }
    }

    func saveAlcohol(drinks: Int, date: Date) async {
        guard drinks > 0,
              let type = HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages) else { return }
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: Double(drinks)), start: date, end: date)
        do {
            try await store.save(sample)
            alcoholHistory = await loadAlcohol(days: 365)
        } catch {
            errorMessage = "El factor se guardó en Éter, pero no pudo escribirse en Apple Salud: \(error.localizedDescription)"
        }
    }

    func replaceAlcohol(near previousDate: Date, drinks: Int, date: Date) async {
        await deleteAlcohol(near: previousDate, refreshAfter: false)
        if drinks > 0 { await saveAlcohol(drinks: drinks, date: date) }
        else { alcoholHistory = await loadAlcohol(days: 365) }
    }

    func deleteAlcohol(near date: Date, refreshAfter: Bool = true) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: date.addingTimeInterval(-120), end: date.addingTimeInterval(120))
        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, values, _ in
                continuation.resume(returning: values as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
        for sample in samples where sample.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier {
            try? await store.delete(sample)
        }
        if refreshAfter { alcoholHistory = await loadAlcohol(days: 365) }
    }

    func saveBodyComposition(weightKg: Double, bodyFatPercent: Double?, leanMassKg: Double?, date: Date) async -> Bool {
        var samples: [HKQuantitySample] = []
        if weightKg > 0, let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: weightKg), start: date, end: date))
        }
        if let bodyFatPercent, bodyFatPercent > 0, let type = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .percent(), doubleValue: bodyFatPercent / 100), start: date, end: date))
        }
        if let leanMassKg, leanMassKg > 0, let type = HKQuantityType.quantityType(forIdentifier: .leanBodyMass) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: leanMassKg), start: date, end: date))
        }
        guard !samples.isEmpty else { return false }
        do {
            try await store.save(samples)
            await refresh()
            return true
        } catch {
            errorMessage = "No se pudo guardar la composición corporal en Apple Salud: \(error.localizedDescription)"
            return false
        }
    }

    func replaceBodyComposition(_ existing: BodyMeasurement, weightKg: Double, bodyFatPercent: Double?, leanMassKg: Double?, date: Date) async -> Bool {
        guard existing.isOwnedByEter else {
            errorMessage = "Esta medición fue creada por \(existing.source). Solo esa aplicación puede modificarla."
            return false
        }
        let saved = await saveBodyComposition(weightKg: weightKg, bodyFatPercent: bodyFatPercent, leanMassKg: leanMassKg, date: date)
        guard saved else { return false }
        return await deleteBodyMeasurement(existing, refreshAfter: true)
    }

    func deleteBodyMeasurement(_ measurement: BodyMeasurement, refreshAfter: Bool = true) async -> Bool {
        guard measurement.isOwnedByEter else {
            errorMessage = "Esta medición fue creada por \(measurement.source). Bórrala desde la aplicación que la registró o desde Apple Salud."
            return false
        }
        do {
            for id in measurement.sampleIDs {
                if let sample = await sample(with: id) { try await store.delete(sample) }
            }
            if refreshAfter { await refresh() }
            return true
        } catch {
            errorMessage = "No se pudo eliminar la medición de Apple Salud: \(error.localizedDescription)"
            return false
        }
    }

    private func sample(with id: UUID) async -> HKSample? {
        for identifier in [HKQuantityTypeIdentifier.bodyMass, .bodyFatPercentage, .leanBodyMass] {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            if let found = await sample(with: id, type: type) { return found }
        }
        return nil
    }

    private func sample(with id: UUID, type: HKSampleType) async -> HKSample? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForObject(with: id), limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples?.first)
            }
            store.execute(query)
        }
    }

    private func loadBodyMeasurements(days: Int) async -> [BodyMeasurement] {
        async let weights = quantitySamples(.bodyMass, days: days)
        async let fats = quantitySamples(.bodyFatPercentage, days: days)
        async let lean = quantitySamples(.leanBodyMass, days: days)
        let allWeights = await weights, allFats = await fats, allLean = await lean
        let calendar = Calendar.current
        let daysPresent = Set((allWeights + allFats + allLean).map { calendar.startOfDay(for: $0.startDate) })
        return daysPresent.map { day in
            let weight = allWeights.filter { calendar.isDate($0.startDate, inSameDayAs: day) }.max { $0.startDate < $1.startDate }
            let fat = allFats.filter { calendar.isDate($0.startDate, inSameDayAs: day) }.max { $0.startDate < $1.startDate }
            let mass = allLean.filter { calendar.isDate($0.startDate, inSameDayAs: day) }.max { $0.startDate < $1.startDate }
            let source = weight?.sourceRevision.source ?? fat?.sourceRevision.source ?? mass?.sourceRevision.source
            return BodyMeasurement(
                date: weight?.startDate ?? fat?.startDate ?? mass?.startDate ?? day,
                weightKg: weight?.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                bodyFatPercent: fat.map { $0.quantity.doubleValue(for: .percent()) * 100 },
                leanMassKg: mass?.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                sampleIDs: [weight?.uuid, fat?.uuid, mass?.uuid].compactMap { $0 },
                source: source?.name ?? "Apple Salud",
                sourceBundle: source?.bundleIdentifier ?? ""
            )
        }.sorted { $0.date > $1.date }
    }

    private func quantitySamples(_ identifier: HKQuantityTypeIdentifier, days: Int) async -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: Date()), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    private func loadAlcohol(days: Int) async -> [AlcoholSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages) else { return [] }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let values = (samples as? [HKQuantitySample] ?? []).map {
                    AlcoholSample(id: $0.uuid, date: $0.startDate, drinks: $0.quantity.doubleValue(for: .count()), source: $0.sourceRevision.source.name)
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    func deleteWorkout(id: UUID) async -> Bool {
        let workout: HKWorkout? = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: id)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
        guard let workout else {
            errorMessage = "No se encontró el entrenamiento en Apple Salud. Actualiza los datos e inténtalo de nuevo."
            return false
        }
        let deleted: Bool = await withCheckedContinuation { continuation in
            store.delete(workout) { success, error in
                Task { @MainActor in
                    if let error { self.errorMessage = "No se pudo eliminar de Apple Salud: \(error.localizedDescription)" }
                    continuation.resume(returning: success)
                }
            }
        }
        if deleted { await refresh() }
        return deleted
    }

    func startStrengthWorkoutOnWatch() async -> Bool {
        // startWatchApp() itself asks watchOS to hand off/launch éter there —
        // real, intended behavior when a companion Watch app is actually
        // installed and ready to mirror the session. But calling it
        // regardless of that (the previous behavior) meant it fired the
        // exact same handoff attempt with no paired Watch, or a paired
        // Watch that never installed the companion app, and iOS's own
        // handoff/launch attempt is what disrupted the iPhone screen —
        // "se sale de la ventana" for someone who never asked for a Watch
        // session in the first place. No properly installed companion means
        // there is nothing to hand off to, so this returns early instead.
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        // ESPERAR la activación antes de preguntar. `isPaired` y
        // `isWatchAppInstalled` sólo tienen valor una vez la sesión está
        // `.activated`, y `activate()` se llama en el init de WatchMetricsStore
        // — que es asíncrono. Al abrir la primera sesión de fuerza tras lanzar
        // la app, este guard se evaluaba con la sesión todavía inactiva, salía
        // por `false` y el reloj no se abría nunca. Peor: el llamante marca
        // `requestedWatchStart = true` de entrada, así que no se reintentaba.
        //
        // Dos segundos como techo: si en ese tiempo no ha activado, algo va mal
        // de verdad y es mejor decirlo que seguir esperando con la pantalla del
        // entrenamiento ya abierta.
        var waited = 0.0
        while session.activationState != .activated, waited < 2.0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard session.activationState == .activated else {
            await MainActor.run {
                self.watchStartDiagnostic = "La sesión con el Apple Watch no llegó a activarse."
            }
            return false
        }
        guard session.isPaired else {
            await MainActor.run { self.watchStartDiagnostic = "No hay ningún Apple Watch emparejado." }
            return false
        }
        guard session.isWatchAppInstalled else {
            // Pasa de verdad con una instalación de desarrollo: el reloj tiene
            // la app pero WCSession no la ve como companion instalada hasta que
            // se instala por la vía normal. Decirlo es más útil que el silencio
            // de antes, que se confundía con "la función no existe".
            await MainActor.run {
                self.watchStartDiagnostic = "éter no está instalada como app companion en el Apple Watch. Ábrela una vez desde el reloj o instálala desde la app Watch."
            }
            return false
        }
        await MainActor.run { self.watchStartDiagnostic = nil }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        return await withCheckedContinuation { continuation in
            store.startWatchApp(with: configuration) { success, error in
                Task { @MainActor in
                    if let error {
                        // Al diagnóstico y no a errorMessage: errorMessage abre
                        // una alerta modal encima de la sesión de entrenamiento
                        // que acabas de empezar, que es justo cuando menos
                        // quieres una. La cabecera ya tiene sitio para decirlo.
                        self.watchStartDiagnostic = "No se pudo iniciar el Apple Watch: \(error.localizedDescription)"
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func cumulative(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date) async -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return 0 }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// Muestras individuales de HOY (desde las 00:00) con su marca de tiempo,
    /// ordenadas. A diferencia de `latest` (que trae sólo el último valor) o de
    /// `dailyAverage` (que colapsa cada día en un punto), aquí queremos la
    /// dispersión intradía real para dibujarla. Ligera por definición: el
    /// predicado es sólo el día en curso.
    private func intradaySamples(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> [TrendPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let points = (samples as? [HKQuantitySample] ?? []).map {
                    TrendPoint(date: $0.startDate, value: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    private func sleepBreakdown() async -> SleepStages {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return .empty }
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let values = samples as? [HKCategorySample] ?? []
                // Multiple apps may mirror the same night. Select the source with
                // the largest amount of staged sleep to avoid double-counting.
                let grouped = Dictionary(grouping: values) { $0.sourceRevision.source.name }
                let stagedSeconds: ([HKCategorySample]) -> Double = { samples in
                    samples.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue && $0.value != HKCategoryValueSleepAnalysis.awake.rawValue }
                        .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                }
                let best = grouped.values.max { stagedSeconds($0) < stagedSeconds($1) } ?? []
                let sleepSamples = best.filter {
                    $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                    $0.value != HKCategoryValueSleepAnalysis.awake.rawValue
                }
                var awake = 0.0, core = 0.0, deep = 0.0, rem = 0.0, unspecified = 0.0
                for sample in best {
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.awake.rawValue: awake += hours
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue: core += hours
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: deep += hours
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue: rem += hours
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: unspecified += hours
                    default: break
                    }
                }
                continuation.resume(returning: SleepStages(
                    awakeHours: awake, coreHours: core, deepHours: deep, remHours: rem,
                    unspecifiedHours: unspecified,
                    startDate: sleepSamples.map(\.startDate).min(),
                    endDate: sleepSamples.map(\.endDate).max()
                ))
            }
            store.execute(query)
        }
    }

    private func sleepDurationHistory(days: Int) async -> [TrendPoint] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))!
        return await sleepDurationHistory(from: start, to: Date())
    }

    private func sleepDurationHistory(from start: Date, to end: Date) async -> [TrendPoint] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let values = samples as? [HKCategorySample] ?? []
                let asleep = values.filter {
                    $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                    $0.value != HKCategoryValueSleepAnalysis.awake.rawValue
                }
                struct NightSource: Hashable { let day: Date; let source: String }
                var totals: [NightSource: Double] = [:]
                for sample in asleep {
                    // Attribute sleep to the morning on which it ended.
                    let day = calendar.startOfDay(for: sample.endDate)
                    let key = NightSource(day: day, source: sample.sourceRevision.source.name)
                    totals[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 3600
                }
                let byNight = Dictionary(grouping: totals, by: { $0.key.day })
                let points = byNight.compactMap { day, sources -> TrendPoint? in
                    guard let hours = sources.map(\.value).max(), hours > 0.5, hours < 16 else { return nil }
                    return TrendPoint(date: day, value: hours)
                }.sorted { $0.date < $1.date }
                continuation.resume(returning: points)
            }
            self.store.execute(query)
        }
    }

    // Same night-attribution rule as sleepDurationHistory above (whichever
    // morning the sleep ended on), but keeping the earliest asleep-stage
    // start and latest asleep-stage end per (night, source) instead of
    // just their summed duration — so schedule *regularity* (how
    // consistent bedtime/wake time are) can be measured, not just how
    // long each night was.
    private func sleepScheduleHistory(days: Int) async -> [NightlySleepSchedule] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))!
        return await sleepScheduleHistory(from: start, to: Date())
    }

    private func sleepScheduleHistory(from start: Date, to end: Date) async -> [NightlySleepSchedule] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let values = samples as? [HKCategorySample] ?? []
                let asleep = values.filter {
                    $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                    $0.value != HKCategoryValueSleepAnalysis.awake.rawValue
                }
                struct NightSource: Hashable { let night: Date; let source: String }
                var stagedSeconds: [NightSource: Double] = [:]
                var earliestStart: [NightSource: Date] = [:]
                var latestEnd: [NightSource: Date] = [:]
                for sample in asleep {
                    let night = calendar.startOfDay(for: sample.endDate)
                    let key = NightSource(night: night, source: sample.sourceRevision.source.name)
                    stagedSeconds[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                    earliestStart[key] = min(earliestStart[key] ?? sample.startDate, sample.startDate)
                    latestEnd[key] = max(latestEnd[key] ?? sample.endDate, sample.endDate)
                }
                let byNight = Dictionary(grouping: stagedSeconds.keys, by: { $0.night })
                let schedules = byNight.compactMap { night, keys -> NightlySleepSchedule? in
                    // Same source disambiguation as sleepBreakdown() — the
                    // source with the most staged sleep that night wins,
                    // avoiding a double-mirrored night (phone + watch)
                    // from picking an artificially wide bedtime-to-wake span.
                    guard let bestKey = keys.max(by: { (stagedSeconds[$0] ?? 0) < (stagedSeconds[$1] ?? 0) }),
                          let bedtime = earliestStart[bestKey], let wakeTime = latestEnd[bestKey],
                          wakeTime.timeIntervalSince(bedtime) > 30 * 60, wakeTime.timeIntervalSince(bedtime) < 16 * 3600
                    else { return nil }
                    return NightlySleepSchedule(night: night, bedtime: bedtime, wakeTime: wakeTime)
                }.sorted { $0.night < $1.night }
                continuation.resume(returning: schedules)
            }
            self.store.execute(query)
        }
    }

    // Same night-attribution and source-disambiguation rules as
    // sleepDurationHistory/sleepScheduleHistory above, generalizing
    // sleepBreakdown()'s single-night deep/REM/core bucketing across a
    // real date range — the actual data SleepArchitectureEngine needs
    // to score restorative *quality* (how much was deep and REM) instead
    // of only how many hours were logged, which is all sleepHistory
    // captures. Deliberately separate from sleepDurationHistory/
    // sleepScheduleHistory rather than folding into them: those two are
    // read far more often (every PersonalBaselineEngine/TwinEngine call)
    // and don't need the extra per-stage bucketing cost.
    private func sleepStagesHistory(days: Int) async -> [NightlySleepStages] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let values = samples as? [HKCategorySample] ?? []
                struct NightSource: Hashable { let night: Date; let source: String }
                var stagedSeconds: [NightSource: Double] = [:]
                var deep: [NightSource: Double] = [:]
                var rem: [NightSource: Double] = [:]
                var core: [NightSource: Double] = [:]
                var unspecified: [NightSource: Double] = [:]
                var awakeDuringSession: [NightSource: Double] = [:]
                for sample in values {
                    let night = calendar.startOfDay(for: sample.endDate)
                    let key = NightSource(night: night, source: sample.sourceRevision.source.name)
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[key, default: 0] += hours; stagedSeconds[key, default: 0] += hours
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[key, default: 0] += hours; stagedSeconds[key, default: 0] += hours
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                        core[key, default: 0] += hours; stagedSeconds[key, default: 0] += hours
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        unspecified[key, default: 0] += hours; stagedSeconds[key, default: 0] += hours
                    case HKCategoryValueSleepAnalysis.awake.rawValue:
                        awakeDuringSession[key, default: 0] += hours
                    default: break
                    }
                }
                let byNight = Dictionary(grouping: stagedSeconds.keys, by: { $0.night })
                let nights = byNight.compactMap { night, keys -> NightlySleepStages? in
                    // Same source disambiguation as sleepBreakdown()/
                    // sleepScheduleHistory — the source with the most
                    // staged sleep that night wins, avoiding a
                    // double-mirrored night (phone + watch) from summing
                    // the same sleep twice.
                    guard let bestKey = keys.max(by: { (stagedSeconds[$0] ?? 0) < (stagedSeconds[$1] ?? 0) }) else { return nil }
                    let nightStages = NightlySleepStages(
                        night: night, deepHours: deep[bestKey] ?? 0, remHours: rem[bestKey] ?? 0,
                        coreHours: core[bestKey] ?? 0, unspecifiedHours: unspecified[bestKey] ?? 0,
                        awakeHours: awakeDuringSession[bestKey] ?? 0
                    )
                    guard nightStages.asleepHours > 0.5, nightStages.asleepHours < 16 else { return nil }
                    return nightStages
                }.sorted { $0.night < $1.night }
                continuation.resume(returning: nights)
            }
            self.store.execute(query)
        }
    }

    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int) async -> [TrendPoint] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: end))!
        return await dailyAverage(id, unit: unit, start: start, end: end)
    }

    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> [TrendPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: calendar.startOfDay(for: end),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var points: [TrendPoint] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    if let value = statistics.averageQuantity()?.doubleValue(for: unit) {
                        points.append(TrendPoint(date: statistics.startDate, value: value))
                    }
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    /// Same shape as dailyAverage but sums same-day samples instead of averaging
    /// them — correct for cumulative quantities like step count.
    private func dailySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int) async -> [TrendPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: end))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: calendar.startOfDay(for: end),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var points: [TrendPoint] = []
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    if let value = statistics.sumQuantity()?.doubleValue(for: unit) {
                        points.append(TrendPoint(date: statistics.startDate, value: value))
                    }
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    private func loadRecentWorkouts(days: Int) async -> [HealthWorkout] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let heartUnit = HKUnit.count().unitDivided(by: .minute())
                let workouts = (samples as? [HKWorkout] ?? []).map { workout in
                    let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
                    let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
                    let elevation = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
                    // Running/cycling dynamics: HKWorkout.statistics(for:) only
                    // returns a value when the recording app/device associated
                    // that quantity type with this specific workout — nil
                    // otherwise, exactly like calories/distance/heart rate
                    // above, never computed or guessed here.
                    func averageStat(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
                        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
                        return workout.statistics(for: type)?.averageQuantity()?.doubleValue(for: unit)
                    }
                    // Indoor vs outdoor (a trainer ride's speed/distance often
                    // isn't comparable to a real road, so downstream code
                    // treats them differently) and pool vs open water (no
                    // current/sighting/wetsuit drag in a pool, so mixing pool
                    // and open-water pace would misrepresent race-day speed)
                    // — both nil when the recording app never set them, never
                    // inferred from activity type alone.
                    let isIndoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue
                    let swimLocation: SwimLocation? = (workout.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber)
                        .flatMap { HKWorkoutSwimmingLocationType(rawValue: $0.intValue) }
                        .flatMap { type -> SwimLocation? in
                            switch type { case .pool: return .pool; case .openWater: return .openWater; default: return nil }
                        }
                    return HealthWorkout(
                        id: workout.uuid,
                        date: workout.startDate,
                        durationMinutes: workout.duration / 60,
                        calories: workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                        distanceKilometers: Self.distanceKilometers(for: workout),
                        averageHeartRate: workout.statistics(for: heartType)?.averageQuantity()?.doubleValue(for: heartUnit),
                        maxHeartRate: workout.statistics(for: heartType)?.maximumQuantity()?.doubleValue(for: heartUnit),
                        elevationMeters: elevation,
                        activity: Self.activityName(workout.workoutActivityType),
                        muscleGroups: Self.muscles(workout.workoutActivityType),
                        source: workout.sourceRevision.source.name,
                        averagePowerWatts: averageStat(.runningPower, .watt()),
                        averageGroundContactMs: averageStat(.runningGroundContactTime, .secondUnit(with: .milli)),
                        averageVerticalOscillationCm: averageStat(.runningVerticalOscillation, .meterUnit(with: .centi)),
                        averageStrideLengthM: averageStat(.runningStrideLength, .meter()),
                        averageCyclingPowerWatts: averageStat(.cyclingPower, .watt()),
                        averageCyclingCadenceRpm: averageStat(.cyclingCadence, .count().unitDivided(by: .minute())),
                        isIndoor: isIndoor,
                        swimLocation: swimLocation
                    )
                }
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    // Real cumulative descent for a small set of recent running/cycling
    // workouts — see the elevationDescendedMeters field's own comment for
    // why this is scoped this narrowly. Runs the per-workout lookups
    // concurrently (each one is two small single-object HealthKit queries
    // plus a route read, not the heavy 365-day archive query above).
    private func loadElevationDescended(for workouts: [HealthWorkout]) async -> [UUID: Double] {
        guard !workouts.isEmpty else { return [:] }
        return await withTaskGroup(of: (UUID, Double?).self) { group in
            for workout in workouts {
                group.addTask { (workout.id, await self.elevationDescended(workoutID: workout.id)) }
            }
            var result: [UUID: Double] = [:]
            for await (id, descent) in group where descent != nil {
                result[id] = descent
            }
            return result
        }
    }

    // The actual summing math lives in RouteElevationCalculator (pure,
    // unit-tested); this is only the HealthKit plumbing to get from a
    // workout's UUID to its route's altitude sequence. nil whenever
    // there's genuinely no route (indoor session, phone-only recording,
    // older Watch without GPS) — never guessed from ascent or distance.
    private func elevationDescended(workoutID: UUID) async -> Double? {
        guard let workout = await fetchWorkout(uuid: workoutID),
              let route = await fetchRoute(for: workout) else { return nil }
        let locations = await routeLocations(route)
        guard locations.count > 1 else { return nil }
        return RouteElevationCalculator.cumulativeDescent(altitudes: locations.map(\.altitude))
    }

    // A plain HealthWorkout value carries no HealthKit reference by
    // design — refetches this one workout's real HKWorkout object by its
    // own UUID, the only way to then ask HealthKit for its route.
    private func fetchWorkout(uuid: UUID) async -> HKWorkout? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: uuid)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout])?.first)
            }
            store.execute(query)
        }
    }

    private func fetchRoute(for workout: HKWorkout) async -> HKWorkoutRoute? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute])?.first)
            }
            store.execute(query)
        }
    }

    private func routeLocations(_ route: HKWorkoutRoute) async -> [CLLocation] {
        await withCheckedContinuation { continuation in
            var collected: [CLLocation] = []
            var finished = false
            let query = HKWorkoutRouteQuery(route: route) { _, locationsOrNil, done, error in
                guard !finished else { return }
                if let locations = locationsOrNil { collected.append(contentsOf: locations) }
                if done || error != nil {
                    finished = true
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
        }
    }

    /// Reads only the classification, date, and (when present) average heart
    /// rate of each electrocardiogram — never the voltage signal itself, which
    /// would require the separate, per-sample HKElectrocardiogramQuery API that
    /// this app never calls. Harmlessly returns an empty list on any Watch
    /// without ECG hardware, or if the user never took one.
    private func loadECGHistory(days: Int) async -> [ECGReading] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .electrocardiogramType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let readings = (samples as? [HKElectrocardiogram] ?? []).map { sample in
                    ECGReading(
                        date: sample.startDate,
                        classification: Self.ecgClassificationName(sample.classification),
                        averageHeartRate: sample.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    )
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }

    nonisolated private static func ecgClassificationName(_ classification: HKElectrocardiogram.Classification) -> String {
        switch classification {
        case .sinusRhythm: return "Sinus Rhythm"
        case .atrialFibrillation: return "Atrial Fibrillation"
        case .inconclusiveLowHeartRate: return "Inconclusive (Low Heart Rate)"
        case .inconclusiveHighHeartRate: return "Inconclusive (High Heart Rate)"
        case .inconclusivePoorReading: return "Inconclusive (Poor Reading)"
        case .inconclusiveOther: return "Inconclusive (Other)"
        case .notSet: return "Not Set"
        case .unrecognized: return "Unrecognized"
        @unknown default: return "Unrecognized"
        }
    }

    // Real bpm cut points for the same 5-zone model loadHeartRateZones uses
    // (lactate-test boundaries > configured max > age-based Tanaka estimate,
    // %HRR/Karvonen anchored at resting HR) — exposed so anything that wants
    // to show a concrete "aim for X-Y bpm" target, like WorkoutPlanner's
    // running prescriptions, uses the exact same math instead of a vaguer
    // "Z1-Z2" label with no way to check it against a live pulse. Returns nil
    // only when there's no way at all to estimate a maximum (no configured
    // value and no birth date) — never a guessed number.
    func currentHeartRateZoneBoundaries() -> HeartRateZoneBoundaries? {
        if let manual = GoalStore.shared.profile.manualHeartRateZones { return manual }
        let configuredMaximum = GoalStore.shared.profile.maximumHeartRate.map(Double.init)
        let ageBasedMaximum = GoalStore.shared.profile.birthDate.map { birthDate -> Double in
            let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 40
            return 208.0 - 0.7 * Double(age)
        }
        guard let effectiveMax = configuredMaximum ?? ageBasedMaximum else { return nil }
        let recentResting = restingHeartRateHistory.suffix(14).map(\.value)
        let restingHR = recentResting.isEmpty ? Double(snapshot.restingHeartRate) : recentResting.reduce(0, +) / Double(recentResting.count)
        let reserve = max(1, effectiveMax - restingHR)
        func bound(_ fraction: Double) -> Int { Int((restingHR + reserve * fraction).rounded()) }
        return HeartRateZoneBoundaries(z1z2: bound(0.60), z2z3: bound(0.70), z3z4: bound(0.80), z4z5: bound(0.90))
    }

    private func loadHeartRateZones(workouts: [HealthWorkout], days: Int) async -> [HeartRateZone] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let relevant = workouts.filter { $0.date >= cutoff }
        guard !relevant.isEmpty else { return [] }
        let windows = relevant.map { workout in
            DateInterval(start: workout.date, duration: workout.durationMinutes * 60)
        }
        return await classifyHeartRateZones(windows: windows)
    }

    // Same classification (Karvonen %HRR against manual/configured/age-based
    // max, same as the rolling multi-day version above) but scoped to a
    // single real workout's own time window instead of every session in an
    // N-day period pooled together — what a workout detail screen actually
    // needs: "how did THIS session distribute across zones," not a blended
    // average across the last several sessions.
    func heartRateZones(for workout: HealthWorkout) async -> [HeartRateZone] {
        await classifyHeartRateZones(windows: [DateInterval(start: workout.date, duration: workout.durationMinutes * 60)])
    }

    private func classifyHeartRateZones(windows: [DateInterval]) async -> [HeartRateZone] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let samples = await quantitySamples(type: type, windows: windows)
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let observedPeak = samples.map({ $0.quantity.doubleValue(for: unit) }).max(), observedPeak > 0 else { return [] }
        // Zone boundaries measured from an actual lactate test beat any %HRmax
        // formula, since they come from this person's real blood lactate
        // curve rather than a population-average estimate — use them directly
        // as bpm cut points instead of computing a fraction of an estimated max.
        // Effective-max/resting-HR resolution and the zone cut points
        // themselves now live in HeartRateZoneClassifier — shared with
        // TrainingPlanEngine's real-intensity muscle-load scaling, so both
        // read this person's effort against the exact same thresholds.
        let manualBoundaries = GoalStore.shared.profile.manualHeartRateZones
        let effectiveMax = HeartRateZoneClassifier.effectiveMaximum(
            configured: GoalStore.shared.profile.maximumHeartRate.map(Double.init),
            birthDate: GoalStore.shared.profile.birthDate, observedPeak: observedPeak
        )
        // Plain %HRmax ignores resting heart rate entirely, which systematically
        // shrinks the "easy" zone for anyone with a low resting HR (typical of a
        // trained endurance athlete): it anchors 0% at a dead stop instead of at
        // this person's actual resting pulse. %HRR (Karvonen, ACSM's preferred
        // method over %HRmax for exactly this reason) anchors zones between rest
        // and max instead, so a genuinely easy effort no longer reads as Z3+.
        let restingHR = HeartRateZoneClassifier.restingHR(
            recentHistory: restingHeartRateHistory.suffix(14).map(\.value),
            snapshotFallback: Double(snapshot.restingHeartRate)
        )
        var seconds = Array(repeating: 0.0, count: 5)
        for (index, sample) in samples.enumerated() {
            let bpm = sample.quantity.doubleValue(for: unit)
            let zone = HeartRateZoneClassifier.zone(bpm: bpm, manualBoundaries: manualBoundaries, effectiveMax: effectiveMax, restingHR: restingHR)
            let nextDate = index + 1 < samples.count ? samples[index + 1].startDate : sample.endDate.addingTimeInterval(5)
            seconds[zone - 1] += max(1, min(30, nextDate.timeIntervalSince(sample.startDate)))
        }
        let total = seconds.reduce(0, +)
        guard total > 0 else { return [] }
        return seconds.enumerated().map { index, duration in
            HeartRateZone(zone: index + 1, percentage: duration / total * 100, minutes: duration / 60)
        }
    }

    /// Prefers the Watch's own heartRateRecoveryOneMinute sample — computed from
    /// continuous sensor data through the whole recovery window, watchOS 9+ on
    /// compatible hardware — over the manual two-point approximation this used
    /// to compute unconditionally. Falls back to that approximation only for
    /// workouts/devices that never produced a native sample, so older history
    /// doesn't just disappear.
    private func loadHeartRateRecovery(workouts: [HealthWorkout]) async -> [TrendPoint] {
        guard let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate), !workouts.isEmpty else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())

        var nativeSamples: [HKQuantitySample] = []
        if let nativeType = HKQuantityType.quantityType(forIdentifier: .heartRateRecoveryOneMinute) {
            let nativeWindows = workouts.map { workout -> DateInterval in
                let end = workout.date.addingTimeInterval(workout.durationMinutes * 60)
                return DateInterval(start: end.addingTimeInterval(-45), end: end.addingTimeInterval(15 * 60))
            }
            nativeSamples = await quantitySamples(type: nativeType, windows: nativeWindows)
        }

        let fallbackWindows = workouts.map { workout -> DateInterval in
            let end = workout.date.addingTimeInterval(workout.durationMinutes * 60)
            return DateInterval(start: end.addingTimeInterval(-45), end: end.addingTimeInterval(90))
        }
        let rawSamples = await quantitySamples(type: heartType, windows: fallbackWindows)

        return workouts.compactMap { workout -> TrendPoint? in
            let end = workout.date.addingTimeInterval(workout.durationMinutes * 60)
            let matchingNative = nativeSamples.filter { abs($0.startDate.timeIntervalSince(end)) <= 15 * 60 }
            if let closest = matchingNative.min(by: { abs($0.startDate.timeIntervalSince(end)) < abs($1.startDate.timeIntervalSince(end)) }) {
                return TrendPoint(date: workout.date, value: closest.quantity.doubleValue(for: unit))
            }
            let before = rawSamples.filter { $0.startDate >= end.addingTimeInterval(-45) && $0.startDate <= end.addingTimeInterval(10) }
            let after = rawSamples.filter { $0.startDate >= end.addingTimeInterval(45) && $0.startDate <= end.addingTimeInterval(90) }
            guard let endRate = before.map({ $0.quantity.doubleValue(for: unit) }).max(),
                  let minuteRate = after.min(by: { abs($0.startDate.timeIntervalSince(end.addingTimeInterval(60))) < abs($1.startDate.timeIntervalSince(end.addingTimeInterval(60))) })?.quantity.doubleValue(for: unit),
                  endRate > minuteRate else { return nil }
            return TrendPoint(date: workout.date, value: endRate - minuteRate)
        }.sorted { $0.date < $1.date }
    }

    /// Fetch only samples that overlap the supplied workout windows. Querying an
    /// entire month of high-frequency heart-rate data caused large transient
    /// allocations and could trigger iOS jetsam on physical devices.
    private func quantitySamples(type: HKQuantityType, windows: [DateInterval]) async -> [HKQuantitySample] {
        guard !windows.isEmpty else { return [] }
        let predicates = windows.map {
            HKQuery.predicateForSamples(withStart: $0.start, end: $0.end, options: .strictStartDate)
        }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, values, _ in
                continuation.resume(returning: values as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    // HealthKit tracks distance per discipline, not per workout — a cycling
    // workout's distance lives under distanceCycling, a swimming one under
    // distanceSwimming, never the generic distanceWalkingRunning this used
    // to read for every activity regardless of type. Tries the identifier
    // that actually matches this workout's own activity first; falls back
    // to distanceWalkingRunning (some third-party sources genuinely log an
    // outdoor ride or swim under it) and finally to the deprecated but
    // still-populated `totalDistance` for pre-iOS 11 imports — never
    // computed or guessed, only ever a real recorded sample.
    nonisolated private static func distanceKilometers(for workout: HKWorkout) -> Double? {
        var identifiers: [HKQuantityTypeIdentifier]
        switch workout.workoutActivityType {
        case .cycling: identifiers = [.distanceCycling, .distanceWalkingRunning]
        case .swimming: identifiers = [.distanceSwimming, .distanceWalkingRunning]
        default: identifiers = [.distanceWalkingRunning]
        }
        for identifier in identifiers {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            if let sum = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)), sum > 0 {
                return sum
            }
        }
        if let legacy = workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)), legacy > 0 { return legacy }
        return nil
    }

    nonisolated private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Carrera"
        case .walking: return "Caminata"
        case .hiking: return "Senderismo"
        case .highIntensityIntervalTraining: return "Intervalos de alta intensidad"
        case .traditionalStrengthTraining: return "Fuerza"
        case .functionalStrengthTraining: return "Fuerza funcional"
        case .stairClimbing: return "Escaleras"
        case .cycling: return "Ciclismo"
        // Previously fell through to the generic "Entrenamiento" default — every
        // swimming session lost its identity and couldn't be told apart from
        // anything else unclassified (the one real multi-sport gap this had).
        case .swimming: return "Natación"
        default: return "Entrenamiento"
        }
    }

    nonisolated private static func muscles(_ type: HKWorkoutActivityType) -> [String: Double] {
        switch type {
        case .running, .stairClimbing: return ["Cuádriceps": 1, "Glúteos": 0.9, "Isquios": 0.75, "Gemelos": 0.8, "Core": 0.35]
        case .highIntensityIntervalTraining: return ["Cuádriceps": 0.8, "Glúteos": 0.8, "Isquios": 0.6, "Gemelos": 0.5, "Core": 0.5]
        case .walking, .hiking: return ["Cuádriceps": 0.35, "Glúteos": 0.35, "Isquios": 0.25, "Gemelos": 0.3, "Core": 0.15]
        case .cycling: return ["Cuádriceps": 0.7, "Glúteos": 0.35, "Isquios": 0.25, "Gemelos": 0.2]
        case .swimming: return ["Espalda": 0.8, "Hombros": 0.7, "Core": 0.5, "Pecho": 0.4]
        // A Watch-logged strength session (no Hevy import behind it) carries
        // no per-exercise detail at all in HealthKit — this used to fall
        // through to the `default: [:]` case below, which meant
        // TwinEngine.calculateMuscles's healthWorkouts loop (which already
        // has real logic to absorb exactly this kind of session) always saw
        // zero involvement for every muscle and silently contributed no
        // fatigue whatsoever: a real "espalda" session read as if it never
        // happened. A generic, disclosed full-body distribution — weighted
        // toward the biggest patterns a typical session covers — beats
        // that false "nothing was trained today". Never as precise as a
        // real per-exercise Hevy import, which is the actual, honest limit
        // of what a bare activity type can tell us.
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return ["Pecho": 0.4, "Espalda": 0.4, "Hombros": 0.35, "Bíceps": 0.3, "Tríceps": 0.3,
                    "Cuádriceps": 0.35, "Glúteos": 0.35, "Isquios": 0.25, "Core": 0.35]
        default: return [:]
        }
    }

    private func enableBackgroundDelivery() {
        for sampleType in observedTypes {
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
        }
    }

    private func installObservers() {
        guard observerQueries.isEmpty else { return }
        observerQueries = observedTypes.map { sampleType in
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completion, error in
                // HealthKit expects this callback promptly; the heavier refresh happens separately.
                completion()
                guard error == nil else { return }
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            store.execute(query)
            return query
        }
    }

    private func scheduleRefresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }
}

struct TrendPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Classification and date only — the app never reads or stores the
/// electrocardiogram voltage signal itself.
struct ECGReading: Identifiable {
    var id: Date { date }
    let date: Date
    let classification: String
    let averageHeartRate: Double?
}

struct AlcoholSample: Identifiable {
    let id: UUID
    let date: Date
    let drinks: Double
    let source: String
}

struct BodyMeasurement: Identifiable {
    var id: String { sampleIDs.map(\.uuidString).joined(separator: "|") }
    let date: Date
    let weightKg: Double?
    let bodyFatPercent: Double?
    let leanMassKg: Double?
    let sampleIDs: [UUID]
    let source: String
    let sourceBundle: String
    var isOwnedByEter: Bool { sourceBundle == Bundle.main.bundleIdentifier || source.localizedCaseInsensitiveContains("eter") }
}

struct HealthWorkout: Identifiable {
    let id: UUID
    let date: Date
    let durationMinutes: Double
    let calories: Double?
    let distanceKilometers: Double?
    let averageHeartRate: Double?
    // Added later; defaulted to nil so existing call sites (tests, previews)
    // don't all need updating for fields they have no opinion about. `var`,
    // not `let`: Swift's synthesized memberwise init only exposes a defaulted
    // parameter for properties it doesn't already consider fully initialized,
    // which excludes `let` with a default — none of this is ever mutated.
    var maxHeartRate: Double? = nil
    let elevationMeters: Double?
    let activity: String
    let muscleGroups: [String: Double]
    let source: String
    // Running dynamics: only populated when the recording device associated
    // these quantity samples with the workout itself (Apple Watch Series 8+/
    // Ultra, or a paired running power accessory) — nil otherwise, never guessed.
    var averagePowerWatts: Double? = nil
    var averageGroundContactMs: Double? = nil
    var averageVerticalOscillationCm: Double? = nil
    var averageStrideLengthM: Double? = nil
    // Cycling dynamics — same "only when the recording device actually
    // associated it" rule as the running dynamics above.
    var averageCyclingPowerWatts: Double? = nil
    var averageCyclingCadenceRpm: Double? = nil
    // nil when the recording app never set the metadata key — never guessed
    // from activity type alone (an indoor trainer ride and an indoor
    // swimming pool session are both "indoor" but for very different
    // reasons, so this is a plain flag, not a location classification).
    var isIndoor: Bool? = nil
    // Pool vs open water — HealthKit's own HKWorkoutSwimmingLocationType.
    // Matters because pool pace and open-water pace aren't comparable: no
    // current/sighting/wetsuit drag in a pool, so mixing them into one
    // "personal pace" would misrepresent race-day (almost always open
    // water) speed.
    var swimLocation: SwimLocation? = nil
    // Real cumulative descent from this workout's GPS/barometric route —
    // HealthKit's own metadata only ever gives ascent (elevationMeters,
    // HKMetadataKeyElevationAscended has no descended counterpart), so
    // this is the one elevation figure this app has to derive itself
    // rather than just read. Only ever populated for a small recent
    // window of running/cycling workouts (see HealthStore.
    // loadElevationDescended) — a per-workout route query is expensive
    // enough that fetching it for a full year of history the way every
    // other field here is loaded would meaningfully slow every refresh
    // for a number nothing outside today's muscle-load scaling uses yet.
    // nil means "not fetched" here, not "no descent" — never guessed.
    var elevationDescendedMeters: Double? = nil
}

enum SwimLocation: String, Codable {
    case pool = "Piscina"
    case openWater = "Aguas abiertas"
}

struct HeartRateZone: Identifiable {
    var id: Int { zone }
    let zone: Int
    let percentage: Double
    let minutes: Double
}

// One real night's bedtime/wake time — distinct from `sleepHistory`
// (TrendPoint, duration only) and from `sleepStages` (stage breakdown, but
// only ever the most recent night). Needed to measure schedule
// *regularity* over time: how consistently this person goes to bed and
// wakes up, not just how long they slept. `bedtime`/`wakeTime` come from
// the first/last real asleep-stage sample for that night (not "in bed",
// which can include time spent awake on a phone before actually falling
// asleep) from whichever source recorded the most staged sleep that
// night — same "most staged seconds wins" source disambiguation
// `sleepBreakdown()` already uses for the latest night, applied per night.
struct NightlySleepSchedule {
    // The calendar day the sleep session ended on — the same "attribute to
    // the morning it ended on" convention sleepDurationHistory already uses.
    let night: Date
    let bedtime: Date
    let wakeTime: Date
}

struct SleepStages {
    let awakeHours: Double
    let coreHours: Double
    let deepHours: Double
    let remHours: Double
    let unspecifiedHours: Double
    let startDate: Date?
    let endDate: Date?
    var asleepHours: Double { coreHours + deepHours + remHours + unspecifiedHours }
    static let empty = SleepStages(
        awakeHours: 0, coreHours: 0, deepHours: 0, remHours: 0,
        unspecifiedHours: 0, startDate: nil, endDate: nil
    )
}

// The per-night counterpart to SleepStages above (which only ever holds
// the most recent night). SleepArchitectureEngine needs several nights
// of the real deep/REM/core split, not just last night's, to say
// anything about a pattern rather than one sample.
struct NightlySleepStages: Identifiable {
    var id: Date { night }
    let night: Date
    let deepHours: Double
    let remHours: Double
    let coreHours: Double
    let unspecifiedHours: Double
    // Awake time recorded *within* the sleep session (real awakenings),
    // not the gap before falling asleep — the same kind of continuity
    // signal sleep-efficiency captures, just without a separate
    // "in bed" timestamp to divide by.
    let awakeHours: Double
    var asleepHours: Double { deepHours + remHours + coreHours + unspecifiedHours }
    // Some nights (older Watch data, or phone-only tracking) never get a
    // real deep/REM split — everything lands in "unspecified". Averaging
    // those in would silently dilute the architecture signal with nights
    // that say nothing about architecture at all.
    var hasStageSplit: Bool { deepHours + remHours > 0 }
}

struct HealthSnapshot {
    let steps: Int
    let activeEnergy: Int
    let exerciseMinutes: Int
    let heartRate: Int
    let restingHeartRate: Int
    let hrv: Int
    let sleepHours: Double

    static let empty = HealthSnapshot(steps: 0, activeEnergy: 0, exerciseMinutes: 0, heartRate: 0, restingHeartRate: 0, hrv: 0, sleepHours: 0)
}
