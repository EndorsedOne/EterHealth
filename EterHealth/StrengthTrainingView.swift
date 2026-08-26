import SwiftUI
import Charts

struct StrengthRoutine: Identifiable, Codable {
    var id: String { name }
    let name: String
    let subtitle: String
    let exercises: [RoutineExercise]
    let lastPerformed: Date?
    let historicalVolume: Double
}

struct RoutineExercise: Identifiable, Codable {
    var id: String { name }
    var name: String
    var sets: [ImportedSet]
    var restSeconds: Int
    var prescriptionNote: String?
    var historySessions: Int?

    init(name: String, sets: [ImportedSet], restSeconds: Int, prescriptionNote: String? = nil, historySessions: Int? = nil) {
        self.name = name
        self.sets = sets
        self.restSeconds = restSeconds
        self.prescriptionNote = prescriptionNote
        self.historySessions = historySessions
    }
}

@MainActor
enum StrengthRoutineBuilder {
    static func applyingVolumeFactor(_ routine: StrengthRoutine, factor: Double) -> StrengthRoutine {
        guard factor < 0.95 else { return routine }
        let exercises = routine.exercises.map { exercise in
            var adjusted = exercise
            let count = max(1, Int((Double(exercise.sets.count) * factor).rounded()))
            adjusted.sets = Array(exercise.sets.prefix(count))
            let deloadNote = "Descarga: \(Int((factor * 100).rounded()))% del volumen habitual"
            adjusted.prescriptionNote = [exercise.prescriptionNote, deloadNote].compactMap { $0 }.joined(separator: " · ")
            return adjusted
        }
        return StrengthRoutine(name: routine.name, subtitle: routine.subtitle, exercises: exercises,
                               lastPerformed: routine.lastPerformed, historicalVolume: routine.historicalVolume)
    }

    static func routines(from imports: ImportStore) -> [StrengthRoutine] {
        [
            build("Push", matches: ["push", "empuje"], fallback: ["Bench Press (Barbell)", "Standing Military Press (Barbell)", "Incline Bench Press (Dumbbell)", "Lateral Raise (Dumbbell)", "Triceps Extension (Cable)"], imports: imports),
            build("Pull", matches: ["pull", "tirón", "tiron"], fallback: ["Deadlift (Barbell)", "Lat Pulldown (Cable)", "Seated Cable Row", "Pull Up", "Biceps Curl (Dumbbell)"], imports: imports),
            build("Pierna", matches: ["pierna", "leg"], fallback: ["Squat (Barbell)", "Leg Press (Machine)", "Romanian Deadlift (Barbell)", "Leg Extension (Machine)", "Leg Curl (Machine)"], imports: imports),
            build("Full Body", matches: ["full body", "fullbody"], fallback: ["Squat (Barbell)", "Bench Press (Barbell)", "Pull Up", "Romanian Deadlift (Barbell)", "Standing Military Press (Barbell)"], imports: imports)
        ]
    }

    static func exerciseLibrary(from imports: ImportStore) -> [RoutineExercise] {
        var seen = Set<String>()
        var result: [RoutineExercise] = []
        for workout in imports.workouts.sorted(by: { $0.start > $1.start }) {
            for exercise in workout.exercises where seen.insert(exercise.name).inserted {
                result.append(routineExercise(exercise))
            }
        }
        for descriptor in ExerciseCatalog.descriptors where seen.insert(descriptor.name).inserted {
            result.append(RoutineExercise(name: descriptor.name, sets: defaultSets, restSeconds: defaultRest(for: descriptor.pattern)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func personalized(_ routine: StrengthRoutine, imports: ImportStore, readiness: Int, muscles: [MuscleReadiness]) -> StrengthRoutine {
        let injuries = InjuryStore.shared.active
        let exercises = routine.exercises.compactMap {
            StrengthPrescriptionEngine.prescribe(
                $0, workouts: imports.workouts, readiness: readiness,
                muscleReadiness: muscles, injuries: injuries, goals: GoalStore.shared.profile.goals
            )
        }
        return StrengthRoutine(name: routine.name, subtitle: exercises.map(\.name).joined(separator: " · "), exercises: exercises,
                               lastPerformed: routine.lastPerformed, historicalVolume: routine.historicalVolume)
    }

    static func routine(from proposed: ProposedWorkout, imports: ImportStore, readiness: Int, muscles: [MuscleReadiness]) -> StrengthRoutine {
        let library = exerciseLibrary(from: imports)
        let injuries = InjuryStore.shared.active
        let exercises = proposed.exercises.compactMap { proposedExercise -> RoutineExercise? in
            guard InjurySafetyEngine.exerciseSafety(proposedExercise.name, injuries: injuries).allowed else { return nil }
            if let historical = library.first(where: {
                $0.name.localizedCaseInsensitiveCompare(proposedExercise.name) == .orderedSame
            }) {
                return StrengthPrescriptionEngine.prescribe(
                    historical, workouts: imports.workouts,
                    readiness: readiness, muscleReadiness: muscles, injuries: injuries, goals: GoalStore.shared.profile.goals
                )
            }
            let numbers = proposedExercise.prescription.split { !$0.isNumber }.compactMap { Int($0) }
            let setCount = min(6, max(1, numbers.first ?? 3))
            let reps = max(1, numbers.dropFirst().first ?? (proposedExercise.prescription.contains("s") ? 30 : 10))
            let descriptor = ExerciseCatalog.descriptor(for: proposedExercise.name)
            return RoutineExercise(
                name: proposedExercise.name,
                sets: (0..<setCount).map { _ in ImportedSet(weight: 0, reps: reps, type: "normal", rpe: nil) },
                restSeconds: defaultRest(for: descriptor.pattern),
                prescriptionNote: proposedExercise.cue,
                historySessions: 0
            )
        }
        return StrengthRoutine(
            name: proposed.title,
            subtitle: exercises.map(\.name).joined(separator: " · "),
            exercises: exercises,
            lastPerformed: nil,
            historicalVolume: 0
        )
    }

    static func recommendations(for routineName: String, excluding: Set<String>, imports: ImportStore) -> [RoutineExercise] {
        let target: Set<String>
        switch routineName.lowercased() {
        case let name where name.contains("push"):
            target = ["Pecho", "Hombros", "Tríceps"]
        case let name where name.contains("pull"):
            target = ["Espalda", "Bíceps"]
        case let name where name.contains("pierna"):
            target = ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"]
        default:
            target = ["Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps", "Cuádriceps", "Glúteos", "Isquios", "Core"]
        }
        let activeInjuries = InjuryStore.shared.active
        let library = exerciseLibrary(from: imports).filter {
            !excluding.contains($0.name) && InjurySafetyEngine.exerciseSafety($0.name, injuries: activeInjuries).allowed
        }
        let frequency = Dictionary(grouping: imports.workouts.flatMap(\.exercises), by: \.name).mapValues(\.count)
        return library.sorted { left, right in
            let leftMatch = Set(MuscleMap.groups(for: left.name)).intersection(target).count
            let rightMatch = Set(MuscleMap.groups(for: right.name)).intersection(target).count
            if leftMatch != rightMatch { return leftMatch > rightMatch }
            return frequency[left.name, default: 0] > frequency[right.name, default: 0]
        }
    }

    private static func build(_ name: String, matches: [String], fallback: [String], imports: ImportStore) -> StrengthRoutine {
        let matching = imports.workouts.filter { workout in
            let title = workout.title.lowercased()
            return matches.contains { title.contains($0) }
        }.sorted { $0.start > $1.start }
        let latest = matching.first
        let exercises: [RoutineExercise]
        if let latest {
            exercises = latest.exercises.map(routineExercise)
        } else {
            let library = exerciseLibrary(from: imports)
            exercises = fallback.map { wanted in
                library.first { $0.name.localizedCaseInsensitiveContains(wanted.components(separatedBy: " (").first ?? wanted) }
                    ?? RoutineExercise(name: wanted, sets: defaultSets, restSeconds: 120)
            }
        }
        let volume = latest?.exercises.reduce(0) { $0 + $1.volume } ?? 0
        return StrengthRoutine(name: name, subtitle: exercises.map(\.name).joined(separator: " · "), exercises: exercises, lastPerformed: latest?.start, historicalVolume: volume)
    }

    private static func routineExercise(_ exercise: ImportedExercise) -> RoutineExercise {
        let details = exercise.setDetails?.filter { $0.reps > 0 } ?? []
        let fallbackReps = max(1, (exercise.totalReps ?? exercise.sets * 8) / max(exercise.sets, 1))
        let sets = details.isEmpty
            ? (0..<max(1, exercise.sets)).map { _ in ImportedSet(weight: exercise.averageWeight ?? 0, reps: fallbackReps, type: "normal", rpe: nil) }
            : details
        return RoutineExercise(name: exercise.name, sets: sets, restSeconds: 120)
    }

    private static var defaultSets: [ImportedSet] {
        (0..<3).map { _ in ImportedSet(weight: 0, reps: 10, type: "normal", rpe: nil) }
    }

    private static func defaultRest(for pattern: String) -> Int {
        pattern.contains("Aislamiento") ? 75 : pattern.contains("Core") ? 60 : 120
    }
}

// Chaining several independent `.sheet` modifiers on the same view is
// unreliable in practice — SwiftUI can end up only presenting the first (or
// silently dropping the others) once multiple `isPresented`/`item` sheets
// share one view's modifier chain, so a tap that sets one of those state
// vars can just... do nothing. This app had three separate ones here
// (selectedRoutine, editingRoutine, showDayProposal); folding them into a
// single `.sheet(item:)` keyed by this enum keeps exactly one sheet
// presentation attached to this view, which is the configuration SwiftUI
// actually handles correctly.
private enum StrengthSheet: Identifiable {
    case liveWorkout(StrengthRoutine)
    case editRoutine(StrengthRoutine)
    case dayProposal

    var id: String {
        switch self {
        case .liveWorkout(let routine): return "live-\(routine.id)"
        case .editRoutine(let routine): return "edit-\(routine.id)"
        case .dayProposal: return "dayProposal"
        }
    }
}

struct StrengthTrainingView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var routineStore: StrengthRoutineStore
    @EnvironmentObject private var checkIns: DailyCheckInStore
    @EnvironmentObject private var goals: GoalStore
    @State private var activeSheet: StrengthSheet?
    @State private var selectedProgressExercise = ""

    var body: some View {
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIns.entry(),
                                           context: TwinContext(profile: goals.profile, events: LifestyleFactorStore.shared.events,
                                                                reviews: WorkoutReviewStore.shared.reviews, activeInjuries: InjuryStore.shared.active,
                                                                calibration: TwinStateStore.shared.calibration,
                                                                personalAnchor: TwinStateStore.shared.personalAnchor()))
        let automatic = StrengthRoutineBuilder.routines(from: imports)
        let routines = automatic.map {
            StrengthRoutineBuilder.personalized(routineStore.routine(named: $0.name) ?? $0, imports: imports,
                                                readiness: assessment.score, muscles: assessment.muscles)
        }
        VStack(alignment: .leading, spacing: 18) {
            EterPageHeader(eyebrow: "Fuerza", title: "Entrena y progresa")
            VStack(alignment: .leading, spacing: 5) {
                Text("Éter parte de tu historial").font(.headline)
                Text("Las series se calculan con hasta cinco sesiones, tu recuperación muscular, disponibilidad y tiempo sin practicar el ejercicio. Todo sigue siendo editable.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.cardStyle()

            strengthProgressSection

            ForEach(routines) { routine in routineCard(routine, customized: routineStore.routine(named: routine.name) != nil) }

            Button {
                activeSheet = .dayProposal
            } label: {
                HStack { Image(systemName: "sparkles"); Text("Crear entrenamiento del día"); Spacer() }
            }.buttonStyle(EterPrimaryButtonStyle())
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .liveWorkout(let routine):
                LiveStrengthWorkoutView(routine: routine)
                    .environmentObject(imports)
                    .environmentObject(health)
            case .editRoutine(let routine):
                RoutineEditorView(routine: routine)
                    .environmentObject(imports)
                    .environmentObject(routineStore)
            case .dayProposal:
                DayWorkoutProposalView(routines: routines)
                    .environmentObject(imports)
                    .environmentObject(health)
                    .environmentObject(checkIns)
            }
        }
        .onAppear { selectDefaultProgressExercise() }
        .onChange(of: imports.workoutCount) { _, _ in selectDefaultProgressExercise() }
    }

    @ViewBuilder private var strengthProgressSection: some View {
        let summary = StrengthProgressEngine.summarize(imports.workouts)
        if summary.exercises.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Evolución de fuerza", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Text("Cuando haya series con peso y repeticiones mostraremos 1RM estimado, volumen, récords y equilibrio de patrones.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.cardStyle()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    EterSectionHeader("Rendimiento, no solo kilos", eyebrow: "Evolución de fuerza")
                    Spacer()
                    DataTrustBadge(trust: DataTrust(nature: .calculated, source: "Historial Hevy + sesiones registradas aquí", measuredAt: imports.workouts.map(\.start).max(), samples: summary.totalHistorySessions, level: ConfidenceEngine.samples(summary.totalHistorySessions, medium: 6, high: 20, label: "sesiones de fuerza").level, explanation: "El sistema reconstruye cada ejercicio a partir de sus series y calcula tendencias comparables entre sesiones.", limitations: "El 1RM se estima con la fórmula de Epley y solo series de 1–12 repeticiones. Técnica, rango de movimiento, RPE y máquinas distintas pueden alterar la comparación."))
                }
                HStack(spacing: 10) {
                    strengthSummaryMetric("Sesiones 28d", "\(summary.sessions28Days)", "calendar")
                    strengthSummaryMetric("Series efectivas", "\(summary.effectiveSets28Days)", "list.number")
                    strengthSummaryMetric("Récords 28d", "\(summary.records28Days)", "trophy.fill")
                }
            }.cardStyle()

            strengthCoverageCard

            if let progress = selectedProgress(in: summary) {
                exerciseProgressCard(progress, choices: summary.exercises)
            }
        }
    }

    private func strengthSummaryMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(EterTheme.positive)
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var strengthCoverageCard: some View {
        let coverage = StrengthProgressEngine.coverage(imports.workouts, profile: goals.profile, healthWorkouts: health.recentWorkouts)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cobertura de fuerza").font(.headline)
                    Text("Realizado frente a tu rango objetivo").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Ciclo \(coverage.days)d").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(coverage.items) { item in
                VStack(spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) {
                            Text(item.name).font(.caption)
                            Spacer()
                            strengthCoverageValue(item)
                            strengthCoverageState(item)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(item.name).font(.caption); Spacer(); strengthCoverageState(item) }
                            strengthCoverageValue(item)
                        }
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.09))
                            let progress = min(1.25, Double(item.completed) / Double(max(1, item.target.upperBound)))
                            Capsule().fill(coverageColor(item.state).opacity(0.78))
                                .frame(width: min(proxy.size.width, proxy.size.width * progress))
                        }
                    }.frame(height: 7)
                }
            }
            Divider()
            Text(coverage.interpretation).font(.caption.bold()).lineSpacing(3)
            Text(coverage.context + " Solo cuenta series de trabajo; el cardio se interpreta en Rendimiento y Plan. Una sesión registrada solo en el Watch (sin detalle de ejercicios) se estima por duración y músculos implicados, no contada con la misma precisión que una importación de Hevy.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func strengthCoverageValue(_ item: StrengthCoverageItem) -> some View {
        Text("\(item.completed) / \(item.target.lowerBound)–\(item.target.upperBound) · \(item.percentage)%")
            .font(.caption.monospacedDigit())
    }

    private func strengthCoverageState(_ item: StrengthCoverageItem) -> some View {
        Text(item.state).font(.caption2.bold()).foregroundStyle(coverageColor(item.state))
    }

    private func coverageColor(_ state: String) -> Color { coverageStateColor(state) }

    private func exerciseProgressCard(_ progress: ExerciseStrengthProgress, choices: [ExerciseStrengthProgress]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Ejercicio", selection: $selectedProgressExercise) {
                ForEach(choices) { Text($0.name).tag($0.name) }
            }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline) {
                if let oneRM = progress.latestOneRM {
                    Text("\(oneRM, specifier: "%.1f") kg").font(.title.bold()).fontDesign(.rounded)
                    Text("1RM estimado").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sin 1RM estimable").font(.headline)
                }
                Spacer()
                Text(progress.state).font(.caption.bold()).foregroundStyle(progressColor(progress.changePercent))
            }
            if progress.points.count >= 2 {
                Chart(progress.points) { point in
                    AreaMark(x: .value("Fecha", point.date), y: .value("1RM", point.estimatedOneRM))
                        .foregroundStyle(LinearGradient(colors: [Color.indigo.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Fecha", point.date), y: .value("1RM", point.estimatedOneRM))
                        .foregroundStyle(.indigo).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    PointMark(x: .value("Fecha", point.date), y: .value("1RM", point.estimatedOneRM)).foregroundStyle(.indigo)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)) } }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 155)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Evolución del 1RM estimado de \(progress.name)")
                .accessibilityValue(progress.points.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.estimatedOneRM.formatted(.number.precision(.fractionLength(1)))) kilogramos" }.joined(separator: ". "))
            } else {
                Text("Hace falta otra sesión comparable para dibujar la tendencia.").font(.caption).foregroundStyle(.secondary).frame(height: 45)
            }
            Divider()
            HStack(spacing: 8) {
                progressMetric("Cambio", progress.changePercent.map { String(format: "%+.1f%%", $0) } ?? "—")
                progressMetric("Último volumen", progress.latestVolume > 0 ? "\(Int(progress.latestVolume.rounded())) kg" : "—")
                progressMetric("Sesiones", "\(progress.sessions)")
            }
            if let best = progress.bestSet {
                Label("Mejor serie: \(best.weight.formatted()) kg × \(best.reps) · \(best.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "trophy")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Serie efectiva = serie completada que no está marcada como calentamiento. El volumen es peso × repeticiones; no se compara directamente entre ejercicios.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func progressMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.subheadline.bold()).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedProgress(in summary: StrengthProgressSummary) -> ExerciseStrengthProgress? {
        summary.exercises.first { $0.name == selectedProgressExercise } ?? summary.exercises.first
    }

    private func selectDefaultProgressExercise() {
        let exercises = StrengthProgressEngine.summarize(imports.workouts).exercises
        if !exercises.contains(where: { $0.name == selectedProgressExercise }) { selectedProgressExercise = exercises.first?.name ?? "" }
    }

    private func progressColor(_ change: Double?) -> Color {
        guard let change else { return .secondary }
        return change >= 2 ? EterTheme.positive : change <= -4 ? EterTheme.negative : .blue
    }

    private func routineCard(_ routine: StrengthRoutine, customized: Bool) -> some View {
        let safeRoutine = InjurySafetyEngine.filter(routine, injuries: InjuryStore.shared.active)
        let removed = routine.exercises.count - safeRoutine.exercises.count
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.name).font(.title3.bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if customized { Text("PERSONALIZADA").font(.caption2.bold()).foregroundStyle(EterTheme.positive) }
                    if let date = routine.lastPerformed { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(routine.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3).lineSpacing(3)
            if removed > 0 {
                Label("\(removed) ejercicio\(removed == 1 ? "" : "s") bloqueado\(removed == 1 ? "" : "s") por una restricción activa", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.bold()).foregroundStyle(EterTheme.warning)
            }
            HStack {
                Label("\(safeRoutine.exercises.count) ejercicios compatibles", systemImage: "list.number")
                if routine.historicalVolume > 0 { Label("\(Int(routine.historicalVolume.rounded())) kg", systemImage: "scalemass") }
            }.font(.caption2).foregroundStyle(.secondary)
            if let note = routine.exercises.first?.prescriptionNote {
                Label("Prescripción: \(note)", systemImage: "waveform.path.ecg")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 9) {
                Button { activeSheet = .editRoutine(routine) } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }
                Button { activeSheet = .liveWorkout(safeRoutine) } label: {
                    HStack { Text("Comenzar rutina").bold(); Spacer(); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(EterTheme.accent).foregroundStyle(EterTheme.accentInk)
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }.disabled(safeRoutine.exercises.isEmpty)
            }
        }.cardStyle()
    }
}

struct DayWorkoutProposalView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var checkIns: DailyCheckInStore
    @EnvironmentObject private var goals: GoalStore
    @Environment(\.dismiss) private var dismiss
    let routines: [StrengthRoutine]
    @State private var activeRoutine: StrengthRoutine?

    private var context: TwinContext {
        TwinContext(profile: goals.profile, events: LifestyleFactorStore.shared.events, reviews: WorkoutReviewStore.shared.reviews,
                   activeInjuries: InjuryStore.shared.active, calibration: TwinStateStore.shared.calibration,
                   personalAnchor: TwinStateStore.shared.personalAnchor())
    }
    private var assessment: TwinAssessment {
        TwinEngine.assess(health: health, imports: imports, checkIn: checkIns.entry(), context: context)
    }
    private var plan: WeeklyPlanStatus {
        TrainingPlanEngine.status(health: health, imports: imports, readiness: assessment.score,
                                  muscles: assessment.muscles, checkIn: checkIns.entry(), context: context,
                                  physiologicalAlert: assessment.physiologicalAlert)
    }
    private var proposal: StrengthRoutine {
        let recommendation = assessment.recommendation.lowercased()
        // Imported gym templates are only reused when the athlete has declared
        // gym access. Without it, WorkoutPlanner builds the bodyweight variant
        // appropriate to the same recommendation and readiness.
        if goals.profile.gymAvailable {
            if recommendation.contains("pierna"), let routine = routines.first(where: { $0.name == "Pierna" }) {
                return StrengthRoutineBuilder.applyingVolumeFactor(InjurySafetyEngine.filter(routine, injuries: InjuryStore.shared.active), factor: plan.volumeFactor)
            }
            if recommendation.contains("tirón") || recommendation.contains("tiron"), let routine = routines.first(where: { $0.name == "Pull" }) {
                return StrengthRoutineBuilder.applyingVolumeFactor(InjurySafetyEngine.filter(routine, injuries: InjuryStore.shared.active), factor: plan.volumeFactor)
            }
            if recommendation.contains("empuje"), let routine = routines.first(where: { $0.name == "Push" }) {
                return StrengthRoutineBuilder.applyingVolumeFactor(InjurySafetyEngine.filter(routine, injuries: InjuryStore.shared.active), factor: plan.volumeFactor)
            }
        }
        let generated = WorkoutPlanner.propose(health: health, imports: imports, checkIn: checkIns.entry())
        let routine = StrengthRoutineBuilder.routine(
            from: generated, imports: imports,
            readiness: assessment.score, muscles: assessment.muscles
        )
        return StrengthRoutineBuilder.applyingVolumeFactor(routine, factor: plan.volumeFactor)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(assessment.state.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        Text(proposal.name).font(.largeTitle).fontDesign(.serif)
                        Text(reason).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    }.cardStyle()

                    VStack(alignment: .leading, spacing: 11) {
                        Text("PROPUESTA DE HOY").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        ForEach(proposal.exercises) { exercise in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(exercise.name).font(.subheadline.bold())
                                    let working = exercise.sets.last
                                    Text("\(exercise.sets.count) series · \(working?.weight ?? 0, specifier: "%.1f") kg × \(working?.reps ?? 0)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(exercise.restSeconds / 60):\(String(format: "%02d", exercise.restSeconds % 60))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if exercise.id != proposal.exercises.last?.id { Divider() }
                        }
                    }.cardStyle()

                    Button { activeRoutine = proposal } label: {
                        Label("Comenzar propuesta", systemImage: "play.fill")
                    }.buttonStyle(EterPrimaryButtonStyle())
                    Button { activeRoutine = proposal } label: {
                        Label("Revisar y editar antes", systemImage: "slider.horizontal.3")
                    }.buttonStyle(EterAccentButtonStyle())
                    Button {
                        activeRoutine = StrengthRoutine(name: "Entrenamiento libre", subtitle: "", exercises: [], lastPerformed: nil, historicalVolume: 0)
                    } label: {
                        Text("Empezar en blanco").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                }.padding(18)
            }
            .background(EterTheme.canvas)
            .navigationTitle("Entrenamiento del día")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .fullScreenCover(item: $activeRoutine) { routine in
                LiveStrengthWorkoutView(routine: routine)
                    .environmentObject(imports)
                    .environmentObject(health)
            }
        }
    }

    private var reason: String {
        let now = Date()
        let block = TrainingPlanEngine.activeBlock(on: now, profile: goals.profile)
        let focus = TrainingPlanEngine.goalFocus(for: goals.profile, on: now)
        let equipment = goals.profile.gymAvailable
            ? "Se usan tus rutinas y cargas históricas de gimnasio."
            : "Como has indicado que no tienes gimnasio, la propuesta usa peso corporal y material cotidiano."
        let priority: String
        if focus.running >= max(focus.strength, focus.hybrid) {
            priority = "La fuerza se prescribe como soporte de \(focus.leadingGoal), sin competir innecesariamente con el trabajo de carrera."
        } else if focus.strength >= focus.hybrid {
            priority = "La fuerza es la capacidad con más peso actual para \(focus.leadingGoal)."
        } else {
            priority = "La sesión favorece la transferencia híbrida hacia \(focus.leadingGoal)."
        }
        return assessment.explanation + " Bloque activo: \(block.name). \(priority) \(equipment)"
    }

}

struct RoutineEditorView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var routineStore: StrengthRoutineStore
    @Environment(\.dismiss) private var dismiss
    let routine: StrengthRoutine
    @State private var exercises: [RoutineExercise]
    @State private var showPicker = false

    init(routine: StrengthRoutine) {
        self.routine = routine
        _exercises = State(initialValue: routine.exercises)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PLANTILLA ACTIVA").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        Text("Los cambios se usarán en los próximos entrenamientos. Los pesos siguen siendo editables durante cada sesión.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    }.cardStyle()

                    ForEach($exercises) { $exercise in
                        editorExerciseCard($exercise)
                    }

                    Button { showPicker = true } label: {
                        // Was missing an explicit foreground color — relied
                        // on the inherited EterTheme.ink, which in dark mode
                        // is a LIGHT color and had poor contrast against
                        // this same light lime background.
                        Label("Añadir ejercicio recomendado", systemImage: "sparkles")
                            .bold().foregroundStyle(EterTheme.accentInk).frame(maxWidth: .infinity).padding()
                            .background(EterTheme.accent).clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                    }

                    if routineStore.routine(named: routine.name) != nil {
                        Button(role: .destructive) {
                            routineStore.restoreAutomatic(routine.name)
                            dismiss()
                        } label: {
                            Text("Volver a usar automáticamente la última rutina de Hevy").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                    }
                }.padding(18)
            }
            .background(EterTheme.canvas)
            .navigationTitle("Editar \(routine.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.bold().disabled(exercises.isEmpty) }
            }
            .sheet(isPresented: $showPicker) { recommendationPicker }
        }
    }

    private func editorExerciseCard(_ exercise: Binding<RoutineExercise>) -> some View {
        let index = exercises.firstIndex { $0.id == exercise.wrappedValue.id } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                exerciseIdentity(exercise.wrappedValue.name)
                Spacer()
                Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.eterTouchTarget().accessibilityLabel("Subir ejercicio").disabled(index == 0)
                Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.eterTouchTarget().accessibilityLabel("Bajar ejercicio").disabled(index >= exercises.count - 1)
                Button(role: .destructive) { exercises.removeAll { $0.id == exercise.wrappedValue.id } } label: { Image(systemName: "trash") }.eterTouchTarget().accessibilityLabel("Eliminar \(exercise.wrappedValue.name)")
            }
            if let note = exercise.wrappedValue.prescriptionNote {
                Text("Propuesta · \(note)").font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
            Stepper(value: exercise.restSeconds, in: 30...300, step: 15) {
                Text("Descanso: \(exercise.wrappedValue.restSeconds / 60):\(String(format: "%02d", exercise.wrappedValue.restSeconds % 60))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("SERIE").frame(width: 42, alignment: .leading)
                Text("KG").frame(maxWidth: .infinity)
                Text("REPS").frame(maxWidth: .infinity)
                Spacer().frame(width: 27)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(exercise.sets.indices, id: \.self) { setIndex in
                HStack(spacing: 9) {
                    Text("\(setIndex + 1)").font(.caption.bold()).frame(width: 42, alignment: .leading)
                    TextField("0", value: exercise.sets[setIndex].weight, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.center).fieldBox()
                    TextField("0", value: exercise.sets[setIndex].reps, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.center).fieldBox()
                    Button(role: .destructive) { exercise.wrappedValue.sets.remove(at: setIndex) } label: { Image(systemName: "minus.circle") }
                        .eterTouchTarget().accessibilityLabel("Eliminar serie \(setIndex + 1)")
                }
            }
            Button {
                let last = exercise.wrappedValue.sets.last ?? ImportedSet(weight: 0, reps: 10, type: "normal", rpe: nil)
                exercise.wrappedValue.sets.append(last)
            } label: { Label("Añadir serie", systemImage: "plus.circle").font(.caption.bold()) }
        }.cardStyle()
    }

    private var recommendationPicker: some View {
        let recommended = StrengthRoutineBuilder.recommendations(for: routine.name, excluding: Set(exercises.map(\.name)), imports: imports)
        return NavigationStack {
            List(recommended) { exercise in
                Button {
                    exercises.append(exercise)
                    showPicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        exerciseIdentity(exercise.name)
                        if let working = exercise.sets.last {
                            Text("Último registro: \(working.weight.formatted()) kg × \(working.reps) · \(exercise.sets.count) series")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let muscles = MuscleMap.groups(for: exercise.name).joined(separator: " · ")
                        if !muscles.isEmpty { Text(muscles).font(.caption2).foregroundStyle(EterTheme.positive) }
                    }.padding(.vertical, 3)
                }
            }
            .navigationTitle("Recomendados")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showPicker = false } } }
        }
    }

    private func exerciseIdentity(_ name: String) -> some View {
        let descriptor = ExerciseCatalog.descriptor(for: name)
        return HStack(spacing: 10) {
            ExerciseVisualView(exercise: name, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("\(descriptor.pattern) · \(descriptor.equipment)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ index: Int, _ offset: Int) {
        let destination = index + offset
        guard exercises.indices.contains(index), exercises.indices.contains(destination) else { return }
        exercises.swapAt(index, destination)
    }

    private func save() {
        let updated = StrengthRoutine(
            name: routine.name,
            subtitle: exercises.map(\.name).joined(separator: " · "),
            exercises: exercises,
            lastPerformed: routine.lastPerformed,
            historicalVolume: routine.historicalVolume
        )
        routineStore.save(updated)
        dismiss()
    }
}

private struct LiveSet: Identifiable {
    let id = UUID()
    var weight: Double
    var reps: Int
    var type: String
    var completed = false
}

private struct LiveExercise: Identifiable {
    let id = UUID()
    var name: String
    var restSeconds: Int
    var sets: [LiveSet]
}

struct LiveStrengthWorkoutView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var watchMetrics: WatchMetricsStore
    @Environment(\.dismiss) private var dismiss
    let routine: StrengthRoutine
    @State private var exercises: [LiveExercise]
    @State private var startedAt = Date()
    @State private var restEndsAt: Date?
    @State private var showExercisePicker = false
    @State private var showDiscardConfirmation = false
    @State private var requestedWatchStart = false
    // Only one set can realistically be timed at once, so a single shared
    // pair of state covers every exercise card.
    @State private var timingSetID: UUID?
    @State private var timingStartedAt: Date?

    init(routine: StrengthRoutine) {
        self.routine = routine
        _exercises = State(initialValue: routine.exercises.map { exercise in
            LiveExercise(name: exercise.name, restSeconds: exercise.restSeconds, sets: exercise.sets.map {
                LiveSet(weight: $0.weight, reps: $0.reps, type: $0.type)
            })
        })
    }

    var body: some View {
        NavigationStack {
            // The rest timer needs to stay visible while scrolling between
            // exercises — it used to live inside the ScrollView and disappear
            // the moment you scrolled down to see the next one. It's now a
            // fixed bar above the scrolling content instead.
            VStack(spacing: 0) {
                sessionHeader.padding(18).padding(.bottom, 0)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach($exercises) { $exercise in exerciseCard($exercise) }
                        Button { showExercisePicker = true } label: {
                            Label("Añadir ejercicio", systemImage: "plus").frame(maxWidth: .infinity).padding()
                                .background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                        }
                        Button(action: finish) {
                            Text("Finalizar entrenamiento")
                        }.buttonStyle(EterPrimaryButtonStyle()).disabled(exercises.isEmpty)
                    }.padding(18)
                }
            }
            .background(EterTheme.canvas)
            .navigationTitle(routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showDiscardConfirmation = true } } }
            .confirmationDialog("¿Cerrar el entrenamiento?", isPresented: $showDiscardConfirmation) {
                Button("Descartar sesión", role: .destructive) { discard() }
                Button("Continuar", role: .cancel) {}
            }
            .sheet(isPresented: $showExercisePicker) { exercisePicker }
            .onChange(of: watchMetrics.terminalAction) { _, action in
                guard let action else { return }
                watchMetrics.clearTerminalAction()
                if action == "finish" { completeSession(notifyWatch: false) }
                else if action == "discard" { discardSession(notifyWatch: false) }
            }
            .onChange(of: watchMetrics.workoutCommand) { _, command in
                guard let command else { return }
                watchMetrics.clearWorkoutCommand()
                if command == "completeSet" { completeNextSet() }
                else if command == "skipRest" { restEndsAt = nil; syncWorkoutContext() }
                else if command.hasPrefix("restAdjust:"), let seconds = Int(command.dropFirst("restAdjust:".count)) {
                    adjustRest(bySeconds: seconds)
                }
            }
            .onChange(of: workoutContextSignature) { _, _ in syncWorkoutContext() }
            .task {
                guard !requestedWatchStart else { return }
                requestedWatchStart = true
                watchMetrics.clearTerminalAction()
                watchMetrics.clearWorkoutCommand()
                syncWorkoutContext()
                _ = await health.startStrengthWorkoutOnWatch()
            }
        }
    }

    private var sessionHeader: some View {
        VStack(spacing: 12) {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Text("TIEMPO").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(duration(context.date.timeIntervalSince(startedAt))).font(.title3.monospacedDigit().bold())
                }
            }
            Spacer()
            if let restEndsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("DESCANSO").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text(max(0, Int(restEndsAt.timeIntervalSince(context.date))).formatted() + " s")
                            .font(.title3.monospacedDigit().bold()).foregroundStyle(.orange)
                    }
                }
            }
        }
        if watchMetrics.isRunning {
            Divider()
            HStack {
                Label("\(Int(watchMetrics.heartRate.rounded())) ppm", systemImage: "heart.fill").foregroundStyle(.red)
                Spacer()
                Label("\(Int(watchMetrics.activeEnergy.rounded())) kcal", systemImage: "flame.fill").foregroundStyle(.orange)
                Spacer()
                Text(watchMetrics.isPaused ? "Watch en pausa" : "Watch conectado").font(.caption2.bold()).foregroundStyle(watchMetrics.isPaused ? EterTheme.negative : EterTheme.positive)
            }.font(.caption)
            Button {
                watchMetrics.isPaused ? watchMetrics.resume() : watchMetrics.pause()
            } label: {
                Label(watchMetrics.isPaused ? "Reanudar en Watch" : "Pausar en Watch", systemImage: watchMetrics.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.bold()).frame(maxWidth: .infinity)
            }
        } else {
            Text("Inicia “Fuerza” en el Apple Watch para añadir pulso y calorías reales a esta sesión.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        }.cardStyle()
    }

    private func exerciseCard(_ exercise: Binding<LiveExercise>) -> some View {
        let descriptor = ExerciseCatalog.descriptor(for: exercise.wrappedValue.name)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        ExerciseVisualView(exercise: exercise.wrappedValue.name, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.wrappedValue.name).font(.headline)
                            Text("\(descriptor.pattern) · \(descriptor.equipment)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Descanso \(exercise.wrappedValue.restSeconds / 60):\(String(format: "%02d", exercise.wrappedValue.restSeconds % 60))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { exercises.removeAll { $0.id == exercise.wrappedValue.id } } label: { Image(systemName: "trash") }
            }
            HStack {
                Text("SERIE").frame(width: 30, alignment: .leading)
                Text("KG").frame(maxWidth: .infinity)
                Text(descriptor.isTimed ? "SEG" : "REPS").frame(maxWidth: .infinity)
                Text("HECHA").frame(width: 52)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(exercise.sets) { $set in
                HStack(spacing: 8) {
                    Text("\((exercise.wrappedValue.sets.firstIndex { $0.id == set.id } ?? 0) + 1)")
                        .font(.subheadline.bold()).frame(width: 30, alignment: .leading)
                    stepperField(value: $set.weight, step: 2.5, minimum: 0, decimalPlaces: 0...1)
                    if descriptor.isTimed {
                        timedSetField($set)
                    } else {
                        stepperField(value: $set.reps, step: 1, minimum: 0)
                    }
                    completedButton($set, restSeconds: exercise.wrappedValue.restSeconds)
                }
            }
            Button {
                let fallback = LiveSet(weight: 0, reps: descriptor.isTimed ? 30 : 10, type: "normal")
                let previous = exercise.wrappedValue.sets.last ?? fallback
                exercise.wrappedValue.sets.append(LiveSet(weight: previous.weight, reps: previous.reps, type: "normal"))
            } label: { Label("Añadir serie", systemImage: "plus.circle").font(.caption.bold()) }
        }.cardStyle()
    }

    // A plain TextField with a live-editable numeric value is fiddly to hit
    // precisely mid-workout — these +/- buttons cover the common case (repeat
    // or nudge the previous set) without needing to type at all. Sized up
    // (bigger box, bolder digits) after comparing against how roomy Hevy's
    // own logging screen is — the old 38pt-wide field with caption-sized
    // text was genuinely harder to hit and read mid-set than it needed to be.
    private func stepperField(value: Binding<Double>, step: Double, minimum: Double, decimalPlaces: ClosedRange<Int> = 0...1) -> some View {
        HStack(spacing: 3) {
            stepButton(systemImage: "minus") { value.wrappedValue = max(minimum, value.wrappedValue - step) }
            TextField("0", value: value, format: .number.precision(.fractionLength(decimalPlaces)))
                .keyboardType(.decimalPad).multilineTextAlignment(.center).font(.title3.bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 60).fieldBox()
            stepButton(systemImage: "plus") { value.wrappedValue += step }
        }.frame(maxWidth: .infinity)
    }

    private func stepperField(value: Binding<Int>, step: Int, minimum: Int) -> some View {
        HStack(spacing: 3) {
            stepButton(systemImage: "minus") { value.wrappedValue = max(minimum, value.wrappedValue - step) }
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.center).font(.title3.bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 52).fieldBox()
            stepButton(systemImage: "plus") { value.wrappedValue += step }
        }.frame(maxWidth: .infinity)
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.body.bold()).frame(width: 34, height: 46)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .eterTouchTarget()
    }

    // A big, filled checkmark button reads and hits far more easily
    // mid-set than the native iOS Toggle switch this replaced — the same
    // "make the thing you tap between every set as easy to hit as
    // possible" reasoning as the bigger weight/reps boxes above.
    private func completedButton(_ set: Binding<LiveSet>, restSeconds: Int) -> some View {
        Button {
            set.wrappedValue.completed.toggle()
            if set.wrappedValue.completed {
                restEndsAt = Date().addingTimeInterval(TimeInterval(restSeconds))
            }
        } label: {
            Image(systemName: "checkmark")
                .font(.title3.bold())
                .foregroundStyle(set.wrappedValue.completed ? .white : .secondary)
                .frame(width: 52, height: 46)
        }
        .buttonStyle(.plain)
        .background(set.wrappedValue.completed ? EterTheme.positive : Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .eterTouchTarget()
    }

    /// Isometric holds/carries aren't a "how many" question — you find out the
    /// duration by timing the hold, not by deciding it in advance. Tap once to
    /// start, tap again to stop and commit the elapsed seconds into the set;
    /// still manually editable via the field when the timer isn't running.
    private func timedSetField(_ set: Binding<LiveSet>) -> some View {
        let isTiming = timingSetID == set.wrappedValue.id
        return HStack(spacing: 2) {
            Button {
                if isTiming {
                    if let startedAt = timingStartedAt {
                        set.wrappedValue.reps = max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
                    }
                    timingSetID = nil; timingStartedAt = nil
                } else {
                    timingSetID = set.wrappedValue.id; timingStartedAt = Date()
                }
            } label: {
                Image(systemName: isTiming ? "stop.fill" : "play.fill").font(.caption.bold()).frame(width: 24, height: 30)
            }
            .buttonStyle(.plain)
            .background((isTiming ? Color.orange : Color.primary).opacity(isTiming ? 0.22 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .eterTouchTarget()

            if isTiming, let startedAt = timingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(startedAt).rounded())) s")
                        .font(.subheadline.monospacedDigit().bold()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity).fieldBox()
                }
            } else {
                TextField("0", value: set.reps, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.center)
                    .lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 30).fieldBox()
            }
        }.frame(maxWidth: .infinity)
    }

    private var exercisePicker: some View {
        let compatible = StrengthRoutineBuilder.exerciseLibrary(from: imports).filter {
            InjurySafetyEngine.exerciseSafety($0.name, injuries: InjuryStore.shared.active).allowed
        }
        return NavigationStack {
            List(compatible) { exercise in
                Button {
                    exercises.append(LiveExercise(name: exercise.name, restSeconds: exercise.restSeconds, sets: exercise.sets.map { LiveSet(weight: $0.weight, reps: $0.reps, type: $0.type) }))
                    showExercisePicker = false
                } label: {
                    VStack(alignment: .leading) { Text(exercise.name); Text("\(exercise.sets.count) series desde tu historial").font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Añadir ejercicio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showExercisePicker = false } } }
        }
    }

    private func finish() {
        completeSession(notifyWatch: true)
    }

    private var workoutContextSignature: String {
        exercises.flatMap { exercise in
            exercise.sets.map { "\(exercise.name)|\($0.weight)|\($0.reps)|\($0.completed)" }
        }.joined(separator: ";") + "|\(restEndsAt?.timeIntervalSince1970 ?? 0)"
    }

    private func syncWorkoutContext() {
        let flattened = exercises.flatMap { exercise in exercise.sets.map { (exercise.name, $0) } }
        let completed = flattened.filter { $0.1.completed }.count
        let next = flattened.first { !$0.1.completed }
        let nextIndex = next.flatMap { target in flattened.firstIndex { $0.1.id == target.1.id } } ?? flattened.count
        let volume = flattened.filter { $0.1.completed }.reduce(0) { $0 + $1.1.weight * Double($1.1.reps) }
        watchMetrics.updateWorkoutContext(routine: routine.name,
                                          workoutID: "\(routine.name)|\(startedAt.timeIntervalSince1970)", workoutDate: startedAt,
                                          exercise: next?.0,
                                          setNumber: min(flattened.count, nextIndex + 1), totalSets: flattened.count,
                                          weight: next?.1.weight, reps: next?.1.reps,
                                          completedSets: completed, totalVolume: volume, restEndsAt: restEndsAt)
    }

    // Mirrors Hevy's ±15s rest-adjust buttons, drivable from either the
    // phone or the Watch (the Watch relays it as a phone command so both
    // devices keep agreeing on the same countdown). Bottoms out at "now"
    // rather than letting a large negative adjustment push it into the
    // past — that's just a skip, handled explicitly by skipRest instead.
    private func adjustRest(bySeconds seconds: Int) {
        guard let restEndsAt else { return }
        let adjusted = restEndsAt.addingTimeInterval(TimeInterval(seconds))
        self.restEndsAt = adjusted <= Date() ? nil : adjusted
        syncWorkoutContext()
    }

    private func completeNextSet() {
        for exerciseIndex in exercises.indices {
            if let setIndex = exercises[exerciseIndex].sets.firstIndex(where: { !$0.completed }) {
                exercises[exerciseIndex].sets[setIndex].completed = true
                restEndsAt = Date().addingTimeInterval(TimeInterval(exercises[exerciseIndex].restSeconds))
                syncWorkoutContext()
                return
            }
        }
    }

    private func completeSession(notifyWatch: Bool) {
        let saved = exercises.compactMap { exercise -> ImportedExercise? in
            let selected = exercise.sets.filter(\.completed)
            let source = selected.isEmpty ? exercise.sets : selected
            guard !source.isEmpty else { return nil }
            let details = source.map { ImportedSet(weight: $0.weight, reps: $0.reps, type: $0.type, rpe: nil) }
            // éter's own live session has no in-session warm-up toggle, so
            // every set is logged as "normal" — the ascending-ramp
            // inference in workingSets(_:) is what actually catches a
            // warm-up ramp here, the same way it does for an untagged Hevy
            // session. setDetails keeps the full raw list either way.
            let working = StrengthProgressEngine.workingSets(details)
            let reps = working.reduce(0) { $0 + $1.reps }
            let volume = working.reduce(0) { $0 + $1.weight * Double($1.reps) }
            return ImportedExercise(name: exercise.name, sets: working.count, volume: volume, totalReps: reps, averageWeight: reps > 0 ? volume / Double(reps) : nil, setDetails: details)
        }
        let endedAt = Date()
        imports.addStrengthWorkout(title: routine.name, start: startedAt, end: endedAt, exercises: saved)
        if notifyWatch && watchMetrics.isRunning {
            watchMetrics.finish()
        } else if !watchMetrics.isRunning && notifyWatch {
            Task { await health.saveStrengthWorkout(start: startedAt, end: endedAt) }
        }
        dismiss()
    }

    private func discard() {
        discardSession(notifyWatch: true)
    }

    private func discardSession(notifyWatch: Bool) {
        if notifyWatch && watchMetrics.isRunning { watchMetrics.discard() }
        restEndsAt = nil
        dismiss()
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval)); return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func fieldBox() -> some View {
        padding(.vertical, 9).background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
