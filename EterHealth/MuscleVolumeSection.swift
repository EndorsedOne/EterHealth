import SwiftUI
import Charts

/// Distribución muscular (radar fuerza + capa de cardio) y volumen de fuerza
/// semanal. Vive en la pestaña Fuerza, que es su sitio temático — antes estaba
/// suelto en Rendimiento. Componente propio para que Fuerza lo componga sin
/// arrastrar toda la lógica de ContentView.
struct MuscleVolumeSection: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -10, to: now)!
        let previousStart = calendar.date(byAdding: .day, value: -20, to: now)!
        let current = combinedMuscleDistribution(from: start, to: now)
        let previous = combinedMuscleDistribution(from: previousStart, to: start)
        let cardio = cardioMuscleStimulus(from: start, to: now)
        let hasCardio = cardio.values.contains { $0 > 0 }
        let volume = imports.weeklyVolume()
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { VStack(alignment: .leading) { Text("Distribución muscular").font(.headline); Text("Series de fuerza (Hevy + Apple Salud) · últimos 10 días frente a los 10 anteriores").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                MuscleRadar(current: current, previous: previous, cardio: cardio, periodDays: 10).frame(height: 285)
                HStack(spacing: 16) {
                    Label("Actual", systemImage: "circle.fill").foregroundStyle(.blue)
                    Label("Anterior", systemImage: "circle.fill").foregroundStyle(.gray)
                    if hasCardio { Label("Cardio", systemImage: "circle.dashed").foregroundStyle(.orange) }
                }.font(.caption).frame(maxWidth: .infinity)
                if hasCardio {
                    let legCardio = cardio["Piernas"] ?? 0
                    let legPercent = Int((legCardio / MuscleRadar.cardioReference("Piernas", periodDays: 10) * 100).rounded())
                    Text("El % de cada eje cuenta sólo fuerza. El radio naranja muestra la carga musculoesquelética del cardio con su propia referencia: piernas \(legPercent)%. Correr carga la pierna, pero no se acredita como volumen de hipertrofia.")
                        .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                }
            }.cardStyle()
            VStack(alignment: .leading, spacing: 12) {
                Text("Volumen de fuerza").font(.headline)
                Text("Carga total semanal: peso × repeticiones").font(.caption).foregroundStyle(.secondary)
                if volume.isEmpty { Text("Importa una exportación de Hevy para ver el histórico.").font(.caption).foregroundStyle(.secondary).frame(height: 80) }
                else {
                    Chart(volume) { point in
                        BarMark(x: .value("Semana", point.date, unit: .weekOfYear), y: .value("Volumen", point.value))
                            .foregroundStyle(EterTheme.positive.gradient).cornerRadius(3)
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.10)); AxisValueLabel() } }
                    .frame(height: 165)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Volumen semanal de fuerza")
                    .accessibilityValue(volume.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \(Int($0.value.rounded())) kilogramos de volumen" }.joined(separator: ". "))
                }
            }.cardStyle()
        }
    }

    private func combinedMuscleDistribution(from start: Date, to end: Date) -> [String: Double] {
        var result = imports.muscleDistribution(from: start, to: end)
        for workout in health.recentWorkouts where workout.date >= start && workout.date < end {
            // Evita el doble conteo del resumen que Hevy/éter también escriben en
            // HealthKit (ver isHealthKitMirror) y restringe el conteo de series a
            // trabajo de FUERZA: el cardio carga la pierna pero no produce series
            // de hipertrofia (ese estímulo va como capa aparte, abajo).
            guard !workout.source.localizedCaseInsensitiveContains("hevy"), !imports.isHealthKitMirror(workout) else { continue }
            guard workout.activity == "Fuerza" || workout.activity == "Fuerza funcional" else { continue }
            let equivalentSets = max(1, workout.durationMinutes / 5)
            for (muscle, involvement) in workout.muscleGroups {
                result[muscleBucket(muscle), default: 0] += equivalentSets * involvement
            }
        }
        return result
    }

    private func muscleBucket(_ muscle: String) -> String {
        switch muscle {
        case "Cuádriceps", "Glúteos", "Isquios", "Gemelos": return "Piernas"
        case "Bíceps", "Tríceps": return "Brazos"
        default: return muscle
        }
    }

    // Estímulo de PIERNA (y core) que la carrera, el ciclismo y el senderismo
    // dejan de verdad, en series-equivalentes, dibujado como capa aparte en el
    // radar. NO entra en combinedMuscleDistribution (ese cuenta hipertrofia);
    // reutiliza el mismo modelo de fatiga del gemelo (cardioMuscleLoad) para no
    // mezclar ni contar doble.
    private func cardioMuscleStimulus(from start: Date, to end: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        for workout in health.recentWorkouts where workout.date >= start && workout.date < end {
            guard !imports.isHealthKitMirror(workout) else { continue }
            let kind: PlannedSessionKind?
            switch workout.activity {
            case "Carrera": kind = workout.durationMinutes >= 75 ? .longRun : .easyRun
            case "Ciclismo": kind = .bike
            case "Senderismo": kind = .easyRun
            default: kind = nil
            }
            guard let kind else { continue }
            let load = TrainingPlanEngine.cardioMuscleLoad(
                for: kind,
                durationMinutes: workout.durationMinutes,
                elevationMeters: workout.elevationMeters ?? 0,
                elevationDescendedMeters: workout.elevationDescendedMeters ?? 0
            )
            for (muscle, sets) in load { result[muscleBucket(muscle), default: 0] += sets }
        }
        return result
    }
}
