import Foundation
import HealthKit

/// Puente mínimo HealthKit → App Group para el widget. No calcula el gemelo ni
/// abre históricos: sólo publica muestras reales de HRV y pulso cuando iOS
/// despierta la app en segundo plano.
@MainActor
final class BackgroundVitalsObserver {
    private final class CompletionBox: @unchecked Sendable {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }
    private let store = HKHealthStore()
    private var queries: [HKObserverQuery] = []

    func start() {
        guard HKHealthStore.isHealthDataAvailable(), queries.isEmpty else { return }
        let types = [
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)
        ].compactMap { $0 }

        queries = types.map { type in
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil, let self else { completion(); return }
                let completionBox = CompletionBox(completion)
                Task { @MainActor [weak self] in
                    guard let self else { completionBox.call(); return }
                    await self.publishCurrentVitals()
                    // HealthKit conserva tiempo de ejecución hasta comunicar
                    // que el dato real ya se procesó.
                    completionBox.call()
                }
            }
            store.execute(query)
            let frequency: HKUpdateFrequency = type.identifier == HKQuantityTypeIdentifier.heartRate.rawValue
                ? .hourly : .immediate
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
            return query
        }
    }

    private func publishCurrentVitals() async {
        let start = Calendar.current.startOfDay(for: Date())
        let hrv = await latest(.heartRateVariabilitySDNN)
        let resting = await latest(.restingHeartRate)
        let pulse = await samples(.heartRate, from: start)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hrvValue = hrv.map { Int($0.quantity.doubleValue(for: .secondUnit(with: .milli)).rounded()) }
        let restingValue = resting.map { Int($0.quantity.doubleValue(for: bpm).rounded()) }
        let points = EnergyTimelineEngine.heartRatePoints(
            samples: pulse.map { TrendPoint(date: $0.startDate, value: $0.quantity.doubleValue(for: bpm)) },
            day: Date(), through: EnergyTimelineEngine.hour(of: Date(), on: Date())
        ).map { EterWidgetHeartRatePoint(hour: $0.hour, bpm: $0.bpm, segment: $0.segment) }
        await WidgetSnapshotStore.updateVitals(
            hrv: hrvValue, restingHeartRate: restingValue,
            heartRatePoints: points
        )
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier) async -> HKQuantitySample? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKQuantitySample)
            }
            store.execute(query)
        }
    }

    private func samples(_ identifier: HKQuantityTypeIdentifier, from start: Date) async -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 2_000,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }
}
