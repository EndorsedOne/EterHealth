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
    @EnvironmentObject private var travel: TravelEpisodeStore
    @State private var activeSheet: StrengthSheet?
    @State private var selectedProgressExercise = ""

    private var context: TwinContext {
        TwinContext(profile: goals.profile, events: LifestyleFactorStore.shared.events,
                    reviews: WorkoutReviewStore.shared.reviews,
                    activeInjuries: InjuryStore.shared.active,
                    calibration: TwinStateStore.shared.calibration,
                    personalAnchor: TwinStateStore.shared.personalAnchor(),
                    travel: travel.episodeForEvaluation(), travelHistory: travel.episodes)
    }

    var body: some View {
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIns.entry(),
                                           context: TwinContext(profile: goals.profile, events: LifestyleFactorStore.shared.events,
                                                                reviews: WorkoutReviewStore.shared.reviews, activeInjuries: InjuryStore.shared.active,
                                                                calibration: TwinStateStore.shared.calibration,
                                                                personalAnchor: TwinStateStore.shared.personalAnchor(),
                                                                travel: travel.episodeForEvaluation(), travelHistory: travel.episodes))
        let forecasts = TrainingPlanEngine.weekAhead(
            health: health, imports: imports, checkIn: checkIns.entry(), context: context, days: 14
        )
        let strengthForecasts = Array(forecasts.filter { $0.kind == .strength }.prefix(3))
        let plan = TrainingPlanEngine.status(
            health: health, imports: imports, readiness: assessment.score,
            muscles: assessment.muscles, checkIn: checkIns.entry(), context: context,
            physiologicalAlert: assessment.physiologicalAlert
        )
        VStack(alignment: .leading, spacing: 18) {
            EterPageHeader(eyebrow: "Fuerza", title: "Entrena y progresa")

            recommendedStrengthSection(strengthForecasts, assessment: assessment, plan: plan)

            strengthProgressSection

            // Objetivos de fuerza (press banca, sentadilla, peso muerto,
            // hipertrofia). Los de carrera/híbridos viven en Rendimiento.
            GoalDistanceCard(strengthOnly: true)

            // Movidas desde Rendimiento: distribución muscular y volumen de
            // fuerza son análisis de fuerza y su sitio es esta pestaña.
            MuscleVolumeSection()

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
                DayWorkoutProposalView()
                    .environmentObject(imports)
                    .environmentObject(health)
                    .environmentObject(checkIns)
            }
        }
        .onAppear { selectDefaultProgressExercise() }
        .onChange(of: imports.workoutCount) { _, _ in selectDefaultProgressExercise() }
    }

    @ViewBuilder private func recommendedStrengthSection(
        _ forecasts: [TrainingPlanEngine.DayForecast], assessment: TwinAssessment, plan: WeeklyPlanStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EterSectionHeader("Tu próxima sesión", eyebrow: "Recomendación de fuerza")
            Text("Una opción principal y dos variantes válidas para el mismo momento. La secuencia futura se muestra aparte para no confundir dos días de pierna con dos alternativas iguales.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)

            if forecasts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Ahora no toca forzar una sesión", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    Text("El plan de los próximos días prioriza otros estímulos o recuperación. Cuando vuelva a encajar fuerza, aparecerá aquí con ejercicios y volumen concretos.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    Button { activeSheet = .dayProposal } label: {
                        Label("Consultar una opción para hoy", systemImage: "sparkles")
                    }.buttonStyle(EterAccentButtonStyle())
                }.cardStyle()
            } else {
                if let primary = forecasts.first {
                    recommendedStrengthCard(primary, rank: 0, assessment: assessment)

                    let variants = strengthVariants(for: primary, assessment: assessment, plan: plan)
                    if !variants.isEmpty {
                        Text("OTRAS FORMAS DE CUBRIRLA").font(.caption2.bold())
                            .tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                        ForEach(Array(variants.enumerated()), id: \.element.id) { index, routine in
                            strengthVariantCard(routine, index: index)
                        }
                    }

                    if forecasts.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SECUENCIA PREVISTA").font(.caption2.bold())
                                .tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(forecasts) { forecast in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(forecast.date.formatted(.dateTime.weekday(.abbreviated).day()))
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(forecast.strengthPattern?.label ?? "Fuerza")
                                                .font(.caption.bold())
                                        }
                                        .padding(.horizontal, 11).padding(.vertical, 8)
                                        .background(EterTheme.raisedSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                                    }
                                }
                            }
                            Text("Es una previsión cronológica: puede repetir patrón si sigue existiendo déficit y hay recuperación suficiente. Se recalcula después de cada sesión.")
                                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                        }
                    }
                }
            }
        }
    }

    private func recommendedStrengthCard(
        _ forecast: TrainingPlanEngine.DayForecast, rank: Int, assessment: TwinAssessment
    ) -> some View {
        let routine = routine(from: forecast, assessment: assessment)
        let totalSets = routine.exercises.reduce(0) { $0 + $1.sets.count }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MEJOR ENCAJE")
                        .font(.caption2.bold()).tracking(EterTheme.eyebrowTracking)
                        .foregroundStyle(rank == 0 ? EterTheme.positive : .secondary)
                    Text(forecast.strengthTitle ?? routine.name).font(.title3.bold())
                    Text(forecast.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if forecast.isDeload {
                    Text("DESCARGA").font(.caption2.bold()).foregroundStyle(EterTheme.warning)
                }
            }

            Text(forecast.rationale).font(.caption).foregroundStyle(.secondary).lineSpacing(3)

            HStack(spacing: 14) {
                Label("\(routine.exercises.count) ejercicios", systemImage: "list.number")
                Label("\(totalSets) series", systemImage: "repeat")
                if let duration = forecast.strengthDuration { Label(duration, systemImage: "clock") }
            }.font(.caption2).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(routine.exercises.prefix(4)) { exercise in
                    HStack {
                        Text(exercise.name).font(.caption.bold()).lineLimit(1)
                        Spacer()
                        let working = exercise.sets.last
                        Text("\(exercise.sets.count) × \(working?.reps ?? 0)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if routine.exercises.count > 4 {
                    Text("+ \(routine.exercises.count - 4) ejercicios").font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 9) {
                Button { activeSheet = .editRoutine(routine) } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }
                .accessibilityLabel("Revisar y editar \(routine.name)")
                Button { activeSheet = .liveWorkout(routine) } label: {
                    HStack { Text("Comenzar").bold(); Spacer(); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(rank == 0 ? EterTheme.accent : EterTheme.raisedSurface)
                        .foregroundStyle(rank == 0 ? EterTheme.accentInk : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }.disabled(routine.exercises.isEmpty)
            }
        }.cardStyle()
    }

    private func strengthVariants(
        for primary: TrainingPlanEngine.DayForecast, assessment: TwinAssessment, plan: WeeklyPlanStatus
    ) -> [StrengthRoutine] {
        let primaryPattern = primary.strengthPattern ?? .push
        let remaining = StrengthPattern.allCases.filter { $0 != primaryPattern }
        let alternatePattern = remaining.max { left, right in
            patternReadiness(left, muscles: assessment.muscles) < patternReadiness(right, muscles: assessment.muscles)
        }

        var result: [StrengthRoutine] = []
        if let alternatePattern {
            let alternate = proposedStrength(
                pattern: alternatePattern, title: "\(alternatePattern.label) como alternativa",
                rationale: "Cambia el patrón principal para conservar la sesión de \(primaryPattern.inline) para otro día. Es útil si hoy prefieres no cargar esa zona, aunque cubre peor el déficit que ha priorizado Éter.",
                assessment: assessment, plan: plan
            )
            result.append(StrengthRoutineBuilder.applyingVolumeFactor(
                StrengthRoutineBuilder.routine(from: alternate, imports: imports,
                                               readiness: assessment.score, muscles: assessment.muscles),
                factor: min(1, plan.volumeFactor)
            ))
        }

        let proposals = StrengthPattern.allCases.map {
            proposedStrength(pattern: $0, title: $0.label, rationale: "",
                             assessment: assessment, plan: plan)
        }
        let fullBodyExercises = proposals.flatMap { proposal in
            let count = proposal.strengthPattern == primaryPattern ? 2 : 1
            return Array(proposal.exercises.prefix(count))
        }
        if !fullBodyExercises.isEmpty {
            let fullBody = ProposedWorkout(
                title: "Full body ajustado", duration: "45–55 min",
                intent: "Repartir el estímulo sin concentrar toda la fatiga en un único patrón.",
                exercises: fullBodyExercises,
                note: "Toca los tres patrones con menos volumen por zona. Da más cobertura global, pero progresa menos el déficit prioritario que la opción principal.",
                kind: .strength, strengthPattern: nil
            )
            result.append(StrengthRoutineBuilder.applyingVolumeFactor(
                StrengthRoutineBuilder.routine(from: fullBody, imports: imports,
                                               readiness: assessment.score, muscles: assessment.muscles),
                factor: min(0.75, plan.volumeFactor)
            ))
        }
        return result
    }

    private func proposedStrength(
        pattern: StrengthPattern, title: String, rationale: String,
        assessment: TwinAssessment, plan: WeeklyPlanStatus
    ) -> ProposedWorkout {
        let workout = WorkoutPlanner.session(
            for: .strength, pattern: pattern, upperBodyOnlyToday: false,
            block: plan.block, isDeload: plan.isDeload,
            readiness: assessment.score, rationale: rationale,
            muscles: assessment.muscles, health: health, imports: imports,
            context: context
        )
        return ProposedWorkout(
            title: title, duration: workout.duration, intent: workout.intent,
            exercises: workout.exercises, note: rationale,
            kind: .strength, strengthPattern: pattern
        )
    }

    private func patternReadiness(_ pattern: StrengthPattern, muscles: [MuscleReadiness]) -> Double {
        let values = pattern.muscles.compactMap { name in muscles.first { $0.name == name }?.readiness }
        return values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }

    private func strengthVariantCard(_ routine: StrengthRoutine, index: Int) -> some View {
        let totalSets = routine.exercises.reduce(0) { $0 + $1.sets.count }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(.headline)
                    Text(index == 0 ? "Otro patrón" : "Más cobertura · menos volumen por zona")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(totalSets) series").font(.caption.bold()).monospacedDigit()
            }
            Text(routine.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 9) {
                Button { activeSheet = .editRoutine(routine) } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }
                Button { activeSheet = .liveWorkout(routine) } label: {
                    HStack { Text("Elegir esta opción").bold(); Spacer(); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(EterTheme.raisedSurface).foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }.disabled(routine.exercises.isEmpty)
            }
        }.cardStyle()
    }

    private func routine(
        from forecast: TrainingPlanEngine.DayForecast, assessment: TwinAssessment
    ) -> StrengthRoutine {
        let proposed = ProposedWorkout(
            title: forecast.strengthTitle ?? "Fuerza recomendada",
            duration: forecast.strengthDuration ?? "",
            intent: forecast.prescription,
            exercises: forecast.strengthExercises,
            note: forecast.rationale,
            kind: .strength,
            strengthPattern: nil
        )
        return StrengthRoutineBuilder.routine(
            from: proposed, imports: imports,
            readiness: assessment.score, muscles: assessment.muscles
        )
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

            let goalChoices = goalExerciseChoices(in: summary)
            if let progress = selectedProgress(in: goalChoices) {
                exerciseProgressCard(progress, choices: goalChoices)
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

    private func selectedProgress(in choices: [ExerciseStrengthProgress]) -> ExerciseStrengthProgress? {
        choices.first { $0.name == selectedProgressExercise } ?? choices.first
    }

    private func goalExerciseChoices(in summary: StrengthProgressSummary) -> [ExerciseStrengthProgress] {
        let kinds = Set(goals.activeGoals.filter { $0.kind.isStrength }.map(\.kind))
        return summary.exercises.filter { progress in
            let name = progress.name.lowercased()
            if kinds.contains(.benchPress),
               name.contains("bench press (barbell)") || name.contains("press banca") { return true }
            if kinds.contains(.squat),
               name.contains("squat (barbell)") || name.contains("sentadilla") { return true }
            if kinds.contains(.deadlift),
               name.contains("deadlift (barbell)") || name.contains("peso muerto") { return true }
            return false
        }
    }

    private func selectDefaultProgressExercise() {
        let exercises = goalExerciseChoices(in: StrengthProgressEngine.summarize(imports.workouts))
        if !exercises.contains(where: { $0.name == selectedProgressExercise }) { selectedProgressExercise = exercises.first?.name ?? "" }
    }

    private func progressColor(_ change: Double?) -> Color {
        guard let change else { return .secondary }
        return change >= 2 ? EterTheme.positive : change <= -4 ? EterTheme.negative : .blue
    }

}

struct DayWorkoutProposalView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var checkIns: DailyCheckInStore
    @EnvironmentObject private var goals: GoalStore
    @EnvironmentObject private var travel: TravelEpisodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var activeRoutine: StrengthRoutine?

    private var context: TwinContext {
        TwinContext(profile: goals.profile, events: LifestyleFactorStore.shared.events, reviews: WorkoutReviewStore.shared.reviews,
                   activeInjuries: InjuryStore.shared.active, calibration: TwinStateStore.shared.calibration,
                   personalAnchor: TwinStateStore.shared.personalAnchor(), travel: travel.episodeForEvaluation(), travelHistory: travel.episodes)
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
        // Siempre parte de la decisión estructurada del entrenador. Antes,
        // si existía una plantilla Push/Pull/Pierna, se copiaba simplemente
        // la última rutina completa: conservaba ejercicios familiares, pero
        // ignoraba qué músculos estaban ya cubiertos, qué levantamiento era
        // prioritario y qué selección acababa de hacer WorkoutPlanner.
        // WorkoutPlanner ya reutiliza ejercicios y cargas de Hevy; no hace
        // falta saltarse su selección para conservar el historial.
        let generated = WorkoutPlanner.propose(health: health, imports: imports, checkIn: checkIns.entry(), context: context)
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

    /// Mismo borrador que la vista en vivo (ver NumericDraftField): el editor
    /// tenía los mismos TextField(value:format:) que reformatean por tecla.
    private func editorWeightField(value: Binding<Double>) -> some View {
        let format: (Double) -> String = {
            $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
        }
        let parse: (String) -> Double? = {
            Double($0.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) }
        }
        return NumericDraftField(value: value, format: format, parse: parse,
                                 keyboard: .decimalPad, minWidth: 44)
    }

    private func editorNumberField(value: Binding<Int>) -> some View {
        let format: (Int) -> String = { String($0) }
        let parse: (String) -> Int? = { Int($0).map { max(0, $0) } }
        return NumericDraftField(value: value, format: format, parse: parse, minWidth: 44)
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
            // El editor mostraba KG y REPS a pelo, sin mirar el ejercicio: una
            // plancha pedía kilos y repeticiones aquí igual que en la sesión.
            // Mismo descriptor y mismas reglas que la vista en vivo.
            let editorDescriptor = ExerciseCatalog.descriptor(for: exercise.wrappedValue.name)
            HStack {
                Text("SERIE").frame(width: 42, alignment: .leading)
                if editorDescriptor.tracksWeight { Text("KG").frame(maxWidth: .infinity) }
                Text(editorDescriptor.measurement == .reps ? "REPS" : "SEG").frame(maxWidth: .infinity)
                Spacer().frame(width: 27)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(exercise.sets.indices, id: \.self) { setIndex in
                HStack(spacing: 9) {
                    Text("\(setIndex + 1)").font(.caption.bold()).frame(width: 42, alignment: .leading)
                    if editorDescriptor.tracksWeight {
                        editorWeightField(value: exercise.sets[setIndex].weight)
                    }
                    editorNumberField(value: exercise.sets[setIndex].reps)
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
    // Campos propios: antes los segundos se guardaban dentro de `reps`, donde
    // eran indistinguibles de repeticiones e inflaban el volumen.
    var durationSeconds: Double?
    var distanceMeters: Double?
    var completed = false
}

private struct LiveExercise: Identifiable {
    let id = UUID()
    var name: String
    var restSeconds: Int
    var sets: [LiveSet]
    // Cronometrar las series de un ejercicio de repeticiones. No es que el
    // dato sea prescindible —es justo el que alimenta el componente de
    // estaciones del forecast de HYROX, y por eso se importa de Hevy—: es que
    // no siempre se mide. Por eso se activa por ejercicio y no está siempre
    // ocupando sitio, igual que en Hevy.
    var tracksTime = false
}

private struct StrengthSessionMuscleRow: Identifiable {
    var id: String { muscle }
    let muscle: String
    let sessionShare: Int
    let cycleProgress: Int
    let sessionSets: Double
    let cycleSets: Double
    let targetSets: Double
}

private struct StrengthSessionSummary: Identifiable {
    let id = UUID()
    let title: String
    let duration: TimeInterval
    let externalVolume: Double
    let completedSets: Int
    let muscles: [StrengthSessionMuscleRow]

    static func make(for workout: ImportedWorkout, allWorkouts: [ImportedWorkout], endedAt: Date) -> Self {
        let session = workout.effectiveMuscleSets.filter { $0.value > 0 }
        let totalStimulus = session.values.reduce(0, +)
        let cycleStart = Calendar.current.date(byAdding: .day, value: -7, to: endedAt) ?? endedAt
        let cycle = allWorkouts.filter { $0.start >= cycleStart && $0.start <= endedAt }
        let landmarkContext = VolumeLandmarkLearning.context(workouts: allWorkouts, now: endedAt)

        let rows = session.map { muscle, sets -> StrengthSessionMuscleRow in
            let accumulated = cycle.reduce(0.0) { $0 + ($1.effectiveMuscleSets[muscle] ?? 0) }
            let target = MuscleVolumeLandmarkTable.landmarks(
                for: muscle,
                learned: landmarkContext.learnedMRV,
                sustained: landmarkContext.sustainedWeeklySets
            ).mav
            return StrengthSessionMuscleRow(
                muscle: muscle,
                sessionShare: totalStimulus > 0 ? Int((sets / totalStimulus * 100).rounded()) : 0,
                cycleProgress: target > 0 ? Int((accumulated / target * 100).rounded()) : 0,
                sessionSets: sets,
                cycleSets: accumulated,
                targetSets: target
            )
        }.sorted { $0.sessionSets > $1.sessionSets }

        return StrengthSessionSummary(
            title: workout.title,
            duration: workout.end.timeIntervalSince(workout.start),
            externalVolume: workout.exercises.reduce(0) { $0 + $1.volume },
            completedSets: workout.exercises.reduce(0) { $0 + $1.sets },
            muscles: rows
        )
    }
}

private struct StrengthSessionSummaryView: View {
    let summary: StrengthSessionSummary
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EterPageHeader(eyebrow: "Sesión guardada", title: "Entrenamiento completado")
                    Text(summary.title).font(.title3.bold()).foregroundStyle(EterTheme.positive)

                    HStack(spacing: 10) {
                        summaryMetric(value: duration(summary.duration), label: "Duración")
                        summaryMetric(value: "\(Int(summary.externalVolume.rounded()).formatted()) kg", label: "Tonelaje externo")
                        summaryMetric(value: "\(summary.completedSets)", label: "Series")
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Impacto muscular").font(.title2.bold())
                        HStack {
                            Text("Músculo").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Sesión").frame(width: 70, alignment: .trailing)
                            Text("Ciclo").frame(width: 70, alignment: .trailing)
                        }.font(.caption.bold()).foregroundStyle(.secondary)

                        ForEach(summary.muscles) { row in
                            VStack(spacing: 7) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.muscle).font(.subheadline.bold())
                                        Text("Hoy \(number(row.sessionSets)) · ciclo \(number(row.cycleSets))/\(number(row.targetSets)) series")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(row.sessionShare)%").frame(width: 70, alignment: .trailing)
                                    Text("\(row.cycleProgress)%").bold()
                                        .foregroundStyle(cycleColor(row.cycleProgress))
                                        .frame(width: 70, alignment: .trailing)
                                }
                                ProgressView(value: min(1.5, Double(row.cycleProgress) / 100))
                                    .tint(cycleColor(row.cycleProgress))
                            }
                            if row.id != summary.muscles.last?.id { Divider() }
                        }
                    }.cardStyle()

                    Text("Sesión indica cómo se repartió el estímulo efectivo de hoy. Ciclo compara las series efectivas acumuladas en los últimos 7 días con tu volumen semanal óptimo personal; puede superar el 100 %. El tonelaje excluye ejercicios de peso corporal.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)

                    Button("Cerrar resumen", action: onDone).buttonStyle(EterPrimaryButtonStyle())
                }.padding(18)
            }.background(EterTheme.canvas)
        }
    }

    private func summaryMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.headline).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func cycleColor(_ percent: Int) -> Color {
        if percent > 125 { return EterTheme.danger }
        if percent >= 75 { return EterTheme.positive }
        return .orange
    }
}

/// Campo numérico con BORRADOR propio, para kilos y repeticiones.
///
/// Resuelve dos problemas que compartían la misma causa, los dos reportados
/// desde el uso real ("escribir las reps o los kilos es una tortura", "va como
/// congelada la pantalla"):
///
///  1. `TextField(value:format:)` reparsea y REFORMATEA el texto en cada
///     pulsación. Teclear "12" pasa por el valor 1, que se reescribe como "1";
///     borrar hasta vacío salta a "0"; y "0.5" es imposible porque "0." no es
///     un número válido todavía. El formateador pelea con quien escribe. El
///     propio archivo ya había resuelto esto para el campo de tiempo con un
///     borrador de texto — esto es el mismo patrón, aplicado donde faltaba.
///  2. Escribir en el binding del modelo en cada tecla mutaba el `@State` de
///     la vista de entrenamiento entera, así que CADA PULSACIÓN reevaluaba el
///     body completo: todas las tarjetas de ejercicio, todas las filas de
///     serie. Con el borrador dentro de esta vista pequeña, teclear invalida
///     sólo este campo y el modelo se toca una vez, al terminar.
///
/// El commit es al perder el foco y al pulsar "hecho", nunca por carácter.
/// La cabecera de la sesión, en su propia vista.
///
/// Lee las métricas del reloj (pulso, calorías, estado), que llegan cada
/// segundo mientras el Watch graba. Cuando esto vivía dentro del body de
/// LiveStrengthWorkoutView, CADA uno de esos avisos invalidaba el body entero:
/// todas las tarjetas de ejercicio y todos los campos de todas las series se
/// reevaluaban una vez por segundo, encima de los dos TimelineView que ya
/// repintan solos. Separarlo acota el repintado a esta tarjeta.
private struct LiveSessionHeader: View {
    @EnvironmentObject private var watchMetrics: WatchMetricsStore
    @EnvironmentObject private var health: HealthStore
    let startedAt: Date
    let restEndsAt: Date?
    let onAdjustRest: (Int) -> Void

    /// h:mm:ss del tiempo de sesión. Copia local del helper de
    /// LiveStrengthWorkoutView, que es privado a esa vista.
    private func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
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
                HStack(spacing: 8) {
                    restAdjustmentButton("−15", seconds: -15)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .center, spacing: 3) {
                            Text("DESCANSO").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(max(0, Int(restEndsAt.timeIntervalSince(context.date))).formatted() + " s")
                                .font(.title3.monospacedDigit().bold()).foregroundStyle(.orange)
                        }
                    }
                    restAdjustmentButton("+15", seconds: 15)
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
            // El motivo real cuando lo hay, y el texto genérico cuando no:
            // "inícialo tú" es un consejo inútil si lo que pasa es que la app
            // companion no está instalada.
            if let diagnostic = health.watchStartDiagnostic {
                Label(diagnostic, systemImage: "applewatch.slash")
                    .font(.caption2).foregroundStyle(EterTheme.danger)
            } else {
                Text("Abriendo “Fuerza” en el Apple Watch para añadir pulso y calorías reales. Si no se abre, inícialo desde el reloj.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        }.cardStyle()
    }

    private func restAdjustmentButton(_ title: String, seconds: Int) -> some View {
        Button { onAdjustRest(seconds) } label: {
            Text(title).font(.caption.bold()).frame(minWidth: 35, minHeight: 38)
        }
        .buttonStyle(.plain)
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(seconds < 0 ? "Restar 15 segundos al descanso" : "Añadir 15 segundos al descanso")
    }
}

private struct NumericDraftField<Value: Equatable>: View {
    @Binding var value: Value
    let format: (Value) -> String
    let parse: (String) -> Value?
    var keyboard: UIKeyboardType = .numberPad
    var minWidth: CGFloat = 52

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("0", text: $draft)
            .keyboardType(keyboard)
            .multilineTextAlignment(.center)
            .font(.title3.bold().monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(minWidth: minWidth)
            .fieldBox()
            .focused($isFocused)
            .onAppear { draft = format(value) }
            // Un cambio del modelo desde FUERA (los botones +/-, repetir la
            // serie anterior) sí tiene que verse — pero sólo cuando el campo
            // no está enfocado, o le pisaría el texto a quien escribe.
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                draft = format(newValue)
            }
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if nowFocused { return }
                if wasFocused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        // Un borrador ilegible no borra el dato: se descarta y se repinta el
        // valor real. Vaciar el campo a propósito sí cuenta como cero, que es
        // lo que alguien espera al borrarlo todo.
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, let zero = parse("0") { value = zero }
        else if let parsed = parse(trimmed) { value = parsed }
        draft = format(value)
    }
}

/// Equivalente de `NumericDraftField` para una duración manual. El cronómetro
/// puede actualizar `durationSeconds` en directo, pero al teclear no hay razón
/// para mutar la serie ni para invalidar toda la sesión por cada dígito.
///
/// Se escribe como un cronómetro: "410" significa 4:10 y "45", 0:45. El
/// texto queda local hasta perder el foco o pulsar Hecho; entonces, y sólo
/// entonces, se guarda el número de segundos en la serie.
private struct TimedDurationDraftField: View {
    @Binding var durationSeconds: Double?

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("mm:ss", text: $draft)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(minWidth: 30)
            .fieldBox()
            .focused($isFocused)
            .onAppear { draft = formatted(durationSeconds) }
            // Si el cronómetro termina o se repite una serie, el valor del
            // modelo debe reflejarse aquí. Mientras alguien escribe, nunca se
            // le pisa su borrador.
            .onChange(of: durationSeconds) { _, newValue in
                guard !isFocused else { return }
                draft = formatted(newValue)
            }
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if !nowFocused, wasFocused { commit() }
            }
            .onSubmit { commit() }
            .accessibilityLabel("Tiempo de la serie, minutos y segundos")
    }

    private func commit() {
        let digits = String(draft.filter(\.isNumber).suffix(5))
        durationSeconds = digits.isEmpty ? nil : seconds(from: digits)
        draft = formatted(durationSeconds)
    }

    private func seconds(from digits: String) -> Double {
        guard let value = Int(digits) else { return 0 }
        return Double(value / 100 * 60 + value % 100)
    }

    private func formatted(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LiveStrengthWorkoutView: View {
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var watchMetrics: WatchMetricsStore
    @EnvironmentObject private var routineStore: StrengthRoutineStore
    @Environment(\.dismiss) private var dismiss
    let routine: StrengthRoutine
    @State private var exercises: [LiveExercise]
    @State private var startedAt = Date()
    @State private var restEndsAt: Date?
    @State private var showExercisePicker = false
    @State private var exerciseSearch = ""
    @State private var showDiscardConfirmation = false
    @State private var completionSummary: StrengthSessionSummary?
    @State private var hasCompleted = false
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
                // En su propia vista, y no inline: lee pulso, calorías y
                // estado del reloj, que llegan cada segundo mientras el Watch
                // graba. Inline, cada uno de esos avisos invalidaba el body
                // COMPLETO — todas las tarjetas y todos los campos de todas
                // las series. Extraerlo acota el repintado a la cabecera.
                LiveSessionHeader(startedAt: startedAt, restEndsAt: restEndsAt, onAdjustRest: adjustRest)
                    .padding(18).padding(.bottom, 0)
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
            .fullScreenCover(item: $completionSummary) { summary in
                StrengthSessionSummaryView(summary: summary) { dismiss() }
                    .interactiveDismissDisabled()
            }
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
                    restMenu(exercise)
                }
                Spacer()
                // Sólo en los ejercicios de repeticiones: en una plancha o un
                // trineo el tiempo no es opcional, es la medida.
                if descriptor.measurement == .reps {
                    Button { exercise.wrappedValue.tracksTime.toggle() } label: {
                        Image(systemName: exercise.wrappedValue.tracksTime ? "stopwatch.fill" : "stopwatch")
                            .foregroundStyle(exercise.wrappedValue.tracksTime ? EterTheme.positive : .secondary)
                    }
                    .accessibilityLabel(exercise.wrappedValue.tracksTime ? "Dejar de cronometrar las series" : "Cronometrar las series")
                }
                Button(role: .destructive) { exercises.removeAll { $0.id == exercise.wrappedValue.id } } label: { Image(systemName: "trash") }
            }
            HStack {
                Text("#").frame(width: 18, alignment: .leading)
                if descriptor.tracksWeight { Text("KG").frame(maxWidth: .infinity) }
                measurementHeaders(descriptor.measurement, tracksTime: exercise.wrappedValue.tracksTime)
                Image(systemName: "checkmark").frame(width: 44)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(exercise.sets) { $set in
                HStack(spacing: 8) {
                    Text("\((exercise.wrappedValue.sets.firstIndex { $0.id == set.id } ?? 0) + 1)")
                        .font(.subheadline.bold()).frame(width: 18, alignment: .leading)
                    if descriptor.tracksWeight {
                        stepperField(value: $set.weight, step: 2.5, minimum: 0, decimalPlaces: 0...1)
                    }
                    measurementFields(descriptor.measurement, set: $set,
                                      tracksTime: exercise.wrappedValue.tracksTime)
                    completedButton($set, restSeconds: exercise.wrappedValue.restSeconds)
                }
            }
            Button {
                let fallback = LiveSet(weight: 0, reps: descriptor.measurement == .reps ? 10 : 0, type: "normal",
                                       durationSeconds: descriptor.isTimed ? 30 : nil, distanceMeters: nil)
                let previous = exercise.wrappedValue.sets.last ?? fallback
                exercise.wrappedValue.sets.append(LiveSet(weight: previous.weight, reps: previous.reps, type: "normal",
                                                          durationSeconds: previous.durationSeconds,
                                                          distanceMeters: previous.distanceMeters))
            } label: { Label("Añadir serie", systemImage: "plus.circle").font(.caption.bold()) }
        }.cardStyle()
    }

    private func restMenu(_ exercise: Binding<LiveExercise>) -> some View {
        Menu {
            ForEach(Array(stride(from: 30, through: 300, by: 15)), id: \.self) { seconds in
                Button {
                    exercise.wrappedValue.restSeconds = seconds
                    persistRoutinePreferences()
                } label: {
                    if seconds == exercise.wrappedValue.restSeconds {
                        Label(restLabel(seconds), systemImage: "checkmark")
                    } else {
                        Text(restLabel(seconds))
                    }
                }
            }
        } label: {
            Label("Descanso \(restLabel(exercise.wrappedValue.restSeconds))", systemImage: "timer")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityHint("Toca para cambiarlo; Éter lo recordará para este ejercicio en esta rutina")
    }

    private func restLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
            weightField(value: value)
            stepButton(systemImage: "plus") { value.wrappedValue += step }
        }.frame(maxWidth: .infinity)
    }

    private func stepperField(value: Binding<Int>, step: Int, minimum: Int) -> some View {
        HStack(spacing: 3) {
            stepButton(systemImage: "minus") { value.wrappedValue = max(minimum, value.wrappedValue - step) }
            plainNumberField(value: value, minWidth: 52)
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
                .frame(width: 44, height: 46)
        }
        .buttonStyle(.plain)
        .background(set.wrappedValue.completed ? EterTheme.positive : Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .eterTouchTarget()
    }

    @ViewBuilder
    private func measurementHeaders(_ measurement: ExerciseMeasurement, tracksTime: Bool) -> some View {
        switch measurement {
        case .reps:
            Text("REPS").frame(maxWidth: .infinity)
            if tracksTime { Text("TIEMPO").frame(maxWidth: .infinity) }
        case .time:
            Text("TIEMPO").frame(maxWidth: .infinity)
        case .timeAndDistance:
            Text("TIEMPO").frame(maxWidth: .infinity)
            Text("M").frame(maxWidth: .infinity)
        }
    }

    /// Los campos de cada tipo de medición. Extraído de la fila porque el
    /// switch en línea con los TextField dentro ahogaba al type-checker.
    @ViewBuilder
    private func measurementFields(_ measurement: ExerciseMeasurement, set: Binding<LiveSet>,
                                   tracksTime: Bool) -> some View {
        switch measurement {
        case .reps where tracksTime:
            // Con cronómetro activo la fila lleva tres datos, así que las
            // reps pasan a campo plano: dos steppers (6 controles) más el
            // tiempo no caben, y un campo plano sí. Es exactamente lo que
            // hace Hevy, que no usa steppers en ninguna columna.
            plainNumberField(value: set.reps)
            timedSetField(set)
        case .reps:
            stepperField(value: set.reps, step: 1, minimum: 0)
        case .time:
            timedSetField(set)
        case .timeAndDistance:
            timedSetField(set)
            // Metros: 200 m de trineo en 90 s y en 150 s no son la misma
            // serie. Campo plano sin stepper, igual que Hevy — 500 m no se
            // teclean a base de +/-, y es lo que deja sitio para que
            // KG + TIEMPO + M + HECHA quepan en el trineo.
            distanceField(set)
        }
    }

    private func plainNumberField(value: Binding<Int>, minWidth: CGFloat = 30) -> some View {
        let format: (Int) -> String = { String($0) }
        let parse: (String) -> Int? = { Int($0).map { max(0, $0) } }
        return NumericDraftField(value: value, format: format, parse: parse, minWidth: minWidth)
    }

    /// Kilos: acepta coma o punto decimal y muestra el entero sin ".0".
    private func weightField(value: Binding<Double>) -> some View {
        let format: (Double) -> String = {
            $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
        }
        let parse: (String) -> Double? = {
            Double($0.replacingOccurrences(of: ",", with: ".")).map { max(0, $0) }
        }
        return NumericDraftField(value: value, format: format, parse: parse,
                                 keyboard: .decimalPad, minWidth: 60)
    }

    private func distanceField(_ set: Binding<LiveSet>) -> some View {
        // El Binding y los closures con su tipo explícito: en línea, el
        // inferidor no resolvía la expresión en tiempo razonable.
        let meters = Binding<Int>(
            get: { Int(set.wrappedValue.distanceMeters ?? 0) },
            set: { newValue in set.wrappedValue.distanceMeters = newValue > 0 ? Double(newValue) : nil }
        )
        let format: (Int) -> String = { $0 > 0 ? String($0) : "" }
        let parse: (String) -> Int? = { Int($0).map { max(0, $0) } }
        return NumericDraftField(value: meters, format: format, parse: parse, minWidth: 30)
    }

    /// "250" -> "4:10". Cadena vacía para nil, nunca "0:00": un cero se leería
    /// como "lo hizo en cero segundos" en vez de "no medido".
    static func minutesSeconds(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Entrada estilo cronómetro: los dos últimos dígitos son segundos, el
    /// resto minutos. "410" -> 4:10, "45" -> 0:45.
    static func secondsFromDigits(_ digits: String) -> Double {
        guard let value = Int(digits) else { return 0 }
        return Double(value / 100 * 60 + value % 100)
    }

    /// Un ejercicio de repeticiones no necesita tiempo para estar bien
    /// registrado, así que esto es un botón y no una columna: no ocupa sitio
    /// mientras no se use, y cuando se usa la duración va a su propio campo
    /// (nunca dentro de `reps`, que es lo que inflaba el volumen).
    private func optionalTimerButton(_ set: Binding<LiveSet>) -> some View {
        let isTiming = timingSetID == set.wrappedValue.id
        return Button {
            if isTiming {
                if let startedAt = timingStartedAt {
                    set.wrappedValue.durationSeconds = max(0, Date().timeIntervalSince(startedAt).rounded())
                }
                timingSetID = nil; timingStartedAt = nil
            } else {
                timingSetID = set.wrappedValue.id; timingStartedAt = Date()
            }
        } label: {
            if isTiming, let startedAt = timingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.minutesSeconds(context.date.timeIntervalSince(startedAt).rounded()))
                        .font(.caption2.monospacedDigit().bold()).foregroundStyle(.orange)
                        .frame(width: 34, height: 30)
                }
            } else if let seconds = set.wrappedValue.durationSeconds, seconds > 0 {
                Text(Self.minutesSeconds(seconds)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 34, height: 30)
            } else {
                Image(systemName: "stopwatch").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
            }
        }
        .buttonStyle(.plain)
        .background((isTiming ? Color.orange : Color.primary).opacity(isTiming ? 0.22 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .eterTouchTarget()
    }

    /// Isometric holds/carries aren't a "how many" question — you find out the
    /// duration by timing the hold, not by deciding it in advance. Tap once to
    /// start, tap again to stop and commit the elapsed seconds into the set;
    /// still manually editable via the field when the timer isn't running.
    private func timedSetField(_ set: Binding<LiveSet>) -> some View {
        let isTiming = timingSetID == set.wrappedValue.id
        return HStack(spacing: 1) {
            Button {
                if isTiming {
                    if let startedAt = timingStartedAt {
                        set.wrappedValue.durationSeconds = max(0, Date().timeIntervalSince(startedAt).rounded())
                    }
                    timingSetID = nil; timingStartedAt = nil
                } else {
                    timingSetID = set.wrappedValue.id; timingStartedAt = Date()
                }
            } label: {
                Image(systemName: isTiming ? "stop.fill" : "play.fill").font(.caption2.bold()).frame(width: 18, height: 30)
            }
            .buttonStyle(.plain)
            .background((isTiming ? Color.orange : Color.primary).opacity(isTiming ? 0.22 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .eterTouchTarget()

            if isTiming, let startedAt = timingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.minutesSeconds(context.date.timeIntervalSince(startedAt).rounded()))
                        .font(.subheadline.monospacedDigit().bold()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity).fieldBox()
                }
            } else {
                TimedDurationDraftField(durationSeconds: set.durationSeconds)
            }
        }.frame(maxWidth: .infinity)
    }

    private var exercisePicker: some View {
        let compatible = StrengthRoutineBuilder.exerciseLibrary(from: imports).filter {
            InjurySafetyEngine.exerciseSafety($0.name, injuries: InjuryStore.shared.active).allowed
        }
        let filtered = exerciseSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? compatible
            : compatible.filter { exerciseMatchesSearch($0.name, query: exerciseSearch) }
        return NavigationStack {
            List(filtered) { exercise in
                Button {
                    exercises.append(LiveExercise(name: exercise.name, restSeconds: exercise.restSeconds, sets: exercise.sets.map { LiveSet(weight: $0.weight, reps: $0.reps, type: $0.type) }))
                    showExercisePicker = false
                } label: {
                    VStack(alignment: .leading) {
                        Text(exercise.name)
                        if exercise.name == "Lat Pulldown (Cable)" {
                            Text("Pull down · Jalón al pecho · Polea")
                                .font(.caption).foregroundStyle(EterTheme.positive)
                        } else {
                            Text("\(exercise.sets.count) series desde tu historial").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Añadir ejercicio").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $exerciseSearch, prompt: "Ejercicio, pull down, jalón…")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showExercisePicker = false } } }
        }
    }

    private func exerciseMatchesSearch(_ name: String, query: String) -> Bool {
        let normalizedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var terms = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if name == "Lat Pulldown (Cable)" { terms += " pull down pulldown jalon jalon al pecho polea" }
        return normalizedQuery.split(separator: " ").allSatisfy { terms.contains($0) }
    }

    /// El descanso es parte de la receta de una rutina, no una preferencia
    /// global. Guardar la lista viva conserva también los ejercicios añadidos
    /// durante la sesión y hace que el próximo inicio de ESTA rutina recuerde
    /// su descanso sin alterar Push/Pull/Full Body entre sí.
    private func persistRoutinePreferences() {
        let updatedExercises = exercises.map { exercise in
            RoutineExercise(
                name: exercise.name,
                sets: exercise.sets.map {
                    ImportedSet(weight: $0.weight, reps: $0.reps, type: $0.type, rpe: nil,
                                durationSeconds: $0.durationSeconds, distanceMeters: $0.distanceMeters)
                },
                restSeconds: exercise.restSeconds,
                prescriptionNote: routine.exercises.first { $0.name == exercise.name }?.prescriptionNote,
                historySessions: routine.exercises.first { $0.name == exercise.name }?.historySessions
            )
        }
        routineStore.save(StrengthRoutine(name: routine.name,
                                          subtitle: updatedExercises.map(\.name).joined(separator: " · "),
                                          exercises: updatedExercises,
                                          lastPerformed: routine.lastPerformed,
                                          historicalVolume: routine.historicalVolume))
    }

    private func finish() {
        completeSession(notifyWatch: true)
    }

    /// La firma que dispara el envío al reloj: SÓLO lo que el reloj muestra.
    ///
    /// Antes recorría todas las series de todos los ejercicios y las unía en
    /// una cadena. Como `.onChange` la evalúa en cada reevaluación del body, y
    /// el body se reevaluaba en cada pulsación de kilos o reps, eso significaba
    /// construir esa cadena y —al cambiar— MANDAR UN MENSAJE POR WATCHCONNECTIVITY
    /// EN CADA TECLA. Con el reloj no alcanzable, `transferUserInfo` además
    /// encola cada envío en disco. Eso es el "va como congelada la pantalla".
    ///
    /// Ahora depende de la serie siguiente, el recuento y el descanso, que es
    /// exactamente lo que la pantalla del reloj pinta: editar el peso de una
    /// serie ya hecha, o de una que no es la siguiente, no le dice nada nuevo
    /// al reloj y por tanto no manda nada.
    private var workoutContextSignature: String {
        let flattened = exercises.flatMap { exercise in exercise.sets.map { (exercise.name, $0) } }
        let completed = flattened.filter { $0.1.completed }.count
        let next = flattened.first { !$0.1.completed }
        return [next?.0 ?? "", "\(next?.1.weight ?? 0)", "\(next?.1.reps ?? 0)",
                "\(completed)", "\(flattened.count)",
                "\(restEndsAt?.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
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
        guard !hasCompleted else { return }
        hasCompleted = true
        let saved = exercises.compactMap { exercise -> ImportedExercise? in
            let selected = exercise.sets.filter(\.completed)
            let source = selected.isEmpty ? exercise.sets : selected
            guard !source.isEmpty else { return nil }
            // Éter ya cronometra las series isométricas/de acarreo
            // (timedSetField) y guardaba esos segundos SOLO en `reps`, donde
            // son indistinguibles de repeticiones. Con eso, un trineo de 240 s
            // registrado aquí no podía alimentar el componente de estaciones
            // del forecast de Hyrox, que sí lee `durationSeconds` — sólo
            // llegaba por importación de Hevy. Ahora una sesión propia de éter
            // vale igual que una importada.
            //
            // `isTimed` sale de ExerciseCatalog, la única definición de qué
            // ejercicio se mide en tiempo, la misma que decide mostrar "SEG"
            // en vez de "REPS" en la propia sesión.
            //
            // `reps` se conserva tal cual a propósito: cambiar su significado
            // aquí tocaría workingSets (que filtra reps > 0), effectiveSetCount
            // y el volumen, y eso es un cambio de semántica con su propio
            // riesgo, no algo que colar en este PR.
            let details = source.map {
                ExerciseCatalog.loggedSet(weight: $0.weight, reps: $0.reps, type: $0.type, exerciseName: exercise.name,
                                          durationSeconds: $0.durationSeconds, distanceMeters: $0.distanceMeters)
            }
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
        let completedWorkout = ImportedWorkout(title: routine.name, start: startedAt, end: endedAt,
                                               exercises: saved, muscleSets: [:])
        imports.addStrengthWorkout(title: routine.name, start: startedAt, end: endedAt, exercises: saved)
        if notifyWatch && watchMetrics.isRunning {
            watchMetrics.finish()
        } else if !watchMetrics.isRunning && notifyWatch {
            Task { await health.saveStrengthWorkout(start: startedAt, end: endedAt) }
        }
        completionSummary = StrengthSessionSummary.make(for: completedWorkout,
                                                        allWorkouts: imports.workouts,
                                                        endedAt: endedAt)
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
