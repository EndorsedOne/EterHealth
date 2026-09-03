import SwiftUI

// Tapping a row in "Últimos entrenamientos" used to do nothing — the row
// itself had no detail to show, only a "Valorar" (RPE review) shortcut and
// a delete button. This is the actual per-session summary: real HealthKit
// data (distance, pace, calories, heart rate, elevation, running/cycling
// dynamics, and — new — a per-SESSION heart rate zone breakdown, not the
// rolling multi-day blend the rest of the app uses) for a run/ride/swim,
// or the full exercise-by-exercise, set-by-set breakdown for a Hevy
// strength session.
struct WorkoutDetailView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var workoutEnrichments: WorkoutEnrichmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingMachineData = false
    let session: RecentTrainingSession

    private var healthWorkout: HealthWorkout? {
        session.healthWorkoutID.flatMap { id in health.recentWorkouts.first { $0.id == id } }
    }
    private var importedWorkout: ImportedWorkout? {
        session.importedWorkoutID.flatMap { id in imports.workouts.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let workout = healthWorkout {
                        healthDetail(workout)
                    } else if let workout = importedWorkout {
                        strengthDetail(workout)
                    } else {
                        Text("Este entrenamiento ya no está disponible — puede haberse eliminado o restaurado desde otra copia de seguridad.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 40)
                    }
                }.padding(18)
            }
            .background(EterTheme.canvas)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .sheet(isPresented: $editingMachineData) {
                if let workout = healthWorkout {
                    RowingEnrichmentEditor(
                        workout: workout,
                        existing: workoutEnrichments.enrichment(for: workout.id)
                    ).environmentObject(workoutEnrichments)
                }
            }
        }
    }

    // MARK: - Running/cardio/swim (HealthKit)

    @ViewBuilder private func healthDetail(_ workout: HealthWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard(date: workout.date, source: workout.source)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                tile("Duración", "\(Int(workout.durationMinutes.rounded())) min")
                if let distance = workout.distanceKilometers, distance > 0 {
                    tile("Distancia", "\(distance.formatted(.number.precision(.fractionLength(1...2)))) km")
                    if workout.durationMinutes > 0 {
                        tile("Ritmo medio", "\(DecisionSimulatorEngine.formatPace(workout.durationMinutes / distance))/km")
                    }
                }
                if let calories = workout.calories, calories > 0 {
                    tile("Calorías", "\(Int(calories.rounded())) kcal")
                }
                if let avgHR = workout.averageHeartRate, avgHR > 0 {
                    tile("FC media", "\(Int(avgHR.rounded())) ppm")
                }
                if let maxHR = workout.maxHeartRate, maxHR > 0 {
                    tile("FC máxima", "\(Int(maxHR.rounded())) ppm")
                }
                if let elevation = workout.elevationMeters, elevation > 0 {
                    tile("Desnivel", "\(Int(elevation.rounded())) m")
                }
            }
        }.cardStyle()
        if let context = deviceContext(workout) {
            Text(context).font(.caption).foregroundStyle(.secondary)
        }
        if hasRunningDynamics(workout) { runningDynamicsCard(workout) }
        if hasCyclingDynamics(workout) { cyclingDynamicsCard(workout) }
        if workout.activity == "Remo indoor" { rowingMachineCard(workout) }
        HeartRateZonesCard(workout: workout).environmentObject(health)
    }

    private func rowingMachineCard(_ workout: HealthWorkout) -> some View {
        let enrichment = workoutEnrichments.enrichment(for: workout.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Datos de la máquina").font(.subheadline.bold())
                    Text("Completa lo que Apple Fitness no registra")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(enrichment == nil ? "Añadir" : "Editar") { editingMachineData = true }
                    .font(.caption.bold())
            }
            if let enrichment {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if let meters = enrichment.distanceMeters { tile("Distancia máquina", "\(Int(meters.rounded())) m") }
                    if let seconds = enrichment.effectiveDurationSeconds { tile("Tiempo efectivo", durationText(seconds)) }
                    if let watts = enrichment.averagePowerWatts { tile("Potencia media", "\(Int(watts.rounded())) W") }
                    if let cadence = enrichment.cadenceSPM { tile("Cadencia", "\(Int(cadence.rounded())) spm") }
                    if let level = enrichment.resistanceLevel { tile("Resistencia", "\(level.formatted(.number.precision(.fractionLength(0...1))))/10") }
                    if let effort = enrichment.perceivedEffort { tile("Esfuerzo", "RPE \(effort)/10") }
                }
                Text("\(enrichment.machine.rawValue) · \(enrichment.resistanceMode.rawValue)\(enrichment.useForHyrox ? " · referencia HYROX" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Puedes añadir distancia, potencia, cadencia y resistencia sin modificar ni duplicar el entrenamiento guardado en Apple Salud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func deviceContext(_ workout: HealthWorkout) -> String? {
        var parts: [String] = []
        if let isIndoor = workout.isIndoor { parts.append(isIndoor ? "Sesión indoor" : "Sesión al aire libre") }
        if let swimLocation = workout.swimLocation { parts.append(swimLocation.rawValue) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func hasRunningDynamics(_ workout: HealthWorkout) -> Bool {
        workout.averagePowerWatts != nil || workout.averageGroundContactMs != nil
            || workout.averageVerticalOscillationCm != nil || workout.averageStrideLengthM != nil
    }
    private func runningDynamicsCard(_ workout: HealthWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dinámica de carrera").font(.subheadline.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let power = workout.averagePowerWatts { tile("Potencia media", "\(Int(power.rounded())) W") }
                if let contact = workout.averageGroundContactMs { tile("Contacto suelo", "\(Int(contact.rounded())) ms") }
                if let oscillation = workout.averageVerticalOscillationCm { tile("Oscilación vertical", "\(oscillation.formatted(.number.precision(.fractionLength(1)))) cm") }
                if let stride = workout.averageStrideLengthM { tile("Zancada", "\(stride.formatted(.number.precision(.fractionLength(2)))) m") }
            }
        }.cardStyle()
    }

    private func hasCyclingDynamics(_ workout: HealthWorkout) -> Bool {
        workout.averageCyclingPowerWatts != nil || workout.averageCyclingCadenceRpm != nil
    }
    private func cyclingDynamicsCard(_ workout: HealthWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dinámica de ciclismo").font(.subheadline.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let power = workout.averageCyclingPowerWatts { tile("Potencia media", "\(Int(power.rounded())) W") }
                if let cadence = workout.averageCyclingCadenceRpm { tile("Cadencia", "\(Int(cadence.rounded())) rpm") }
            }
        }.cardStyle()
    }

    // MARK: - Strength (Hevy)

    @ViewBuilder private func strengthDetail(_ workout: ImportedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard(date: workout.start, source: "Hevy")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                tile("Duración", "\(Int((workout.end.timeIntervalSince(workout.start) / 60).rounded())) min")
                tile("Series", "\(workout.exercises.reduce(0) { $0 + $1.sets })")
                tile("Volumen", "\(Int(workout.exercises.reduce(0.0) { $0 + $1.volume }.rounded()).formatted()) kg")
            }
        }.cardStyle()
        let muscles = workout.effectiveMuscleSets.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        if !muscles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Distribución muscular").font(.subheadline.bold())
                ForEach(muscles, id: \.key) { muscle, sets in
                    HStack {
                        Text(muscle).font(.caption)
                        Spacer()
                        Text("\(sets.formatted(.number.precision(.fractionLength(0...1)))) series efectivas")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.cardStyle()
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Ejercicios").font(.subheadline.bold())
            ForEach(Array(workout.exercises.enumerated()), id: \.offset) { _, exercise in
                exerciseCard(exercise)
            }
        }
    }

    private func exerciseCard(_ exercise: ImportedExercise) -> some View {
        let details = exercise.setDetails ?? []
        let warmupIndices = StrengthProgressEngine.warmupIndices(details)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ExerciseVisualView(exercise: exercise.name, size: 28)
                Text(exercise.name).font(.subheadline.bold())
            }
            if details.isEmpty {
                Text("\(exercise.sets) series\(exercise.averageWeight.map { " · \($0.formatted(.number.precision(.fractionLength(0...1)))) kg de media" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(details.enumerated()), id: \.offset) { index, set in
                    let isWarmup = warmupIndices.contains(index)
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                        Text("\(set.weight.formatted(.number.precision(.fractionLength(0...1)))) kg × \(set.reps)")
                            .font(.caption).monospacedDigit()
                        if let rpe = set.rpe {
                            Text("RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isWarmup {
                            Text("Calentamiento").font(.caption2.bold()).foregroundStyle(EterTheme.warning)
                        }
                    }
                }
            }
        }.cardStyle()
    }

    // MARK: - Shared

    private func headerCard(date: Date, source: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.bold())
                Text(source).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // Was cardStyle() per tile — inside runningDynamicsCard/
    // cyclingDynamicsCard that meant a shadowed card nested inside another
    // shadowed card for every single stat. eterInsetStyle() is the same
    // "tile living inside a card" treatment WeekAheadStripView already
    // uses elsewhere, instead of reinventing a third look here.
    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.bold()).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).eterInsetStyle()
    }
}

private struct RowingEnrichmentEditor: View {
    @EnvironmentObject private var store: WorkoutEnrichmentStore
    @Environment(\.dismiss) private var dismiss
    let workout: HealthWorkout
    let existing: WorkoutEnrichment?

    @State private var machine: WorkoutMachine
    @State private var mode: RowingResistanceMode
    @State private var distance: String
    @State private var duration: String
    @State private var power: String
    @State private var cadence: String
    @State private var resistance: String
    @State private var effort: Int
    @State private var useForHyrox: Bool
    @State private var note: String

    init(workout: HealthWorkout, existing: WorkoutEnrichment?) {
        self.workout = workout
        self.existing = existing
        _machine = State(initialValue: existing?.machine ?? .technogymSkillrow)
        _mode = State(initialValue: existing?.resistanceMode ?? .aquaFeel)
        _distance = State(initialValue: existing?.distanceMeters.map { String(Int($0.rounded())) } ?? "")
        _duration = State(initialValue: existing?.effectiveDurationSeconds.map(Self.formatDuration) ?? "")
        _power = State(initialValue: existing?.averagePowerWatts.map { String(Int($0.rounded())) } ?? "")
        _cadence = State(initialValue: existing?.cadenceSPM.map { String(Int($0.rounded())) } ?? "")
        _resistance = State(initialValue: existing?.resistanceLevel.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
        _effort = State(initialValue: existing?.perceivedEffort ?? 5)
        _useForHyrox = State(initialValue: existing?.useForHyrox ?? true)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Máquina") {
                    Picker("Equipo", selection: $machine) {
                        ForEach(WorkoutMachine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Modo de resistencia", selection: $mode) {
                        ForEach(RowingResistanceMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    numericField("Nivel de resistencia (1–10)", text: $resistance, suffix: nil)
                }
                Section("Resultado") {
                    numericField("Distancia", text: $distance, suffix: "m")
                    TextField("Tiempo efectivo (mm:ss)", text: $duration)
                        .keyboardType(.numbersAndPunctuation)
                    numericField("Potencia media", text: $power, suffix: "W")
                    numericField("Cadencia", text: $cadence, suffix: "spm")
                    Stepper("Esfuerzo percibido: \(effort)/10", value: $effort, in: 1...10)
                }
                Section {
                    Toggle("Usar como referencia para HYROX", isOn: $useForHyrox)
                    Text("Éter la reconocerá como evidencia de remo. No la tratará como una simulación completa ni inventará el comportamiento del trineo o la carrera.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Notas") { TextField("Sensaciones, técnica o configuración", text: $note, axis: .vertical) }
                if existing != nil {
                    Section {
                        Button("Borrar datos añadidos", role: .destructive) {
                            store.delete(workoutID: workout.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Completar remo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar", action: save).bold() }
            }
        }
    }

    @ViewBuilder private func numericField(_ title: String, text: Binding<String>, suffix: String?) -> some View {
        HStack {
            TextField(title, text: text).keyboardType(.decimalPad)
            if let suffix { Text(suffix).foregroundStyle(.secondary) }
        }
    }

    private func save() {
        let enrichment = WorkoutEnrichment(
            workoutID: workout.id.uuidString, workoutDate: workout.date,
            machine: machine, resistanceMode: mode,
            resistanceLevel: boundedNumber(resistance, range: 1...10),
            distanceMeters: positiveNumber(distance),
            effectiveDurationSeconds: parseDuration(duration),
            averagePowerWatts: positiveNumber(power), cadenceSPM: positiveNumber(cadence),
            perceivedEffort: effort, useForHyrox: useForHyrox,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines), updatedAt: Date()
        )
        store.save(enrichment)
        dismiss()
    }

    private func positiveNumber(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return value
    }

    private func boundedNumber(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard let value = positiveNumber(text), range.contains(value) else { return nil }
        return value
    }

    private func parseDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return positiveNumber(text).map { $0 * 60 }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// Loaded on demand (not eagerly for every session in the list) — real
// per-session zone classification straight from HealthKit's own heart
// rate samples for exactly this workout's time window, the same Karvonen
// %HRR math HealthStore's rolling multi-day version already uses, scoped
// to one session instead of blending several together.
private struct HeartRateZonesCard: View {
    @EnvironmentObject private var health: HealthStore
    let workout: HealthWorkout
    @State private var zones: [HeartRateZone]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zonas cardíacas de esta sesión").font(.subheadline.bold())
            switch zones {
            case nil:
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            case .some(let zones) where zones.isEmpty:
                Text("Sin muestras de frecuencia cardíaca para esta sesión.").font(.caption).foregroundStyle(.secondary)
            case .some(let zones):
                ForEach(zones.sorted { $0.zone < $1.zone }) { zone in
                    HStack(spacing: 8) {
                        Text("Z\(zone.zone)").font(.caption.bold()).frame(width: 22, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 8)
                            Capsule().fill(zoneColor(zone.zone)).frame(width: max(3, geo.size.width * zone.percentage / 100), height: 8)
                        }.frame(height: 8)
                        Text("\(Int(zone.percentage.rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .cardStyle()
        .task {
            guard zones == nil else { return }
            zones = await health.heartRateZones(for: workout)
        }
    }

    // Same 5-zone color convention the Watch app's own live session view uses.
    private func zoneColor(_ zone: Int) -> Color {
        switch zone { case 1: return .cyan; case 2: return .blue; case 3: return .green; case 4: return .orange; default: return .red }
    }
}
