import SwiftUI
import UniformTypeIdentifiers
import Charts

// Chaining several independent `.fileImporter`/`.sheet` modifiers on the same
// view is unreliable — SwiftUI can end up only ever presenting the first one
// (or silently dropping the others), so a button that sets one of several
// sibling booleans/optionals can end up doing nothing when tapped. This view
// used to have three separate `.fileImporter`s and six separate `.sheet`s;
// folding each family into one `.fileImporter`/`.sheet(item:)` keyed by an
// enum keeps exactly one of each attached here, which SwiftUI actually
// handles reliably. (BodyComposition/LifestyleFactors sheets stay separate:
// their booleans are owned by child card views, not this one.)
private enum ContentImporter: Equatable {
    case dataFiles, backupRestore, automaticBackupFolder
}

private enum ContentSheet: Identifiable {
    case checkIn
    case workoutReview(RecentTrainingSession)
    case workoutDetail(RecentTrainingSession)
    case goalEditor
    case injuryHistory
    case travel

    var id: String {
        switch self {
        case .checkIn: return "checkIn"
        case .workoutReview(let session): return "workoutReview-\(session.id)"
        case .workoutDetail(let session): return "workoutDetail-\(session.id)"
        case .goalEditor: return "goalEditor"
        case .injuryHistory: return "injuryHistory"
        case .travel: return "travel"
        }
    }
}

// Same reasoning as above, for the three `.confirmationDialog`s that used to
// be chained here — this is what was actually breaking "Restaurar": picking
// a backup file called `importBackup`, which sets `pendingBackup`, but the
// confirmation dialog that's supposed to appear next silently never did, so
// nothing ever reached `restorePendingBackup()`. The three underlying
// optionals (pendingBackup, workoutPendingDeletion,
// importedWorkoutPendingDeletion) stay as they were; only the presentation
// is unified into one dialog that shows whichever is set.
private enum ConfirmationKind { case restoreBackup, deleteWorkout, deleteImportedWorkout }

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var checkIns: DailyCheckInStore
    @EnvironmentObject private var lifestyle: LifestyleFactorStore
    @EnvironmentObject private var workoutReviews: WorkoutReviewStore
    @EnvironmentObject private var planHistory: PlanHistoryStore
    @EnvironmentObject private var strengthRoutines: StrengthRoutineStore
    @EnvironmentObject private var goals: GoalStore
    @EnvironmentObject private var injuries: InjuryStore
    @EnvironmentObject private var travel: TravelEpisodeStore
    @EnvironmentObject private var watchMetrics: WatchMetricsStore
    @EnvironmentObject private var twinStates: TwinStateStore
    @State private var activeImporter: ContentImporter?
    // Set together with activeImporter at the moment each button is tapped,
    // and read inside .fileImporter's onCompletion below. Deliberately NOT
    // read via activeImporter there: SwiftUI clears activeImporter (through
    // the isPresented binding's dismiss) around the same moment it invokes
    // onCompletion, and reading a @State var races that clear — this was the
    // actual cause of "Restaurar" silently doing nothing after picking a
    // file. This closure captures what to do at tap time instead, so there's
    // nothing left to race.
    @State private var importerCompletion: (Result<[URL], any Error>) -> Void = { _ in }
    @State private var selectedTab = 0
    @State private var activeSheet: ContentSheet?
    @State private var showLifestyleFactors = false
    @State private var lifestyleFactorPendingEdit: LifestyleEvent?
    @State private var simulatedDecision: SimulatedDecision = .rest
    @State private var workoutPendingDeletion: HealthWorkout?
    @State private var showBodyComposition = false
    @State private var bodyMeasurementPendingEdit: BodyMeasurement?
    @State private var importedWorkoutPendingDeletion: String?
    @State private var showBackupExporter = false
    @State private var backupDocument: EterBackupDocument?
    @State private var pendingBackup: EterBackup?
    @State private var backupMessage: String?
    @State private var todayStrengthRoutine: StrengthRoutine?
    @State private var automaticBackupRevision = 0
    @StateObject private var dashboard = DashboardViewModel()

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        TabView(selection: $selectedTab) {
            appPage { todayPage }
                .tabItem { Label("Hoy", systemImage: "sparkles") }.tag(0)
            appPage { performancePage }
                .tabItem { Label("Rendimiento", systemImage: "figure.run") }.tag(1)
            appPage { StrengthTrainingView() }
                .tabItem { Label("Fuerza", systemImage: "dumbbell.fill") }.tag(2)
            appPage { healthPage }
                .tabItem { Label("Salud", systemImage: "heart.text.square") }.tag(3)
            appPage { dataPage }
                .tabItem { Label("Datos", systemImage: "externaldrive") }.tag(4)
        }
        .fileImporter(
            isPresented: Binding(get: { activeImporter != nil }, set: { if !$0 { activeImporter = nil } }),
            allowedContentTypes: {
                switch activeImporter {
                case .dataFiles: return [.commaSeparatedText, .pdf]
                case .backupRestore: return [.json]
                case .automaticBackupFolder: return [.folder]
                case nil: return [.item]
                }
            }(),
            allowsMultipleSelection: activeImporter == .dataFiles
        ) { result in
            importerCompletion(result)
            activeImporter = nil
        }
        .fileExporter(isPresented: $showBackupExporter, document: backupDocument, contentType: .json,
                      defaultFilename: backupFilename) { result in
            switch result {
            case .success: backupMessage = "Copia guardada correctamente."
            case .failure(let error): backupMessage = "No se pudo guardar la copia: \(error.localizedDescription)"
            }
            backupDocument = nil
        }
        .alert(activeAlert?.title ?? "", isPresented: Binding(
            get: { activeAlert != nil },
            set: { if !$0 { imports.message = nil; health.errorMessage = nil; backupMessage = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(activeAlert?.message ?? "") }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { activeConfirmationKind != nil },
                set: { if !$0 { pendingBackup = nil; workoutPendingDeletion = nil; importedWorkoutPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            // Each case captures its data into a local constant right here,
            // where the dialog's buttons are built, instead of re-reading the
            // @State var inside a button's tap action — SwiftUI clears these
            // @State vars via the isPresented binding's dismiss around the
            // same moment a button's action runs, and re-reading them there
            // races that clear (the same bug that made "Restaurar" silently
            // do nothing after picking a file).
            switch activeConfirmationKind {
            case .restoreBackup:
                if let backup = pendingBackup {
                    Button("Fusionar con mis datos") { restorePendingBackup(backup) }
                }
                Button("Cancelar", role: .cancel) { pendingBackup = nil }
            case .deleteWorkout:
                if let workout = workoutPendingDeletion {
                    Button("Eliminar de Éter y Apple Salud", role: .destructive) {
                        workoutPendingDeletion = nil
                        Task {
                            if await health.deleteWorkout(id: workout.id) {
                                if workout.source.localizedCaseInsensitiveContains("eter") { imports.deleteStrengthWorkout(near: workout.date) }
                            }
                        }
                    }
                }
                Button("Cancelar", role: .cancel) { workoutPendingDeletion = nil }
            case .deleteImportedWorkout:
                if let id = importedWorkoutPendingDeletion {
                    Button("Eliminar de Éter", role: .destructive) {
                        imports.deleteWorkout(id: id); workoutReviews.delete(workoutID: "hevy-\(id)")
                        importedWorkoutPendingDeletion = nil
                    }
                }
                Button("Cancelar", role: .cancel) { importedWorkoutPendingDeletion = nil }
            case nil:
                EmptyView()
            }
        } message: {
            switch activeConfirmationKind {
            case .restoreBackup:
                Text((pendingBackup?.summary ?? "") + "\nLa restauración no borrará los datos actuales.")
            case .deleteWorkout:
                Text("Se eliminará el entrenamiento y dejará de afectar a carga, recuperación y predicciones. Esta acción no se puede deshacer.")
            case .deleteImportedWorkout:
                Text("Se eliminará de los cálculos de carga y recuperación. El archivo CSV original no se modifica.")
            case nil:
                EmptyView()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .checkIn:
                DailyCheckInView(existing: checkIns.entry()).environmentObject(checkIns)
            case .workoutReview(let session):
                WorkoutReviewView(workoutID: session.id, title: session.title, date: session.date,
                                  existing: workoutReviews.review(for: session.id))
                    .environmentObject(workoutReviews)
                    .environmentObject(planHistory)
            case .workoutDetail(let session):
                WorkoutDetailView(session: session).environmentObject(health).environmentObject(imports)
            case .goalEditor:
                GoalEditorView(profile: goals.profile).environmentObject(goals)
            case .injuryHistory:
                InjuryHistoryView().environmentObject(injuries)
            case .travel:
                TravelView().environmentObject(travel)
            }
        }
        .sheet(isPresented: $showLifestyleFactors) {
            LifestyleFactorView(existing: lifestyleFactorPendingEdit).environmentObject(lifestyle).environmentObject(health)
        }
        .sheet(isPresented: $showBodyComposition) {
            BodyCompositionView(existing: bodyMeasurementPendingEdit).environmentObject(health)
        }
        .fullScreenCover(item: $todayStrengthRoutine) { routine in
            LiveStrengthWorkoutView(routine: routine)
                .environmentObject(imports)
                .environmentObject(health)
        }
        .onChange(of: health.lastUpdated) { _, _ in
            refreshDashboard()
            captureCurrentPlanIfNeeded()
            syncWatchSummary()
            performAutomaticBackupIfNeeded()
        }
        .onReceive(checkIns.objectWillChange) { _ in
            Task { @MainActor in await Task.yield(); refreshDashboard(); captureCurrentPlanIfNeeded(); syncWatchSummary() }
        }
        .onReceive(lifestyle.objectWillChange) { _ in
            Task { @MainActor in await Task.yield(); refreshDashboard(); captureCurrentPlanIfNeeded(); syncWatchSummary() }
        }
        .onChange(of: imports.workoutCount) { _, _ in refreshDashboard(); captureCurrentPlanIfNeeded(); syncWatchSummary() }
        // syncWatchSummary sólo estaba enganchado a CAMBIOS (lastUpdated,
        // check-in, estilo de vida, importaciones). Con la app abierta y nada
        // cambiando, el iPhone no enviaba nada nunca y el reloj se quedaba en
        // "Esperando datos" — el síntoma exacto. Esto lo envía también cuando
        // hay permiso de Salud (que es cuando el guard de syncWatchSummary
        // deja de rechazarlo) y cada vez que la app vuelve a primer plano.
        .onChange(of: health.authorizationRequested) { _, granted in
            if granted { syncWatchSummary() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { syncWatchSummary() }
        }
        // performAutomaticBackupIfNeeded() used to also run from onAppear,
        // which fires the instant this view mounts — before health.prepare()'s
        // async HealthKit fetch (kicked off separately at the App level) has
        // populated anything. Since the write is throttled to once per
        // calendar day, that early call almost always won the race, writing
        // a backup with HealthStore still at its empty startup defaults and
        // then blocking the real write from the onChange above (which fires
        // once refresh() actually completes) for the rest of the day — the
        // dashboard would show that day's Health data as stale or missing
        // even though the device itself had it all along. onChange alone is
        // sufficient: it already fires on the initial refresh and on every
        // later HealthKit background-delivery update.
        // syncWatchSummary aquí también: si el permiso de Salud ya estaba
        // concedido antes de que esta vista apareciera, ningún onChange llega a
        // dispararse y el reloj se quedaría esperando igual.
        .onAppear { refreshDashboard(); syncWatchSummary() }
    }

    // Type erasure is intentional at the navigation boundary. Each tab contains a
    // large, independent SwiftUI tree; exposing all five concrete generic types to
    // TabView caused recursive metadata substitution and an EXC_BAD_ACCESS on launch.
    private func appPage<Content: View>(@ViewBuilder content: () -> Content) -> AnyView {
        AnyView(AppScaffold(isLoading: health.isLoading, content: content))
    }

    // PR1.5: the one real-store read every TwinCore call site below shares,
    // instead of each repeating the same six labels.
    private var twinContext: TwinContext {
        TwinContext(profile: goals.profile, events: lifestyle.events, reviews: workoutReviews.reviews,
                   activeInjuries: injuries.active, calibration: twinStates.calibration,
                   personalAnchor: twinStates.personalAnchor(),
                   // PR15: el episodio activo, resuelto en UN sitio
                   // (TravelEpisodeStore.currentEpisode) para que la tarjeta de
                   // Viajes, el gemelo y el plan no puedan elegir episodios
                   // distintos.
                   travel: travel.currentEpisode(), travelHistory: travel.episodes)
    }

    private func refreshDashboard() {
        guard health.authorizationRequested else { return }
        dashboard.refresh(health: health, imports: imports, checkIn: checkIns.entry(),
                         profile: goals.profile, events: lifestyle.events, reviews: workoutReviews.reviews,
                         activeInjuries: injuries.active, calibration: twinStates.calibration,
                         personalAnchor: twinStates.personalAnchor(),
                         travel: travel.currentEpisode(), travelHistory: travel.episodes)
    }

    private var currentAssessment: TwinAssessment {
        dashboard.assessment ?? TwinEngine.assess(
            health: health, imports: imports, checkIn: checkIns.entry(), context: twinContext
        )
    }

    private var currentPlan: WeeklyPlanStatus {
        dashboard.plan ?? TrainingPlanEngine.status(
            health: health, imports: imports, readiness: currentAssessment.score,
            muscles: currentAssessment.muscles, checkIn: checkIns.entry(), context: twinContext,
            physiologicalAlert: currentAssessment.physiologicalAlert
        )
    }

    @ViewBuilder private var todayPage: some View {
        if !health.authorizationRequested {
            permissionCard
        } else {
            VStack(alignment: .leading, spacing: 18) {
                EterPageHeader(eyebrow: "Hoy", title: "Tu estado real")
                dailyCheckInCard
                lifestyleFactorCard
                physiologicalAlertCard
                twinCard
                currentPlanCard
                proposedWorkoutCard
                // Simular decisión antes de la semana: la lógica es
                // "¿qué pasaría si...?" primero, "así queda tu semana
                // resultante" después — no al revés.
                decisionSimulatorCard
                WhatIfSimulatorCardView()
                weekAheadCard
                LazyVGrid(columns: columns, spacing: 12) {
                    metric("Sueño", value: String(format: "%.1f", health.snapshot.sleepHours), unit: "h", icon: "moon.fill",
                           insight: todayComparisonInsight(health.sleepHistory, unit: "h"))
                    metric("HRV", value: health.snapshot.hrv.formatted(), unit: "ms", icon: "waveform.path.ecg",
                           insight: todayComparisonInsight(health.hrvHistory, unit: "ms", decimals: 0))
                    metric("Pulso", value: health.snapshot.heartRate.formatted(), unit: "ppm", icon: "heart.fill")
                    metric("Energía", value: health.snapshot.activeEnergy.formatted(), unit: "kcal", icon: "flame.fill")
                    // 10.000 stays as the general reference ceiling (not a
                    // precise clinical cutoff), but the actual daily target
                    // is personalized: progressedCeiling ratchets it up from
                    // this person's own recent habitual average — the same
                    // "don't jump more than ~15%" logic already used for
                    // run/bike/swim weekly minutes — instead of handing
                    // everyone the same number regardless of where they start.
                    metric("Pasos", value: health.snapshot.steps.formatted(), unit: "", icon: "figure.walk",
                           insight: stepsInsight)
                }
                latestSessionCard
                updateControl
            }
        }
    }

    @ViewBuilder private var latestSessionCard: some View {
        if let workout = health.recentWorkouts.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("ÚLTIMA SESIÓN").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Image(systemName: "applewatch").font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workout.activity).font(.headline)
                        Text("\(workout.date.formatted(date: .abbreviated, time: .shortened)) · \(Int(workout.durationMinutes.rounded())) min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if let calories = workout.calories { Text("\(Int(calories.rounded())) kcal").font(.caption.bold()) }
                        Button(role: .destructive) { workoutPendingDeletion = workout } label: {
                            Label("Eliminar", systemImage: "trash").font(.caption2.bold())
                        }.buttonStyle(.plain)
                    }
                }
            }.cardStyle()
        }
    }

    private var updateControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { Task { await health.refresh() } } label: {
                HStack { Image(systemName: "arrow.clockwise"); Text(health.isLoading ? "Actualizando…" : "Actualizar ahora").bold(); Spacer() }
                    .eterInsetStyle()
            }.disabled(health.isLoading)
            if let date = health.lastUpdated { Text("Última lectura: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var physiologicalAlertCard: some View {
        // Reads the exact same alert TrainingPlanEngine.status now hard-gates
        // on (via currentAssessment.physiologicalAlert) instead of a second,
        // independently-computed one — the card and the actual plan can no
        // longer show a "prioriza recuperación" alert next to a proposal
        // that ignores it.
        if let alert = currentAssessment.physiologicalAlert {
            PhysiologicalAlertCard(alert: alert, trust: physiologicalAlertTrust(alert))
        }
    }

    private func physiologicalAlertTrust(_ alert: PhysiologicalAlert) -> DataTrust {
        DataTrust(
            nature: .inferred, source: "Línea base personal + check-in",
            measuredAt: alert.signals.compactMap(\.measuredAt).max(), samples: alert.signals.count,
            level: alert.confidence.level,
            explanation: alert.confidence.reason + " La alerta exige una desviación marcada o varias señales adversas coincidentes.",
            limitations: "No es diagnóstico médico. Apple Watch puede producir lecturas atípicas y una señal aislada debe confirmarse."
        )
    }

    private var dataSources: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                importerCompletion = { result in if case .success(let urls) = result { imports.importFiles(urls) } }
                activeImporter = .dataFiles
            } label: {
                HStack {
                    if imports.isImporting { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.down") }
                    Text(imports.isImporting ? "Importando archivos…" : "Importar CSV o PDF").bold()
                    Spacer(); if !imports.isImporting { Image(systemName: "plus") }
                }.eterInsetStyle()
            }.disabled(imports.isImporting)
            HStack(spacing: 10) {
                sourceCount("Entrenamientos Hevy", value: imports.workoutCount)
                sourceCount("Resultados clínicos", value: imports.labCount)
            }
            sourceCount("Sesiones de Apple Salud · 30 días", value: health.recentWorkouts.count)
            VStack(alignment: .leading, spacing: 8) {
                Label("Apple Salud conectado", systemImage: "checkmark.circle.fill").foregroundStyle(EterTheme.positive)
                Text("Sueño, actividad, corazón, VO₂ máx. y entrenamientos se leen desde HealthKit. CSV y PDF permanecen guardados dentro de esta instalación.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }.cardStyle()
        }
    }

    private var backupCard: some View {
        let _ = automaticBackupRevision
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copia y restauración").font(.headline)
                    Text("Todos los datos creados o importados en Éter").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "externaldrive.badge.icloud").font(.title2).foregroundStyle(.teal)
            }
            Text("Incluye entrenamientos importados, analíticas, check-ins, factores, valoraciones, historial del plan, estados diarios del gemelo y rutinas personalizadas.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            HStack(spacing: 10) {
                Button { exportBackup() } label: { Label("Exportar copia", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Button {
                    importerCompletion = { result in importBackup(result) }
                    activeImporter = .backupRestore
                } label: { Label("Restaurar", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copia automática diaria").font(.subheadline.bold())
                    if let folder = EterBackupManager.automaticFolderName {
                        Label(folder, systemImage: "folder.fill").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Elige una carpeta de iCloud Drive o Archivos.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(EterBackupManager.automaticBackupEnabled ? "Cambiar" : "Activar") {
                    importerCompletion = { result in configureAutomaticBackup(result) }
                    activeImporter = .automaticBackupFolder
                }.buttonStyle(.bordered)
            }
            if let last = EterBackupManager.automaticLastSuccess {
                Label("Última copia: \(last.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud.fill")
                    .font(.caption2).foregroundStyle(EterTheme.positive)
            }
            if EterBackupManager.automaticBackupEnabled {
                HStack {
                    Text("Un único archivo se reemplaza una vez al día al abrir o actualizar Éter.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    // The once-a-day throttle means new imports or fixes made
                    // after today's automatic write won't reach the file (and
                    // whatever reads it, e.g. a dashboard sync) until tomorrow
                    // — this lets that be forced immediately instead.
                    Button("Sincronizar ahora") { performAutomaticBackupIfNeeded(force: true) }.font(.caption2)
                    Button("Desactivar", role: .destructive) {
                        EterBackupManager.disableAutomaticBackup()
                        automaticBackupRevision += 1
                    }.font(.caption2)
                }
            }
            Text("Los datos originales de Apple Salud no se duplican: volverán a leerse de HealthKit en este iPhone.")
                .font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }


    private var performancePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            EterPageHeader(eyebrow: "Rendimiento", title: "Objetivo híbrido")
            trainingRoadmapCard
            goalDistanceCard
            hyroxForecastCard
            triathlonForecastCard
            RunningPerformanceView(
                running: dashboard.running ?? RunningPerformanceEngine.summarize(
                    workouts: health.workoutHistory,
                    zones: health.runningHeartRateZones,
                    reviews: workoutReviews.reviews
                ),
                plan: currentPlan
            )
            performanceDashboard
            heartZoneChart
            trainingAnalytics
            recentTraining
        }
    }

    private var goalDistanceCard: some View {
        let running = dashboard.running ?? RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory, zones: health.runningHeartRateZones,
            reviews: workoutReviews.reviews
        )
        let strength = StrengthProgressEngine.summarize(imports.workouts)
        let distances = GoalDistanceEngine.evaluate(
            goals: goals.activeGoals, running: running, strength: strength,
            importedWorkouts: imports.workouts, healthWorkouts: health.workoutHistory
        )
        return VStack(alignment: .leading, spacing: 14) {
            EterSectionHeader("Dónde estás y qué falta", eyebrow: "Distancia al objetivo")
            ForEach(distances) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.goal.title).font(.headline)
                        if let days = item.daysRemaining {
                            Text("\(days) días").font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(item.confidence.color).frame(width: 7, height: 7)
                        Text(item.confidence.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        goalDistanceMetric("Actual", item.current)
                        goalDistanceMetric("Objetivo", item.target)
                    }
                    if let progress = item.progress {
                        ProgressView(value: progress).tint(goalDistanceColor(item.state))
                        Text("Proximidad de marca \(Int((progress * 100).rounded()))% · \(item.gap)")
                            .font(.caption.bold()).foregroundStyle(goalDistanceColor(item.state))
                    } else {
                        Text(item.gap).font(.caption).foregroundStyle(.secondary).lineSpacing(2)
                    }
                    Text(item.evidence).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if item.id != distances.last?.id { Divider() }
            }
            Text("La proximidad compara la marca actual estimada con el objetivo; no representa el porcentaje de preparación total para competir.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    @ViewBuilder private var hyroxForecastCard: some View {
        if let goal = goals.goal(.hyrox) {
            let running = dashboard.running ?? RunningPerformanceEngine.summarize(
                workouts: health.workoutHistory, zones: health.runningHeartRateZones,
                reviews: workoutReviews.reviews
            )
            let forecast = HyroxForecastEngine.forecast(
                running: running, workouts: imports.workouts,
                division: goal.hyroxDivision ?? .open,
                vo2Max: health.vo2MaxHistory.last?.value,
                bodyFatPercentage: health.bodyFatHistory.last?.value
            )
            HyroxForecastCard(
                goal: goal, forecast: forecast,
                measuredAt: [health.lastUpdated, imports.workouts.first?.start].compactMap { $0 }.max()
            )
        }
    }

    @ViewBuilder private var triathlonForecastCard: some View {
        if let goal = goals.activeGoals.first(where: { $0.kind == .triathlon || $0.kind == .ironman }) {
            let running = dashboard.running ?? RunningPerformanceEngine.summarize(
                workouts: health.workoutHistory, zones: health.runningHeartRateZones,
                reviews: workoutReviews.reviews
            )
            let forecast = TriathlonForecastEngine.forecast(
                distance: goal.resolvedTriathlonDistance ?? .olympic,
                running: running, workouts: health.workoutHistory, courseDetails: goal.courseDetails
            )
            TriathlonForecastCard(
                goal: goal, forecast: forecast,
                measuredAt: [health.lastUpdated, imports.workouts.first?.start].compactMap { $0 }.max()
            )
        }
    }

    private func goalDistanceMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalDistanceColor(_ state: GoalDistanceState) -> Color {
        switch state {
        case .achieved: return EterTheme.positive
        case .close: return EterTheme.primary
        case .progressing: return EterTheme.warning
        case .missingTarget, .insufficientData: return .secondary
        }
    }

    private var healthPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            EterPageHeader(eyebrow: "Salud", title: "Evolución fisiológica")
            PhysiologicalHealthView()
            HabitInsightsCardView()
            BodyCompositionCardView(
                showBodyComposition: $showBodyComposition,
                bodyMeasurementPendingEdit: $bodyMeasurementPendingEdit
            )
            LifestyleHistoryCardView(
                showLifestyleFactors: $showLifestyleFactors,
                lifestyleFactorPendingEdit: $lifestyleFactorPendingEdit
            )
            ClinicalHealthSectionView()
        }
    }



    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            EterPageHeader(eyebrow: "Datos", title: "Fuentes y configuración")
            dataSources
            backupCard
            injuryCard
            travelCard
            updateControl
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    EterSectionHeader("Perfil híbrido", eyebrow: "Objetivos activos")
                    Spacer(); Button("Editar") { activeSheet = .goalEditor }.buttonStyle(.bordered)
                }
                ForEach(goals.activeGoals) { goal in
                    HStack {
                        Circle().fill(goal.priority == .primary ? Color.orange : Color.teal.opacity(0.7)).frame(width: 7, height: 7)
                        Text(goal.title).font(.subheadline)
                        Spacer()
                        Text([goal.date?.formatted(date: .abbreviated, time: .omitted), goal.displayTarget].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(goals.profile.trainingDaysPerWeek) días/semana · \(goals.profile.gymAvailable ? "gimnasio disponible" : "sin gimnasio")")
                    .font(.caption2).foregroundStyle(.secondary)
            }.cardStyle()
        }
    }

    private var injuryCard: some View {
        Button { activeSheet = .injuryHistory } label: {
            HStack(spacing: 13) {
                Image(systemName: "cross.case.fill").font(.title2).foregroundStyle(injuries.active.isEmpty ? .teal : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lesiones y restricciones").font(.headline).foregroundStyle(.primary)
                    Text(injuries.active.isEmpty ? "No hay restricciones activas" : "\(injuries.active.count) activas · afectan a las recomendaciones")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            // El mismo defecto latente que la tarjeta de Viajes: aquí sólo no
            // se notaba porque el texto es más ancho y cubre el punto donde
            // uno pulsa por costumbre.
            .contentShape(Rectangle())
        }.buttonStyle(.plain).cardStyle()
    }

    // PR14: el viaje se da de alta como episodio, no se marca cada día. La
    // tarjeta muestra la fase actual porque es la respuesta a "¿sigo en
    // viaje?, ¿cuánto tiempo?", que es justo lo que el check diario no podía
    // responder.
    private var travelCard: some View {
        let current = travel.currentEpisode()
        return Button { activeSheet = .travel } label: {
            HStack(spacing: 13) {
                Image(systemName: "airplane").font(.title2).foregroundStyle(current == nil ? .teal : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Viajes").font(.headline).foregroundStyle(.primary)
                    if let current {
                        Text("\(current.title) · \(current.phase(at: Date()).rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Sin viajes en curso").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            // PR15: sin esto, el área tappable es sólo el CONTENIDO del label
            // — el Spacer no es hit-testable, así que la tarjeta parece
            // pulsable en todo su ancho y no responde en la mitad derecha.
            // Encontrado en el simulador: tocar sobre "Viajes" abría la hoja y
            // tocar 90 pt a la derecha no hacía nada.
            .contentShape(Rectangle())
        }.buttonStyle(.plain).cardStyle()
    }

    private var activeAlert: (title: String, message: String)? {
        if let message = imports.message { return ("Importación", message) }
        if let message = health.errorMessage { return ("Apple Salud", message) }
        if let message = backupMessage { return ("Copia de seguridad", message) }
        return nil
    }

    private var activeConfirmationKind: ConfirmationKind? {
        if pendingBackup != nil { return .restoreBackup }
        if workoutPendingDeletion != nil { return .deleteWorkout }
        if importedWorkoutPendingDeletion != nil { return .deleteImportedWorkout }
        return nil
    }

    private var confirmationTitle: String {
        switch activeConfirmationKind {
        case .restoreBackup: return "¿Restaurar esta copia?"
        case .deleteWorkout: return "¿Eliminar esta sesión?"
        case .deleteImportedWorkout: return "¿Eliminar el entrenamiento importado?"
        case nil: return ""
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return "eter-copia-\(formatter.string(from: Date()))"
    }

    private func exportBackup() {
        let backup = EterBackupManager.make(imports: imports, checkIns: checkIns, lifestyle: lifestyle,
                                             workoutReviews: workoutReviews, planHistory: planHistory,
                                             strengthRoutines: strengthRoutines, health: health, travel: travel)
        backupDocument = EterBackupDocument(backup: backup)
        showBackupExporter = true
    }

    private func importBackup(_ result: Result<[URL], any Error>) {
        do {
            let url = try result.get().first ?? { throw EterBackupError.unreadableFile }()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            pendingBackup = try EterBackupCodec.decode(Data(contentsOf: url))
        } catch {
            backupMessage = "No se pudo leer la copia: \(error.localizedDescription)"
        }
    }

    private func restorePendingBackup(_ backup: EterBackup) {
        pendingBackup = nil
        EterBackupManager.restore(backup, imports: imports, checkIns: checkIns, lifestyle: lifestyle,
                                  workoutReviews: workoutReviews, planHistory: planHistory,
                                  strengthRoutines: strengthRoutines, travel: travel)
        backupMessage = "Restauración terminada. Se han procesado \(backup.totalRecords) registros."
    }

    private func configureAutomaticBackup(_ result: Result<[URL], any Error>) {
        do {
            guard let folder = try result.get().first else { throw EterBackupError.automaticFolderUnavailable }
            try EterBackupManager.configureAutomaticBackup(folder: folder)
            try EterBackupManager.writeAutomaticBackupIfNeeded(
                imports: imports, checkIns: checkIns, lifestyle: lifestyle,
                workoutReviews: workoutReviews, planHistory: planHistory,
                strengthRoutines: strengthRoutines, health: health, travel: travel, force: true
            )
            automaticBackupRevision += 1
            backupMessage = "Copia automática activada en \(folder.lastPathComponent)."
        } catch {
            backupMessage = "No se pudo activar la copia automática: \(error.localizedDescription)"
        }
    }

    private func performAutomaticBackupIfNeeded(force: Bool = false) {
        do {
            let written = try EterBackupManager.writeAutomaticBackupIfNeeded(
                imports: imports, checkIns: checkIns, lifestyle: lifestyle,
                workoutReviews: workoutReviews, planHistory: planHistory,
                strengthRoutines: strengthRoutines, health: health, travel: travel, force: force
            )
            if written { automaticBackupRevision += 1 }
        } catch {
            // Keep the last valid file intact and retry on the next app launch.
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tu salud, conectada.")
                .font(.largeTitle).fontDesign(.serif)
            Text("Éter necesita tu permiso para leer sueño, actividad y señales cardíacas. Tus permisos se pueden revocar en cualquier momento desde Ajustes.")
                .foregroundStyle(.secondary).lineSpacing(4)
            Button {
                Task { await health.authorize() }
            } label: {
                HStack { Text("Conectar con Salud"); Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(EterPrimaryButtonStyle())
            .disabled(health.isLoading)
        }
        .cardStyle()
    }

    private var performanceDashboard: some View {
        let summary = dashboard.performance ?? PerformanceEngine.summarize(health: health, imports: imports)
        return VStack(alignment: .leading, spacing: 16) {
            trainingBalanceCard
            weeklySummary(summary)
            trainingLoadCard(summary)
            TrainingScenarioCardView()
            intensityFocusCard(summary)
            activityCalendar(summary)
            baselineCard("HRV personal", unit: "ms", points: health.hrvHistory, favorableHigh: true, color: .purple)
            baselineCard("Pulso en reposo personal", unit: "ppm", points: health.restingHeartRateHistory, favorableHigh: false, color: .red)
            capacityCard
            heartRateRecoveryCard
        }
    }

    private var trainingBalanceCard: some View {
        let balance = dashboard.balance ?? PerformanceEngine.balance(health: health, imports: imports, context: twinContext)
        return VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("EQUILIBRIO DEL ENTRENAMIENTO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                Text(balance.headline).font(.title2).fontDesign(.serif)
                Text(balance.phase).font(.subheadline.bold()).foregroundStyle(EterTheme.positive)
            }
            Text(balance.explanation).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            balanceBar("Running", balance.runningScore, .blue)
            balanceBar("Fuerza", balance.strengthScore, .indigo)
            balanceBar("Intensidad", balance.intensityScore, .orange)
            balanceBar("Recuperación", balance.recoveryScore, .green)
            Divider()
            Text("SIGUIENTE AJUSTE").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            ForEach(balance.nextPriorities.prefix(2), id: \.self) { priority in
                HStack(alignment: .top, spacing: 8) { Image(systemName: "arrow.right.circle.fill").foregroundStyle(.teal); Text(priority).font(.caption).lineSpacing(2) }
            }
            Text("Perfil actual: " + goals.activeGoals.map { goal in
                [goal.title, goal.displayTarget].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " · ") + ".")
                .font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func balanceBar(_ name: String, _ score: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(name).font(.caption); Spacer(); Text("\(score)%").font(.caption2.monospacedDigit()) }
            GeometryReader { proxy in
                ZStack(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.10)); Capsule().fill(color).frame(width: proxy.size.width * Double(score) / 100) }
            }.frame(height: 8)
        }
    }

    private func weeklySummary(_ summary: PerformanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("Resumen semanal").font(.headline); Text("Últimos 7 días").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(summary.sessionChange == 0 ? "=" : summary.sessionChange > 0 ? "+\(summary.sessionChange)" : "\(summary.sessionChange)")
                    .font(.subheadline.bold()).foregroundStyle(summary.sessionChange >= 0 ? .green : .orange)
            }
            LazyVGrid(columns: columns, spacing: 14) {
                performanceMetric("Sesiones", "\(summary.sessions)", "figure.run")
                performanceMetric("Duración", durationText(summary.minutes), "clock")
                performanceMetric("Energía", summary.calories > 0 ? "\(Int(summary.calories)) kcal" : "Sin datos", "flame.fill")
                performanceMetric("Fuerza", "\(summary.strengthSets) series", "dumbbell.fill")
            }
            if summary.strengthVolume > 0 { Text("Volumen de fuerza: \(Int(summary.strengthVolume).formatted()) kg · peso × repeticiones").font(.caption).foregroundStyle(.secondary) }
        }.cardStyle()
    }

    private func performanceMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainingLoadCard(_ summary: PerformanceSummary) -> some View {
        let ratio = summary.loadRatio
        let observedDays = summary.daily.filter { $0.sessions > 0 }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Carga de entrenamiento").font(.headline)
                DataTrustBadge(trust: DataTrust(
                    nature: .calculated,
                    source: "Apple Salud + entrenamientos importados",
                    measuredAt: health.lastUpdated,
                    samples: observedDays,
                    level: ConfidenceEngine.level(samples: observedDays, medium: 4, high: 14),
                    explanation: "La carga combina duración e intensidad cardiovascular con el trabajo de fuerza registrado. La confianza aumenta cuando hay varias semanas con sesiones completas.",
                    limitations: "No es una medición fisiológica directa. Calorías incompletas, sesiones sin pulso o entrenamientos no registrados pueden infraestimar la carga."
                ))
                Spacer()
                Text(summary.loadState).font(.subheadline.bold()).foregroundStyle(loadColor(ratio))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(summary.acuteLoad.rounded()))").font(.largeTitle.bold()).fontDesign(.rounded)
                Text("carga aguda ponderada").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if summary.habitualLoad > 0 { Text("base 28 d · \(Int(summary.habitualLoad.rounded()))").font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(loadColor(ratio)).frame(width: proxy.size.width * min(1, ratio / 1.7))
                }
            }.frame(height: 10)
            // PR3f: el ratio que se muestra es el del canal que manda —el
            // mismo que gatea el plan— y se dice cuál es. El desglose de los
            // dos canales solo aparece cuando los dos tienen base real: sin
            // ella no hay ratio que enseñar, y un "×0.00" leería como
            // "descansado" cuando lo que pasa es que no hay datos.
            if summary.dual.aerobicRatio > 0 && summary.dual.strengthRatio > 0 {
                HStack(spacing: 14) {
                    channelRatio("Fondo", summary.dual.aerobicRatio, .blue)
                    channelRatio("Fuerza", summary.dual.strengthRatio, .orange)
                }
            }
            Text(summary.habitualLoad > 0
                 ? "Relación aguda/base \(summary.loadChannel): \(ratio.formatted(.number.precision(.fractionLength(2)))). Manda el canal más exigido, no la media de los dos. \(summary.loadAdvice)"
                 : summary.loadAdvice)
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func channelRatio(_ title: String, _ ratio: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("×\(ratio.formatted(.number.precision(.fractionLength(2))))").font(.caption2.bold()).monospacedDigit()
        }
    }

    private func intensityFocusCard(_ summary: PerformanceSummary) -> some View {
        // The 12-32% "hard" range already used for running-only intensity is a
        // reasonable general reference here too (this card spans every workout
        // type), rather than inventing a separate arbitrary threshold.
        let target = RunningPerformanceEngine.hardIntensityTarget(for: TrainingPlanEngine.activeBlock(on: Date(), profile: goals.profile))
        let hard = summary.highAerobic + summary.anaerobic
        return VStack(alignment: .leading, spacing: 14) {
            Label("Foco de intensidad", systemImage: "heart.text.square.fill").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                focusMetric("Suave", subtitle: "Z1–Z2", summary.lowAerobic, .blue,
                            comparedTo: (100 - target.upperBound)...(100 - target.lowerBound))
                focusMetric("Intenso", subtitle: "Z3–Z4", summary.highAerobic, .orange, comparedTo: nil)
                focusMetric("Anaeróbico", subtitle: "Z5", summary.anaerobic, .purple, comparedTo: nil)
            }
            twoTierBar(segments: [(summary.lowAerobic, .blue), (summary.highAerobic, .orange), (summary.anaerobic, .purple)])
            Text(hard > target.upperBound
                 ? "El objetivo general para esta fase es \(Int(target.lowerBound))–\(Int(target.upperBound))% intenso + anaeróbico; llevas \(Int(hard.rounded()))%."
                 : "Suave = Z1–Z2 · Intenso = Z3–Z4 · Anaeróbico = Z5. Distribución de los últimos 10 días, todos los entrenamientos.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            if !health.heartRateZones.isEmpty {
                Divider()
                heartRateZoneBreakdown(health.heartRateZones)
            }
        }.cardStyle()
    }

    private func focusMetric(_ title: String, subtitle: String, _ value: Double, _ color: Color, comparedTo target: ClosedRange<Double>?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(color)
            Text("\(Int(value.rounded()))").font(.title.bold()).monospacedDigit() + Text("%").font(.caption.bold()).foregroundStyle(.secondary)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            if let target {
                Label(target.contains(value) ? "En objetivo" : value < target.lowerBound ? "Por debajo" : "Por encima",
                      systemImage: target.contains(value) ? "checkmark" : value < target.lowerBound ? "chevron.down" : "chevron.up")
                    .font(.caption2.bold()).foregroundStyle(target.contains(value) ? EterTheme.positive : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func twoTierBar(segments: [(Double, Color)]) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(segment.1).frame(width: proxy.size.width * segment.0 / 100)
                    }
                }.frame(height: 13).clipShape(Capsule())
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(segment.1.opacity(0.35)).frame(width: proxy.size.width * segment.0 / 100)
                    }
                }.frame(height: 5).clipShape(Capsule())
            }
        }.frame(height: 21)
    }

    private static let heartRateZoneColors: [Color] = [.mint, .blue, .yellow, .orange, .red]

    private func heartRateZoneBreakdown(_ zones: [HeartRateZone]) -> some View {
        let byZone = Dictionary(uniqueKeysWithValues: zones.map { ($0.zone, $0.percentage) })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Zonas de frecuencia cardíaca").font(.subheadline.bold())
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { zone in
                        Rectangle().fill(Self.heartRateZoneColors[zone - 1])
                            .frame(width: proxy.size.width * (byZone[zone] ?? 0) / 100)
                    }
                }.clipShape(Capsule())
            }.frame(height: 13)
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { zone in
                    VStack(spacing: 2) {
                        Circle().fill(Self.heartRateZoneColors[zone - 1]).frame(width: 7, height: 7)
                        Text("Z\(zone)").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int((byZone[zone] ?? 0).rounded()))%").font(.caption2.bold()).monospacedDigit()
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func activityCalendar(_ summary: PerformanceSummary) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Consistencia").font(.headline); Spacer(); Text("28 días").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(summary.daily) { day in
                    RoundedRectangle(cornerRadius: 5).fill(day.load == 0 ? Color.primary.opacity(0.09) : day.load < 35 ? EterTheme.positive.opacity(0.45) : day.load < 75 ? EterTheme.positive.opacity(0.75) : EterTheme.warning.opacity(0.8))
                        .frame(height: 22).overlay(Text(day.sessions > 1 ? "\(day.sessions)" : "").font(.caption2.bold()).foregroundStyle(.white))
                }
            }
            Text("El color representa carga, no una obligación de entrenar: los días de descanso también forman parte del ciclo.").font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func baselineCard(_ title: String, unit: String, points: [TrendPoint], favorableHigh: Bool, color: Color) -> some View {
        let recent = Array(points.suffix(42))
        let baselineValues = Array(recent.dropLast().suffix(28)).map(\.value)
        let mean = baselineValues.isEmpty ? nil : baselineValues.reduce(0, +) / Double(baselineValues.count)
        let deviation = mean.map { average in sqrt(baselineValues.reduce(0) { $0 + pow($1 - average, 2) } / Double(max(1, baselineValues.count))) }
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) { Text(title).font(.headline); Text("Tu banda habitual de 28 días").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let last = recent.last { Text("\(last.value, specifier: "%.1f") \(unit)").font(.subheadline.bold()).foregroundStyle(color) }
            }
            if recent.count < 7 || mean == nil || deviation == nil {
                Text("Aún no hay suficientes mediciones para una línea base personal.").font(.caption).foregroundStyle(.secondary).frame(height: 75)
            } else if let mean, let deviation {
                Chart {
                    RectangleMark(xStart: nil, xEnd: nil, yStart: .value("Inferior", mean - deviation), yEnd: .value("Superior", mean + deviation))
                        .foregroundStyle(color.opacity(0.12))
                    ForEach(recent) { point in
                        LineMark(x: .value("Fecha", point.date), y: .value(title, point.value)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(y: .value("Base", mean)).foregroundStyle(color.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }.frame(height: 135)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Línea base de \(title)")
                    .accessibilityValue("Último valor \(recent.last?.value.formatted(.number.precision(.fractionLength(1))) ?? "sin dato") \(unit). Base \(mean.formatted(.number.precision(.fractionLength(1))))")
                if let last = recent.last {
                    let delta = last.value - mean
                    let recentWeek = Array(recent.suffix(7)).map(\.value)
                    let low = recentWeek.min() ?? last.value
                    let high = recentWeek.max() ?? last.value
                    // Half a personal standard deviation is treated as
                    // "within normal noise" — small wobbles inside that
                    // band aren't worth coloring as good or bad news.
                    let favorability = Favorability.of(delta: delta, favorableHigh: favorableHigh, deadZone: deviation * 0.5)
                    // Apple Health's own widgets pair a headline number with a
                    // sentence — how it compares, and the range it's actually
                    // moved in — instead of leaving the number to speak for
                    // itself. Same shape here: direction vs. personal baseline,
                    // then the last 7 days' spread — now colored so "better or
                    // worse" reads at a glance instead of requiring the
                    // sentence to be read in full every time.
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: favorability == .neutral ? "equal.circle.fill" : delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(favorability.color).font(.caption)
                        Text("\(abs(delta), specifier: "%.1f") \(unit) \((delta >= 0) == favorableHigh ? "por encima" : "por debajo") de tu base habitual de \(mean, specifier: "%.1f") \(unit). En los últimos 7 días ha ido de \(low, specifier: "%.1f") a \(high, specifier: "%.1f") \(unit).")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(2)
                    }
                }
            }
        }.cardStyle()
    }

    private var capacityCard: some View {
        let vo2 = health.vo2MaxHistory.last?.value
        let hrvLong = average(health.hrvHistory.suffix(30).map(\.value))
        let rhrLong = average(health.restingHeartRateHistory.suffix(30).map(\.value))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Capacidad a largo plazo").font(.headline)
            Text("Mantenemos las señales separadas para no ocultarlas tras un índice opaco.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                capacityMetric("VO₂ máx.", vo2, "ml/kg/min")
                capacityMetric("HRV 30d", hrvLong, "ms")
                capacityMetric("RHR 30d", rhrLong, "ppm")
            }
        }.cardStyle()
    }

    private var heartRateRecoveryCard: some View {
        let points = health.heartRateRecoveryHistory
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Recuperación cardiaca", systemImage: "heart.circle").font(.headline)
                Spacer()
                if let last = points.last { Text("−\(Int(last.value.rounded())) ppm").font(.subheadline.bold()).foregroundStyle(.purple) }
            }
            if points.isEmpty {
                Text("No hay todavía entrenamientos con muestras válidas al finalizar y un minuto después. No se calcula una estimación cuando faltan esos dos puntos.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Fecha", point.date), y: .value("Caída", point.value)).foregroundStyle(.purple).lineStyle(StrokeStyle(lineWidth: 2.3))
                    PointMark(x: .value("Fecha", point.date), y: .value("Caída", point.value)).foregroundStyle(.purple)
                }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }.frame(height: 125)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Evolución de la recuperación cardiaca")
                    .accessibilityValue(points.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): caída de \(Int($0.value.rounded())) pulsaciones" }.joined(separator: ". "))
                Text("Caída del pulso entre el final de la sesión y aproximadamente 60 segundos después. Compara sobre todo sesiones de naturaleza similar.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.cardStyle()
    }

    private func capacityMetric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.headline).monospacedDigit(); Text(unit).font(.caption2).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    private func durationText(_ minutes: Double) -> String { "\(Int(minutes) / 60)h \(Int(minutes) % 60)m" }
    // Same load-ratio-risk concept TrainingScenarioCardView models with
    // EterTheme tokens — this one had drifted to raw color literals.
    private func loadColor(_ ratio: Double) -> Color { ratio == 0 ? .gray : ratio < 0.65 ? .blue : ratio < 1.30 ? EterTheme.positive : ratio < 1.55 ? EterTheme.negative : EterTheme.danger }


    private var twinCard: some View {
        let assessment = currentAssessment
        return ReadinessCard(assessment: assessment, trust: readinessTrust(assessment.baselineConfidence))
    }


    private var proposedWorkoutCard: some View {
        let assessment = currentAssessment
        let plan = currentPlan
        let workout = WorkoutPlanner.propose(health: health, imports: imports, checkIn: checkIns.entry(), context: twinContext)
        let strengthIsAllowed = !injuries.active.contains { $0.restrictions.contains(.avoidStrength) }
        // PR8: la propuesta dice si es de fuerza (workout.kind), en vez de
        // deducirse de que su título NO contenga "recuperación" — una
        // condición que también daba `true` para una natación, un brick o un
        // protocolo de competición, y que dependía de la redacción exacta del
        // título. El chequeo de MuscleMap se queda: además de ser de fuerza,
        // los ejercicios tienen que ser nombres que el mapa reconozca para
        // poder registrarla como sesión propia.
        let isCompatibleStrengthProposal = workout.kind == .strength &&
            workout.exercises.contains { !MuscleMap.groups(for: $0.name).isEmpty }
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ENTRENAMIENTO PROPUESTO").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                    Text(workout.title).font(.title2).fontDesign(.serif)
                    Text("\(workout.duration) · \(workout.intent)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2).foregroundStyle(EterTheme.positive)
            }
            Divider()
            ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { index, exercise in
                HStack(alignment: .top, spacing: 11) {
                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                        .frame(width: 25, height: 25).background(EterTheme.primary).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.name).font(.subheadline.bold())
                        Text(exercise.prescription).font(.caption).foregroundStyle(EterTheme.positive)
                        Text(exercise.cue).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            Text(workout.note).font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            if plan.nextSession == .strength && strengthIsAllowed && isCompatibleStrengthProposal {
                Button {
                    todayStrengthRoutine = StrengthRoutineBuilder.routine(
                        from: workout, imports: imports,
                        readiness: assessment.score, muscles: assessment.muscles
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Comenzar rutina").font(.headline)
                            Text("Editable antes y durante la sesión").font(.caption2).opacity(0.76)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 15).frame(minHeight: 54)
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.15))
                    .background(Color(red: 0.84, green: 0.94, blue: 0.55))
                    .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius))
                }
                .buttonStyle(.plain)
            }
        }.cardStyle()
    }

    // "La gente no vive solo con el hoy": today's proposed workout used to
    // be the only thing on screen — this shows where the plan actually
    // goes for the next 6 days too, so a hard day or a rest day doesn't
    // arrive as a surprise. Linked to "Simular decisión" below: the same
    // decision picked there can replace today's session (or, for a
    // lifestyle choice, just tomorrow's readiness) and recompute the rest
    // of this week from it, via the real/simulación toggle.
    // TwinCore's weekAhead/simulate no longer read GoalStore/
    // LifestyleFactorStore/WorkoutReviewStore/InjuryStore/TwinStateStore
    // internally — twinContext above bundles the real values read from
    // them once, so the several call sites below don't each repeat them.
    private func weekAhead(checkIn: DailyCheckIn?, override: TrainingPlanEngine.DecisionOverride? = nil) -> [TrainingPlanEngine.DayForecast] {
        TrainingPlanEngine.weekAhead(health: health, imports: imports, checkIn: checkIn, context: twinContext, override: override)
    }

    private func simulateDecision(_ decision: SimulatedDecision, checkIn: DailyCheckIn?) -> DecisionSimulation {
        DecisionSimulatorEngine.simulate(decision, health: health, imports: imports, checkIn: checkIn,
                                         profile: goals.profile, events: lifestyle.events, reviews: workoutReviews.reviews,
                                         activeInjuries: injuries.active, calibration: twinStates.calibration,
                                         personalAnchor: twinStates.personalAnchor(),
                                         travel: travel.currentEpisode())
    }

    private var weekAheadCard: some View {
        let week = weekAhead(checkIn: checkIns.entry())
        let simulation = simulateDecision(simulatedDecision, checkIn: checkIns.entry())
        let simulatedWeek = weekAhead(checkIn: checkIns.entry(), override: simulation.weekAheadOverride)
        return WeekAheadStripView(realDays: week, simulatedDays: simulatedWeek, simulatedDecisionLabel: simulatedDecision.rawValue)
    }

    private var decisionSimulatorCard: some View {
        let simulation = simulateDecision(simulatedDecision, checkIn: checkIns.entry())
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                EterSectionHeader("¿Qué pasa si hoy…?", eyebrow: "Simular decisión")
                Spacer()
                DataTrustBadge(trust: DataTrust(nature: .inferred, source: "Gemelo personal · carga + recuperación", measuredAt: health.lastUpdated, samples: health.recentWorkouts.count + imports.workoutCount, level: simulation.confidence, explanation: "Compara la carga típica de cada opción con tu carga habitual y disponibilidad actual para proyectar mañana.", limitations: "Es una simulación, no una predicción fisiológica exacta. No conoce aún la duración, intensidad real ni respuesta individual de una sesión futura."))
            }
            Picker("Decisión", selection: $simulatedDecision) {
                ForEach(SimulatedDecision.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).labelsHidden()
            HStack(spacing: 9) {
                simulatorMetric("Carga añadida", "+\(Int(simulation.addedLoad.rounded()))")
                simulatorMetric("Carga 7 días", "\(Int(simulation.projectedAcuteLoad.rounded()))")
                simulatorMetric("Mañana", "\(simulation.tomorrowReadiness)%")
            }
            Text(simulation.headline).font(.headline).foregroundStyle(scoreColor(simulation.tomorrowReadiness))
            Text(simulation.explanation).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            VStack(alignment: .leading, spacing: 3) {
                Text("CÓMO VAS A RENDIR HOY").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                Text(simulation.performanceExpectation).font(.subheadline).lineSpacing(3)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EterTheme.accent.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Chart(simulation.trajectory) { day in
                AreaMark(x: .value("Día", day.day), y: .value("Disponibilidad", day.readiness))
                    .foregroundStyle(LinearGradient(colors: [EterTheme.positive.opacity(0.24), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Día", day.day), y: .value("Disponibilidad", day.readiness))
                    .foregroundStyle(EterTheme.positive).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Día", day.day), y: .value("Disponibilidad", day.readiness))
                    .foregroundStyle(EterTheme.positive)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: simulation.trajectory.map(\.day)) { value in AxisValueLabel { if let day = value.as(Int.self) { Text(day == 1 ? "Mañana" : "+\(day)d") } } } }
            .frame(height: 125)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Proyección de disponibilidad durante cuatro días")
            .accessibilityValue(simulation.trajectory.map { "Día \($0.day): \($0.readiness) por ciento, \($0.guidance)" }.joined(separator: ". "))
            ForEach(simulation.trajectory) { day in
                HStack {
                    Text(day.day == 1 ? "Mañana" : "+\(day.day) días").font(.caption.bold())
                    Spacer()
                    Text(day.guidance).font(.caption).foregroundStyle(.secondary)
                    Text("\(day.readiness)%").font(.caption.bold()).monospacedDigit()
                }
            }
            Text("Mañana refleja la decisión de hoy. A partir de ahí, la proyección asume que sigues el plan que éter recomendaría cada día — no reposo indefinido — y mantiene tu disponibilidad de hoy, ya que no podemos predecir tu sueño o HRV futuros. Se recalcula cuando entrenas o registras nuevas señales.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            Label("Esta misma decisión puede sustituir el entrenamiento de hoy en \"Próximos 7 días\" arriba — activa \"Simulación\" en esa tarjeta.", systemImage: "arrow.up")
                .font(.caption2.bold()).foregroundStyle(EterTheme.primary)
            Divider()
            ForEach(simulation.tradeoffs, id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "arrow.right.circle.fill").font(.caption).foregroundStyle(.teal)
                    Text(item).font(.caption)
                }
            }
            Text("Relación aguda/habitual proyectada: \(simulation.projectedRatio, specifier: "%.2f") · confianza \(simulation.confidence.rawValue.lowercased()).")
                .font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func simulatorMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dailyCheckInCard: some View {
        let entry = checkIns.entry()
        return Button { activeSheet = .checkIn } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(entry == nil ? EterTheme.warning.opacity(0.15) : EterTheme.positive.opacity(0.14)).frame(width: 44, height: 44)
                    Image(systemName: entry == nil ? "person.fill.questionmark" : "checkmark").foregroundStyle(entry == nil ? EterTheme.warning : EterTheme.positive)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry == nil ? "Check-in de 20 segundos" : "Check-in completado").font(.headline)
                    if let entry {
                        Text("Energía \(entry.energy)/5 · Fatiga \(entry.fatigue)/5 · Estrés \(entry.stress)/5")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Añade cómo te sientes para afinar el gemelo de hoy.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let entry {
                    DataTrustBadge(trust: DataTrust(nature: .declared, source: "Check-in de Ángel", measuredAt: entry.createdAt, samples: 1, level: ConfidenceEngine.declared(samples: 1).level, explanation: "Es tu percepción directa de hoy; aporta señales que el reloj no puede observar, como dolor, estrés, motivación y agujetas.", limitations: "Es subjetivo y puede variar con el contexto. Se usa como señal complementaria, no como diagnóstico."))
                }
                Image(systemName: entry == nil ? "arrow.right" : "pencil").foregroundStyle(.secondary)
            }.padding(16).background(EterTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: EterTheme.cardRadius, style: .continuous))
        }.buttonStyle(.plain)
    }

    private var lifestyleFactorCard: some View {
        Button { lifestyleFactorPendingEdit = nil; showLifestyleFactors = true } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Otros factores").font(.headline)
                    if let latest = lifestyle.events.first, Date().timeIntervalSince(latest.date) < 36 * 3600 {
                        Text(latest.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text("Alcohol, sauna, agua fría o cambio horario.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(); Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }.padding(16).background(EterTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: EterTheme.cardRadius, style: .continuous))
        }.buttonStyle(.plain)
    }


    private var currentPlanCard: some View {
        let plan = currentPlan
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    EterSectionHeader(plan.block.name, eyebrow: "Plan actual", subtitle: plan.block.objective)
                    Text("Carga y objetivos · ventana móvil de 7 días").font(.caption2).foregroundStyle(.secondary)
                    if plan.isDeload {
                        Label("Descarga activa · volumen al \(Int((plan.volumeFactor * 100).rounded()))%", systemImage: "arrow.down.right.circle.fill")
                            .font(.caption.bold()).foregroundStyle(EterTheme.warning)
                    }
                }
                Spacer()
                DataTrustBadge(trust: DataTrust(nature: .inferred, source: "Objetivos + carga + disponibilidad", measuredAt: health.lastUpdated, samples: health.recentWorkouts.count + imports.workoutCount, level: ConfidenceEngine.readiness(baselineConfidence: currentAssessment.baselineConfidence, signalCount: currentAssessment.signals.count, hasCheckIn: checkIns.entry() != nil, updatedAt: health.lastUpdated).level, explanation: "La recomendación cruza el bloque de planificación activo con lo ya entrenado y tu disponibilidad actual.", limitations: "Es una propuesta adaptable. Dolor, enfermedad, agenda o una prueba reciente pueden justificar cambiarla."))
                if let days = plan.daysToEvent, let event = plan.eventName {
                    VStack(spacing: 1) { Text("\(days)").font(.title2.monospacedDigit().bold()); Text("días · \(event)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 8) {
                planProgress("Running", done: plan.completedRuns, target: plan.targetRuns, color: .blue)
                planProgress("Fuerza", done: plan.completedStrength, target: plan.targetStrength, color: .indigo)
                planProgress("Calidad", done: plan.completedQuality, target: plan.targetQuality, color: .orange)
            }
            // Dose in minutes, not session counts — "dos salidas de bici"
            // used to read as covered even if both were 35 minutes; this is
            // what actually answers "¿he construido tolerancia real esta
            // semana?". Only shown for disciplines the active goal needs.
            if plan.swimDose.targetMinutes > 0 || plan.bikeDose.targetMinutes > 0 || plan.brickDose.targetMinutes > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DOSIS SEMANAL (MIN)").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if plan.swimDose.targetMinutes > 0 { planDoseProgress("Natación", plan.swimDose, color: .cyan) }
                        if plan.bikeDose.targetMinutes > 0 { planDoseProgress("Bici", plan.bikeDose, color: .teal) }
                        if plan.brickDose.targetMinutes > 0 { planDoseProgress("Brick", plan.brickDose, color: .pink) }
                    }
                }
            }
            Divider()
            Text("SIGUIENTE SESIÓN · \(plan.nextSession.rawValue.uppercased())").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(EterTheme.positive)
            Text(plan.recommendation).font(.subheadline).lineSpacing(3)
            Text(plan.rationale).font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    /// PR16: guarda los días reales hasta estabilidad EN CUANTO se confirman,
    /// mientras las series de sueño y HRV que los demuestran siguen dentro de
    /// su ventana de 90 días. Sin esto, el aprendizaje sólo podría mirar los
    /// últimos tres meses — y con tres o cuatro viajes al año nunca habría dos
    /// tramos comparables a la vez en la misma dirección.
    ///
    /// Va junto a las otras dos capturas diarias (el plan y el estado del
    /// gemelo) porque es lo mismo: convertir algo que hoy se puede medir en
    /// algo que mañana se podrá recordar.
    private func captureTravelStabilityIfNeeded(_ assessment: TwinAssessment) {
        guard let episode = travel.currentEpisode(),
              let stabilizedAt = assessment.travel.stabilizedAt else { return }
        let leg: TravelLeg = assessment.travel.phase == .homeReadaptation ? .homeReturn : .outbound
        guard let anchor = leg == .homeReturn ? episode.homeArrival : episode.destinationArrival,
              stabilizedAt >= anchor else { return }
        travel.recordStability(episodeID: episode.id, leg: leg,
                               days: stabilizedAt.timeIntervalSince(anchor) / 86_400,
                               confounders: assessment.travel.confounders)
    }

    private func captureCurrentPlanIfNeeded() {
        guard health.authorizationRequested else { return }
        let assessment = currentAssessment
        let plan = currentPlan
        planHistory.captureIfNeeded(plan, health: health)
        twinStates.capture(assessment: assessment, health: health)
        captureTravelStabilityIfNeeded(assessment)
    }

    private func syncWatchSummary() {
        guard health.authorizationRequested else {
            print("[éter/watch] syncWatchSummary descartado: sin permiso de Salud todavía")
            return
        }
        let assessment = currentAssessment
        // Driven by the plan's own structured PlannedSessionKind, not by
        // re-parsing the rendered Spanish recommendation text — see
        // TrainingPlanEngine.watchActivity's own comment for the two real
        // misclassifications that string-matching caused (swim/bike/brick/
        // HYROX/race-day defaulting to "strength", and "Brick bici-carrera"
        // being misread as running because it contains "carrera").
        let activity = TrainingPlanEngine.watchActivity(for: currentPlan.nextSession)
        watchMetrics.updateTwinSummary(readiness: assessment.score, state: assessment.state,
                                       recommendation: assessment.recommendation,
                                       reason: assessment.explanation, activity: activity,
                                       confidence: assessment.baselineConfidence,
                                       maximumHeartRate: goals.profile.maximumHeartRate,
                                       hrv: health.snapshot.hrv,
                                       restingHeartRate: health.snapshot.restingHeartRate,
                                       sleepHours: health.snapshot.sleepHours)
        WidgetSnapshotStore.update(
            assessment: assessment, health: health, imports: imports,
            checkIn: checkIns.entry(), lifestyle: lifestyle
        )
    }

    private func planProgress(_ name: String, done: Int, target: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text("\(done)/\(target)").font(.headline.monospacedDigit())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color).frame(width: proxy.size.width * min(1, Double(done) / Double(max(target, 1))))
                }
            }.frame(height: 6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planDoseProgress(_ name: String, _ dose: DisciplineDose, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(dose.completedMinutes))/\(Int(dose.targetMinutes))").font(.headline.monospacedDigit())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color).frame(width: proxy.size.width * min(1, dose.completedMinutes / max(dose.targetMinutes, 1)))
                }
            }.frame(height: 6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trainingRoadmapCard: some View {
        let today = Date()
        let roadmapBlocks = TrainingPlanEngine.blocks(for: goals.profile)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("HOJA DE RUTA").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
                Spacer(); Button("Editar objetivos") { activeSheet = .goalEditor }.font(.caption.bold())
            }
            ForEach(Array(roadmapBlocks.enumerated()), id: \.element.id) { index, block in
                let active = today >= block.start && today <= Calendar.current.date(byAdding: .day, value: 1, to: block.end)!
                HStack(alignment: .top, spacing: 11) {
                    VStack(spacing: 0) {
                        Circle().fill(active ? EterTheme.positive : block.end < today ? Color.gray : Color.primary.opacity(0.16)).frame(width: 11, height: 11)
                        if index < roadmapBlocks.count - 1 { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 2, height: 52) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(block.name).font(.subheadline.bold()); if active { Text("AHORA").font(.caption2.bold()).foregroundStyle(EterTheme.positive) } }
                        Text("\(block.start.formatted(.dateTime.day().month(.abbreviated))) – \(block.end.formatted(.dateTime.day().month(.abbreviated)))").font(.caption2).foregroundStyle(.secondary)
                        Text(block.objective).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
            }
            Text("Los objetivos semanales son rangos orientativos. Readiness, enfermedad, dolor y carga reciente pueden reducir o aplazar una sesión.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }


    private func scoreColor(_ score: Int) -> Color { score >= 70 ? EterTheme.positive : score >= 45 ? EterTheme.negative : EterTheme.danger }


    private var recentTraining: some View {
        let sessions = recentSessions
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Últimos entrenamientos").font(.headline)
                    Text("Actividad de los últimos 7 días").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(sessions.count)").font(.title3.bold()).monospacedDigit()
            }
            if sessions.isEmpty {
                Text("No hay entrenamientos registrados esta semana.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 18)
            } else {
                ForEach(Array(sessions.prefix(12).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title).font(.subheadline.bold())
                                Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.source)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(Int(session.duration.rounded())) min").font(.caption.bold()).monospacedDigit()
                                Button { activeSheet = .workoutReview(session) } label: {
                                    if let review = workoutReviews.review(for: session.id) {
                                        Label("RPE \(review.effort)", systemImage: review.pain ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                            .font(.caption2.bold()).foregroundStyle(review.pain ? EterTheme.negative : EterTheme.positive)
                                    } else {
                                        Label("Valorar", systemImage: "square.and.pencil").font(.caption2).foregroundStyle(.blue)
                                    }
                                }.buttonStyle(.plain).eterTouchTarget().accessibilityLabel("Valorar \(session.title)")
                                if let healthID = session.healthWorkoutID,
                                   let workout = health.recentWorkouts.first(where: { $0.id == healthID }) {
                                    Button(role: .destructive) { workoutPendingDeletion = workout } label: { Image(systemName: "trash").font(.caption2) }
                                        .buttonStyle(.plain).eterTouchTarget().accessibilityLabel("Eliminar \(session.title)")
                                } else if let importedID = session.importedWorkoutID {
                                    Button(role: .destructive) { importedWorkoutPendingDeletion = importedID } label: { Image(systemName: "trash").font(.caption2) }
                                        .buttonStyle(.plain).eterTouchTarget().accessibilityLabel("Eliminar \(session.title)")
                                }
                            }
                        }
                        // Distance/pace and heart rate — real per-session
                        // numbers, not just the summary a tap used to be
                        // required to see. Pace is derived here (distance
                        // and duration are already both on hand) rather
                        // than added as its own stored field. Horizontally
                        // scrollable, same as the muscle capsules below —
                        // a run can now show up to 4 chips at once
                        // (distance, pace, pulse, calories), which won't
                        // always fit a narrow screen without it.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                if let distance = session.distanceKilometers, distance > 0 {
                                    Label("\(distance.formatted(.number.precision(.fractionLength(1...2)))) km", systemImage: "location.fill")
                                    if session.duration > 0 {
                                        Label("\(DecisionSimulatorEngine.formatPace(session.duration / distance))/km", systemImage: "speedometer")
                                    }
                                }
                                if let heartRate = session.averageHeartRate, heartRate > 0 {
                                    Label("\(Int(heartRate.rounded())) ppm", systemImage: "heart.fill")
                                }
                                if let calories = session.calories, calories > 0 {
                                    Label("\(Int(calories.rounded())) kcal", systemImage: "flame.fill")
                                }
                                if let sets = session.sets, sets > 0 {
                                    Label("\(sets) series", systemImage: "dumbbell.fill")
                                }
                                if let volume = session.volume, volume > 0 {
                                    Label("\(Int(volume.rounded()).formatted()) kg", systemImage: "chart.bar.fill")
                                }
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if !session.muscles.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(session.muscles, id: \.self) { muscle in
                                        Text(muscle).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(EterTheme.positive.opacity(0.14)).clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    // A tap anywhere on the row opens the detail — the
                    // "Valorar"/borrar buttons above stay their own Buttons,
                    // which SwiftUI resolves independently of this gesture
                    // at the exact tap location, so neither interferes with
                    // the other.
                    .contentShape(Rectangle())
                    .onTapGesture { activeSheet = .workoutDetail(session) }
                }
            }
        }.cardStyle()
    }

    private var recentSessions: [RecentTrainingSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let hevy = imports.workouts.filter { $0.start >= cutoff }.map { workout in
            RecentTrainingSession(
                id: "hevy-\(workout.id)", title: workout.title, date: workout.start,
                duration: workout.end.timeIntervalSince(workout.start) / 60,
                source: "Hevy", calories: nil,
                sets: workout.exercises.reduce(0) { $0 + $1.sets },
                volume: workout.exercises.reduce(0) { $0 + $1.volume },
                distanceKilometers: nil, averageHeartRate: nil,
                muscles: workout.muscleSets.sorted { $0.value > $1.value }.map(\.key),
                healthWorkoutID: nil, importedWorkoutID: workout.id
            )
        }
        let healthSessions = health.recentWorkouts.filter {
            $0.date >= cutoff && !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }.map { workout in
            RecentTrainingSession(
                id: "health-\(workout.id.uuidString)", title: workout.activity, date: workout.date,
                duration: workout.durationMinutes, source: workout.source, calories: workout.calories,
                sets: nil, volume: nil,
                distanceKilometers: workout.distanceKilometers, averageHeartRate: workout.averageHeartRate,
                muscles: workout.muscleGroups.sorted { $0.value > $1.value }.map(\.key),
                healthWorkoutID: workout.id, importedWorkoutID: nil
            )
        }
        return (hevy + healthSessions).sorted { $0.date > $1.date }
    }

    private func sourceCount(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private var trainingAnalytics: some View {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -10, to: now)!
        let previousStart = calendar.date(byAdding: .day, value: -20, to: now)!
        let current = combinedMuscleDistribution(from: start, to: now)
        let previous = combinedMuscleDistribution(from: previousStart, to: start)
        let volume = imports.weeklyVolume()
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { VStack(alignment: .leading) { Text("Distribución muscular").font(.headline); Text("Hevy + Apple Salud · últimos 10 días frente a los 10 anteriores").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                MuscleRadar(current: current, previous: previous, periodDays: 10).frame(height: 285)
                HStack(spacing: 16) { Label("Actual", systemImage: "circle.fill").foregroundStyle(.blue); Label("Anterior", systemImage: "circle.fill").foregroundStyle(.gray) }.font(.caption).frame(maxWidth: .infinity)
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

    private var heartZoneChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zonas de frecuencia cardíaca").font(.headline)
                    Text("Distribución estimada de tus entrenamientos · últimos 10 días").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if health.heartRateZones.isEmpty {
                Text("No hay muestras de frecuencia cardíaca asociadas a entrenamientos en este periodo.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 70)
            } else {
                Chart(health.heartRateZones) { item in
                    BarMark(x: .value("Porcentaje", item.percentage), y: .value("Zona", "Z\(item.zone)"))
                        .foregroundStyle(zoneColor(item.zone).gradient)
                        .annotation(position: .trailing) { Text("\(Int(item.percentage.rounded()))%").font(.caption.bold()).monospacedDigit() }
                }
                .chartXScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in AxisGridLine().foregroundStyle(Color.primary.opacity(0.10)); AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } } } }
                .frame(height: 190)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Distribución por zonas de frecuencia cardiaca")
                .accessibilityValue(health.heartRateZones.map { "Zona \($0.zone): \(Int($0.percentage.rounded())) por ciento" }.joined(separator: ". "))
                Text(goals.profile.maximumHeartRate.map {
                    "Z1 recuperación · Z2 base aeróbica · Z3 tempo · Z4 umbral · Z5 alta intensidad. Calibradas con tu FC máxima configurada de \($0) ppm."
                } ?? "Z1 recuperación · Z2 base aeróbica · Z3 tempo · Z4 umbral · Z5 alta intensidad. Zonas provisionales estimadas desde tu pico reciente; configura una FC máxima medida en Plan del gemelo para calibrarlas.")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
        }.cardStyle()
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return .gray
        case 2: return .blue
        case 3: return .green
        case 4: return .orange
        default: return .red
        }
    }

    private func combinedMuscleDistribution(from start: Date, to end: Date) -> [String: Double] {
        var result = imports.muscleDistribution(from: start, to: end)
        for workout in health.recentWorkouts where workout.date >= start && workout.date < end {
            // Hevy can also write a summary workout to HealthKit — its detailed
            // CSV is already counted above, so ignore that summary to avoid
            // counting twice. But that's not the only way a duplicate shows
            // up: éter's own live session ALSO writes its own generic
            // HKWorkout on completion (saveStrengthWorkout, source "éter",
            // so the "hevy" name check alone never caught it) for the exact
            // same session already counted above via imports — every
            // éter-logged session was silently counted twice, once with
            // real per-exercise set data and again with a rough fixed-
            // fraction estimate, which is exactly what inflated two modest
            // sessions into "230% bíceps". isHealthKitMirror matches by
            // start time + duration regardless of source name, the same
            // general check TrainingPlanEngine's own "already trained
            // today" logic already relies on.
            guard !workout.source.localizedCaseInsensitiveContains("hevy"), !imports.isHealthKitMirror(workout) else { continue }
            // muscleGroups exists for every activity type — including
            // Carrera/Ciclismo/Senderismo/Caminata/Natación — because
            // TwinEngine's fatigue model genuinely needs to know a run
            // tired out your legs. But this chart counts *hypertrophy
            // sets*, and cardio doesn't produce those: a 111-minute hike
            // isn't ~22 leg sets. Without this, every cardio session's
            // fatigue-oriented leg/core involvement got converted into
            // "equivalent sets" here too — the actual mechanism behind
            // "465% piernas" after two modest strength days: real
            // contribution was ~32%, the other ~430 points were hikes,
            // runs, and bike rides that have nothing to do with hypertrophy
            // dosing. Restrict to what StrengthProgressEngine's own
            // Watch-only merge already restricts itself to: strength
            // activity only.
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

    private func metric(_ title: String, value: String, unit: String, icon: String, insight: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color(red: 0.27, green: 0.45, blue: 0.35))
                Spacer()
                DataTrustBadge(trust: metricTrust(title))
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.bold()).fontDesign(.rounded)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            // Only passed where a real personal baseline backs it (Sueño,
            // HRV) — never invented for a tile that has no trend behind it.
            if let insight { Text(insight).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value + " " + unit, insight].compactMap { $0 }.joined(separator: ". "))
    }

    // Same "value + how it compares to your own recent pattern" shape as
    // baselineCard, condensed to one short line for the compact Hoy tiles.
    private func todayComparisonInsight(_ points: [TrendPoint], unit: String, decimals: Int = 1) -> String? {
        let recent = Array(points.suffix(8))
        guard recent.count >= 4, let last = recent.last else { return nil }
        let baseline = recent.dropLast().map(\.value)
        guard !baseline.isEmpty else { return nil }
        let average = baseline.reduce(0, +) / Double(baseline.count)
        let delta = last.value - average
        func fmt(_ value: Double) -> String { abs(value).formatted(.number.precision(.fractionLength(decimals))) }
        if abs(delta) < 0.05 { return "En línea con tu media de 7 días." }
        return "\(fmt(delta)) \(unit) \(delta >= 0 ? "por encima" : "por debajo") de tu media de 7 días."
    }

    // The target itself is personalized (see personalizedStepTarget), but
    // the copy still names 10.000 when that's genuinely the number in
    // play — either because it's this person's real target already, or
    // because there isn't yet enough history to personalize it.
    private var stepsInsight: String {
        let (target, isPersonalized) = TrainingPlanEngine.personalizedStepTarget(stepsHistory: health.stepsHistory, now: Date())
        let steps = health.snapshot.steps
        if steps >= target {
            return isPersonalized ? "✓ Objetivo personal de \(target.formatted()) cumplido" : "✓ 10.000 pasos cumplidos"
        }
        return isPersonalized ? "Objetivo de hoy: \(target.formatted()) pasos" : "Objetivo: 10.000 pasos/día"
    }

    private func metricTrust(_ title: String) -> DataTrust {
        switch title {
        case "Sueño": return HealthDataTrust.sleep(health)
        case "HRV":
            return HealthDataTrust.trend(title: "Variabilidad cardíaca", points: health.hrvHistory, health: health)
        case "Pulso":
            let samples = health.snapshot.heartRate > 0 ? 1 : 0
            return DataTrust(nature: .measured, source: "Apple Salud · última muestra de frecuencia cardiaca", measuredAt: health.lastUpdated, samples: samples, level: ConfidenceEngine.samples(samples, medium: 1, high: 4, label: "muestras recientes").level, explanation: "Es la última muestra disponible al sincronizar, no un monitor continuo en esta pantalla.", limitations: "Puede no representar tu pulso justo en este instante y depende de cuándo el reloj realizó la última lectura.")
        case "Pasos":
            let samples = health.snapshot.steps > 0 ? 1 : 0
            return DataTrust(nature: .measured, source: "Apple Salud · pasos acumulados hoy", measuredAt: health.lastUpdated, samples: samples, level: ConfidenceEngine.samples(samples, medium: 1, high: 4, label: "sincronizaciones de hoy").level, explanation: "Suma de pasos del día tal como los reporta tu iPhone/Apple Watch al sincronizar.", limitations: "Depende de que lleves el dispositivo encima; no captura movimiento sin él (natación, algunas bicis).")
        default:
            let samples = health.snapshot.activeEnergy > 0 ? 1 : 0
            return DataTrust(nature: .calculated, source: "Apple Salud · estimación de energía activa", measuredAt: health.lastUpdated, samples: samples, level: ConfidenceEngine.samples(samples, medium: 1, high: 4, label: "estimaciones diarias").level, explanation: "Apple estima la energía activa usando movimiento, pulso y datos personales.", limitations: "Las kilocalorías son una estimación y su error varía según actividad, ajuste del reloj y datos corporales.")
        }
    }

    private func readinessTrust(_ baselineConfidence: Int) -> DataTrust {
        DataTrust(
            nature: .inferred,
            source: "Apple Salud + Hevy/importaciones + check-in",
            measuredAt: health.lastUpdated,
            samples: health.hrvHistory.count + health.restingHeartRateHistory.count + health.sleepHistory.count + imports.workoutCount,
            level: ConfidenceEngine.readiness(baselineConfidence: baselineConfidence, signalCount: currentAssessment.signals.count, hasCheckIn: checkIns.entry() != nil, updatedAt: health.lastUpdated).level,
            explanation: "El porcentaje se infiere comparando HRV, pulso y sueño con tu línea base personal, y ajustándolo por carga, recuperación muscular y sensaciones.",
            limitations: "No mide directamente recuperación ni daño muscular. Una fuente ausente o un entrenamiento no registrado puede cambiar la recomendación."
        )
    }

}

struct RecentTrainingSession: Identifiable {
    let id: String
    let title: String
    let date: Date
    let duration: Double
    let source: String
    let calories: Double?
    let sets: Int?
    let volume: Double?
    let distanceKilometers: Double?
    let averageHeartRate: Double?
    let muscles: [String]
    let healthWorkoutID: UUID?
    let importedWorkoutID: String?
}
