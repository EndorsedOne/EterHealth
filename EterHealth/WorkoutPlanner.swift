import Foundation

private extension Double {
    /// Rounds to the nearest multiple of `step` (e.g. nearest 5 minutes) —
    /// used so ramped durations read like a coach's round numbers, not a
    /// raw linear-interpolation artifact like "37.4 min".
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}

struct ProposedWorkout {
    let title: String
    let duration: String
    let intent: String
    let exercises: [ProposedExercise]
    let note: String
}

struct ProposedExercise: Identifiable {
    var id: String { name }
    let name: String
    let prescription: String
    let cue: String
}

@MainActor
enum WorkoutPlanner {
    static func propose(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn? = nil, now: Date = Date()) -> ProposedWorkout {
        let proposal = rawProposal(health: health, imports: imports, checkIn: checkIn, now: now)
        return InjurySafetyEngine.sanitize(proposal, injuries: InjuryStore.shared.active)
    }

    private static func rawProposal(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn? = nil, now: Date = Date()) -> ProposedWorkout {
        // TwinCore's engines no longer read these singletons internally —
        // this is the one place, outside TwinCore, responsible for it.
        let profile = GoalStore.shared.profile
        let reviews = WorkoutReviewStore.shared.reviews
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn,
                                           events: LifestyleFactorStore.shared.events, reviews: reviews,
                                           activeInjuries: InjuryStore.shared.active,
                                           calibration: TwinStateStore.shared.calibration,
                                           personalAnchor: TwinStateStore.shared.personalAnchor(now: now),
                                           profile: profile, now: now)
        let plan = TrainingPlanEngine.status(health: health, imports: imports, readiness: assessment.score,
                                             muscles: assessment.muscles, checkIn: checkIn,
                                             profile: profile, reviews: reviews,
                                             physiologicalAlert: assessment.physiologicalAlert, now: now)
        let deload = plan.isDeload
        let bodyweightOnly = !profile.gymAvailable
        // Real bpm targets instead of a bare "Z1"/"Z2" label wherever this
        // is knowable (lactate-test boundaries, a configured max, or at
        // least an age-based Tanaka estimate) — the same numbers the app's
        // own zone tracking uses, not a second, disconnected guess.
        let zones = health.currentHeartRateZoneBoundaries()
        func upTo(_ bpm: Int?) -> String { bpm.map { " · <\($0) ppm" } ?? "" }
        func range(_ low: Int?, _ high: Int?) -> String { (low != nil && high != nil) ? " · \(low!)–\(high!) ppm" : "" }
        func floor(_ bpm: Int?) -> String { bpm.map { " · >\($0) ppm" } ?? "" }
        // How far into the current phase we are — 0 at its first day, 1 at
        // its last. Lets a 6-week block ramp volume week to week instead of
        // handing the same session on week 1 as week 6, the gap flagged
        // earlier: the periodization skeleton existed, but nothing inside a
        // phase actually progressed.
        let progress = plan.block.progress(on: now)
        let primaryEvent = TrainingPlanEngine.primaryEvents(for: GoalStore.shared.profile).first
        let triDistance = primaryEvent?.resolvedTriathlonDistance
        // The distance this periodization is actually built around — nil
        // (falls back to the half-marathon reference band, scale 1.0) for
        // HYROX, strength, or an unmodelled custom challenge, never guessed.
        // A triathlon/Ironman goal still resolves to its own run *leg*
        // distance here — a half-Ironman's 21.1 km run needs exactly the
        // same long-run ceiling a standalone half marathon would, and a
        // full Ironman's marathon leg the same as a standalone marathon.
        let targetKilometers = primaryEvent?.kind.targetKilometers ?? triDistance?.runKilometers
        let swimTargetKilometers = triDistance?.swimKilometers
        let bikeTargetKilometers = triDistance?.bikeKilometers
        if assessment.score < 45 || assessment.recommendation.localizedCaseInsensitiveContains("recuperación") || assessment.recommendation.localizedCaseInsensitiveContains("descanso") {
            // A coach doesn't put rest, a run, a walk and a sauna on one
            // undifferentiated menu — there's a real hierarchy. Rest is
            // always the default, no justification needed. A second
            // stimulus only belongs in "the plan" if it actually serves a
            // goal this athlete has (a run means nothing to prescribe if
            // running isn't part of their training at all) AND is spaced
            // out enough that concurrent-training interference isn't a
            // real concern — Wilson et al. 2012's meta-analysis and Fyfe/
            // Bishop/Stepto's review both point to aerobic work too soon
            // after resistance training blunting the mTOR signaling that
            // session was for; low-intensity Z2 within a few hours is a
            // small, acceptable risk, not zero hours later. Sauna and a
            // walk are neither of those things — no periodized program
            // actually prescribes them, they're personal comfort choices
            // with a small, debated recovery effect at best — so they're
            // presented separately, as "your call", not folded into the
            // same list as if a coach endorsed them as training.
            if plan.rationale.localizedCaseInsensitiveContains("tren superior") {
                // hoursSinceLastCompleted only looks at HealthKit data (by
                // design, elsewhere) — a session logged only in Hevy, with
                // no HealthKit mirror, would be invisible to it, making
                // "hours since your strength session" silently wrong for
                // exactly the kind of session this branch exists for.
                // Checking imports directly too and taking whichever
                // source saw the more recent completion covers both.
                let hoursSinceHealthPush = TrainingPlanEngine.hoursSinceLastCompleted(
                    matching: { $0.activity == "Fuerza" || $0.activity == "Fuerza funcional" },
                    health: health, imports: imports, now: now
                )
                let hoursSinceImportedPush = imports.workouts.filter { $0.end <= now }.map(\.end).max()
                    .map { now.timeIntervalSince($0) / 3_600 }
                let hoursSincePush = [hoursSinceHealthPush, hoursSinceImportedPush].compactMap { $0 }.min()
                let calendar = Calendar.current
                let saunaAlreadyToday = LifestyleFactorStore.shared.events.contains {
                    $0.saunaMinutes > 0 && calendar.isDate($0.date, inSameDayAs: now)
                }
                let walkAlreadyToday = health.recentWorkouts.contains {
                    $0.activity == "Caminata" && calendar.isDate($0.date, inSameDayAs: now)
                }
                let hasRunningGoal = TrainingPlanEngine.goalFocus(for: GoalStore.shared.profile, on: now).running > 0.05
                var exercises = [ProposedExercise(name: "Descanso completo", prescription: "El resto del día", cue: "Es la opción por defecto — no hace falta justificar nada más")]
                // The only genuine second-training-stimulus option, and
                // only when it actually serves a real goal in this plan.
                if hasRunningGoal, let hoursSincePush, hoursSincePush >= 3 {
                    exercises.append(ProposedExercise(
                        name: "Carrera suave (aporta a tu plan)", prescription: "20–30 min · Z2\(range(zones?.z1z2, zones?.z2z3))",
                        cue: "Han pasado \(Int(hoursSincePush.rounded())) h desde la sesión de fuerza — margen suficiente para que la interferencia sea mínima, y es volumen real hacia tu objetivo de carrera"
                    ))
                }
                var extras: [ProposedExercise] = []
                if !walkAlreadyToday {
                    extras.append(ProposedExercise(name: "Paseo suave", prescription: "20–30 min", cue: "Sin efecto demostrado sobre tu progreso — hazlo solo si te apetece"))
                }
                if !saunaAlreadyToday {
                    extras.append(ProposedExercise(name: "Calor (sauna)", prescription: "15–20 min", cue: "Evidencia mixta y pequeña sobre recuperación — no forma parte del plan, hidrátate después si lo haces"))
                }
                exercises.append(contentsOf: extras)
                return ProposedWorkout(title: "Después del tren superior", duration: "Opcional",
                                       intent: hasRunningGoal ? "Descanso es la opción por defecto; la carrera es la única que realmente suma al plan" : "Ya hay estímulo real hoy — descansar es lo que corresponde",
                                       exercises: exercises,
                                       note: "Ya has entrenado tren superior con volumen real hoy.\(extras.isEmpty ? "" : " Paseo y sauna no son parte del entrenamiento — son elección personal, sin impacto real en tu progreso.")")
            }
            return ProposedWorkout(title: "Recuperación activa", duration: "25–35 min", intent: "Bajar carga y favorecer recuperación", exercises: [
                ProposedExercise(name: "Caminata suave", prescription: "20–30 min · Z1\(upTo(zones?.z1z2))", cue: "Ritmo cómodo y respiración nasal"),
                ProposedExercise(name: "Movilidad global", prescription: "2 vueltas · 6–8 min", cue: "Cadera, tobillo, dorsal y hombros")
            // TrainingPlanEngine routes several different situations to .recovery
            // (a completed session today, accumulated load, still recovering from a
            // long/quality run, 3+ training days in 72h, or moderate-low readiness)
            // — plan.rationale already says which one applies. A hardcoded "you
            // already did today's session" here was wrong for every branch except
            // the first, and showed up exactly like that after a backup restore
            // shifted readiness with zero workouts actually done that day.
            ], note: assessment.score < 45 ? "Si la fatiga se siente peor de lo que indican los datos, descansa." : "\(plan.rationale) Esta propuesta es opcional; descansar también es una buena ejecución del plan.")
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("competición"), let event = TrainingPlanEngine.eventToday(now, profile: profile) {
            // A real event today used to fall through to an ordinary
            // workout (a HYROX race day generated a training "brick",
            // a triathlon race day too, a running race a tempo session) —
            // exactly backwards: today needs a pacing/nutrition/transition/
            // stop-criteria protocol, never something to train.
            return raceDayProtocol(event: event, health: health, imports: imports, now: now)
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("carrera suave") {
            let band = easyRunBand(phase: plan.block.phase, targetKilometers: targetKilometers)
            let minutes = deload ? Int((band.min * 0.6).rounded(to: 5)) : Int(ramp(band.min, band.max, progress).rounded(to: 5))
            return ProposedWorkout(title: "Carrera suave", duration: "\(minutes + 13)–\(minutes + 18) min", intent: deload ? "Conservar frecuencia mientras disipamos fatiga" : "Construir base aeróbica sin añadir fatiga innecesaria", exercises: [
                ProposedExercise(name: "Calentamiento", prescription: "8–10 min · Z1\(upTo(zones?.z1z2))", cue: "Empieza realmente cómodo"),
                ProposedExercise(name: "Carrera continua", prescription: deload ? "\(minutes) min · Z1–Z2\(upTo(zones?.z2z3))" : "\(minutes) min · Z2\(range(zones?.z1z2, zones?.z2z3))", cue: "Ritmo conversacional y estable"),
                ProposedExercise(name: "Vuelta a la calma", prescription: "5 min suave", cue: "No necesitas terminar fuerte")
            ], note: (deload ? "Descarga activa: no prolongues la sesión aunque las sensaciones sean buenas." : "La zona cardíaca manda más que el ritmo cuando hace calor, hay desnivel o acumulas fatiga. Semana \(Int((progress * 100).rounded()))% de \(plan.block.name.lowercased()): el volumen sube progresivamente dentro de esta fase.") + goalTimelineNote())
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("calidad") {
            let modality = qualitySessionModality(phase: plan.block.phase, block: plan.block, now: now)
            let interval = intervalPrescription(phase: plan.block.phase, progress: progress, health: health, hrFloor: floor(zones?.z3z4), modality: modality)
            return ProposedWorkout(title: "Calidad de carrera", duration: "40–55 min", intent: "Estimular velocidad o umbral con volumen controlado", exercises: [
                ProposedExercise(name: "Calentamiento", prescription: "12–15 min suave", cue: "Añade movilidad y 3 progresivos"),
                ProposedExercise(name: "Bloque principal", prescription: interval.prescription, cue: interval.cue),
                ProposedExercise(name: "Vuelta a la calma", prescription: "8–10 min suave", cue: "Termina progresivamente")
            ], note: interval.basisNote + goalTimelineNote())
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("tirada larga") {
            // Base builds general aerobic tolerance; the build-specific phase
            // pushes toward what a half marathon actually demands (a peak
            // long run well past an easy-run duration); taper deliberately
            // pulls back. This is the concrete answer to "entiende el reto,
            // la ambición, y cuánto tiempo tengo para prepararlo": the ceiling
            // itself changes by phase, not just by today's deload flag.
            let band = longRunBand(phase: plan.block.phase, targetKilometers: targetKilometers)
            // The phase table sets the ambition; this never lets it override
            // reality — the actual ceiling this week is also capped by this
            // person's own recent longest run plus a safe ~15% increase, so
            // the plan can't jump straight to a fixed number regardless of
            // whether real duration tolerance has been built yet.
            let recentLongestRun = TrainingPlanEngine.recentLongestSessionMinutes(health.workoutHistory, activity: "Carrera", now: now)
            let (personalizedCeiling, isPersonalized) = TrainingPlanEngine.progressedCeiling(recent: recentLongestRun, phaseCeiling: band.max)
            let minutes = deload ? Int((band.min * 0.65).rounded(to: 5)) : Int(ramp(band.min, personalizedCeiling, progress).rounded(to: 5))
            let progressionNote = isPersonalized && personalizedCeiling < band.max
                ? " Techo ajustado a tu propia tirada más larga reciente (progresión máxima ~15%/semana), no a la tabla de fase sin más."
                : ""
            return ProposedWorkout(title: deload ? "Tirada reducida" : "Tirada larga", duration: "\(minutes + 15)–\(minutes + 25) min", intent: deload ? "Mantener resistencia sin ampliar fatiga" : "Aumentar resistencia específica", exercises: [
                ProposedExercise(name: "Inicio", prescription: "10–15 min muy suaves", cue: "No persigas ritmo"),
                ProposedExercise(name: "Bloque continuo", prescription: "\(minutes) min · Z2" + range(zones?.z1z2, zones?.z2z3), cue: "Respiración controlada y combustible si procede"),
                ProposedExercise(name: "Final", prescription: "5–10 min cómodos", cue: "Sin progresión si las piernas se deterioran")
            ], note: (deload ? "La reducción es deliberada: esta semana buscamos asimilar, no progresar distancia." : "Objetivo de esta fase (\(plan.block.name.lowercased())): progresar hacia \(Int(personalizedCeiling)) min según avance el bloque — hoy toca ≈\(minutes) min (\(Int((progress * 100).rounded()))% del bloque). No aumentes bruscamente por una sola recomendación.\(progressionNote)") + goalTimelineNote() + nutritionNote(minutes: Double(minutes) + 20))
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("natación") {
            // A triathlon/Ironman goal's swim leg had no dedicated session at
            // all before this — it either fell through to strength/bodyweight
            // or, worse, never got proposed since nothing in the decision
            // engine asked for it. Same phase/progress treatment as running.
            return swimWorkout(phase: plan.block.phase, progress: progress, deload: deload,
                               targetKilometers: swimTargetKilometers, health: health, muscles: assessment.muscles, now: now)
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("ciclismo") {
            return bikeWorkout(phase: plan.block.phase, progress: progress, deload: deload,
                               targetKilometers: bikeTargetKilometers, health: health, muscles: assessment.muscles,
                               zoneRange: range(zones?.z1z2, zones?.z2z3), zoneFloor: floor(zones?.z3z4), now: now)
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("brick") {
            // The specific stimulus a triathlon needs that swimming, biking
            // and running separately never provide: running on legs a bike
            // has already fatigued.
            return brickWorkout(phase: plan.block.phase, progress: progress, deload: deload,
                                distance: triDistance, muscles: assessment.muscles,
                                zoneRange: range(zones?.z1z2, zones?.z2z3))
        }
        if assessment.recommendation.localizedCaseInsensitiveContains("híbrido") {
            // "No pretendo que tenga entrenamiento para todos los retos del
            // mundo, pero sí para los básicos... HYROX" — hasta ahora un día
            // de "Trabajo híbrido" caía en el gimnasio genérico de abajo, sin
            // ninguna de las 8 estaciones reales ni la carrera de enlace que
            // las conecta. Esto le da al HYROX el mismo trato de periodización
            // real que ya tiene la carrera (fase, progreso dentro del bloque,
            // descarga), en vez de desentenderse del reto.
            return hyroxWorkout(phase: plan.block.phase, progress: progress, deload: deload, muscles: assessment.muscles, now: now)
        }
        if bodyweightOnly { return bodyweight(for: assessment.recommendation, light: assessment.score < 62 || deload, muscles: assessment.muscles) }
        return gym(for: assessment.recommendation, imports: imports, light: assessment.score < 62 || deload, muscles: assessment.muscles)
    }

    static func ramp(_ low: Double, _ high: Double, _ progress: Double) -> Double { low + (high - low) * min(1, max(0, progress)) }

    // The bands below were tuned for a half marathon (21.0975 km) — the goal
    // this feature was originally built against. A marathon needs a peak
    // long run meaningfully longer than that (real plans commonly peak
    // 2.5-3h), while a 5K/10K needs meaningfully less: scaling by distance
    // ratio, not a flat number regardless of race length, is what makes this
    // apply to "los básicos" instead of only the one distance it happened to
    // be written against. Capped: long-run duration doesn't scale linearly
    // forever — past a point more time on feet trades recovery for training
    // benefit already captured, which is the standard reason marathon plans
    // themselves cap the longest run rather than let it track goal pace.
    static func distanceScale(targetKilometers: Double?) -> Double {
        guard let targetKilometers, targetKilometers > 0 else { return 1.0 }
        let halfMarathonKm = 21.0975
        return min(2.2, max(0.5, targetKilometers / halfMarathonKm))
    }

    // Base builds general tolerance; build-specific asks for real long-run
    // distance (what the actual goal race needs — nowhere near an easy-run
    // duration); taper deliberately retreats. Minutes, not kilometers, since
    // pace varies with terrain/heat and duration is what actually drives
    // training stress here.
    static func longRunBand(phase: TrainingPhase, targetKilometers: Double? = nil) -> (min: Double, max: Double) {
        let scale = distanceScale(targetKilometers: targetKilometers)
        let band: (min: Double, max: Double)
        switch phase {
        case .base: band = (35, 55)
        case .buildSpecific: band = (50, 80)
        case .taper: band = (25, 40)
        case .transition: band = (30, 50)
        case .race: band = (20, 20)
        }
        return (band.min * scale, band.max * scale)
    }

    static func easyRunBand(phase: TrainingPhase, targetKilometers: Double? = nil) -> (min: Double, max: Double) {
        // Easy-run duration scales far more gently than the long run — a
        // marathoner's ordinary weekday run isn't 2x a half marathoner's,
        // only somewhat longer — hence the square root instead of the raw ratio.
        let scale = sqrt(distanceScale(targetKilometers: targetKilometers))
        let band: (min: Double, max: Double)
        switch phase {
        case .base: band = (20, 35)
        case .buildSpecific: band = (25, 40)
        case .taper: band = (15, 25)
        case .transition: band = (20, 30)
        case .race: band = (15, 15)
        }
        return (band.min * scale, band.max * scale)
    }

    // Same anchor-then-scale approach as distanceScale above, but for the
    // other two triathlon disciplines and with a wider cap: an Ironman's
    // bike leg is 4.5x an Olympic one (180 vs 40 km) and its swim leg 2.5x
    // (3.8 vs 1.5 km) — bigger jumps than a marathon is over a half
    // marathon (2x), so distanceScale's 2.2x cap would clip Ironman volume.
    static func disciplineScale(targetKilometers: Double?, referenceKilometers: Double, cap: Double) -> Double {
        guard let targetKilometers, targetKilometers > 0, referenceKilometers > 0 else { return 1.0 }
        return min(cap, max(1 / cap, targetKilometers / referenceKilometers))
    }

    // Anchored on the Olympic distance (1.5 km swim / 40 km bike) — the most
    // common "triatlón" distance, same role halfMarathonKm plays above.
    static func swimBand(phase: TrainingPhase, targetKilometers: Double? = nil) -> (min: Double, max: Double) {
        let scale = sqrt(disciplineScale(targetKilometers: targetKilometers, referenceKilometers: 1.5, cap: 3.0))
        let band: (min: Double, max: Double)
        switch phase {
        case .base: band = (20, 35)
        case .buildSpecific: band = (30, 50)
        case .taper: band = (15, 25)
        case .transition: band = (20, 30)
        case .race: band = (15, 15)
        }
        return (band.min * scale, band.max * scale)
    }

    static func bikeBand(phase: TrainingPhase, targetKilometers: Double? = nil) -> (min: Double, max: Double) {
        let scale = disciplineScale(targetKilometers: targetKilometers, referenceKilometers: 40, cap: 5.0)
        let band: (min: Double, max: Double)
        switch phase {
        case .base: band = (40, 70)
        case .buildSpecific: band = (60, 110)
        case .taper: band = (30, 50)
        case .transition: band = (40, 60)
        case .race: band = (30, 30)
        }
        return (band.min * scale, band.max * scale)
    }

    // Nutrition guidance for a session long enough to need in-session
    // fueling (EnduranceNutritionEngine itself returns nil under 60 min,
    // so calling this for a short easy run or swim session is a safe no-
    // op). Pulls expected race-day air temperature from the active goal's
    // own course details when the athlete has entered one — never guessed.
    private static func nutritionNote(minutes: Double) -> String {
        guard let guidance = EnduranceNutritionEngine.guidance(
            durationMinutes: minutes,
            expectedAirTemperatureCelsius: TrainingPlanEngine.primaryEvents(for: GoalStore.shared.profile).first?.courseDetails?.expectedAirTemperatureCelsius
        ) else { return "" }
        return " Nutrición de referencia: \(EnduranceNutritionEngine.summary(guidance)). \(guidance.note)"
    }

    // Ties today's session to the actual goal it's supposedly building
    // toward, using the real (now-fixed) Riegel forecast instead of leaving
    // the connection implicit. Empty string (not a placeholder sentence)
    // when there's no active dated goal or not enough data for a forecast —
    // never invents a countdown or a pace nobody has run.
    private static func goalTimelineNote() -> String {
        guard let goal = GoalStore.shared.nextEvent(), let date = goal.date else { return "" }
        let weeks = max(0, Int(date.timeIntervalSince(Date()) / (7 * 86_400)))
        return " Faltan \(weeks) semanas para tu \(goal.title.lowercased())."
    }

    // Below this, the twin's own per-muscle readiness (already computed by
    // TwinEngine from real training history and each muscle's own learned
    // recovery half-life — the exact number PhysiologicalHealthView already
    // shows) actually changes what gets prescribed, instead of being
    // computed and then discarded: the freshest muscle in the target group
    // gets first pick, and a muscle that's still in its own recovery window
    // gets an explicit cue rather than silently being loaded the same as if
    // it were fully recovered.
    private static func recoveryCue(for muscleNames: [String], in muscles: [MuscleReadiness]) -> String? {
        let readiness = muscles.filter { muscleNames.contains($0.name) }
        guard let worst = readiness.min(by: { $0.readiness < $1.readiness }), worst.readiness < 55 else { return nil }
        return " \(worst.name) sigue en ventana de recuperación (\(worst.readiness)/100) — prioriza técnica, no busques el fallo."
    }

    private static func bodyweight(for recommendation: String, light: Bool, muscles: [MuscleReadiness]) -> ProposedWorkout {
        let rounds = light ? 3 : 4
        if recommendation.localizedCaseInsensitiveContains("pierna") {
            let legMuscles = ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"]
            return ProposedWorkout(title: "Pierna sin gimnasio", duration: "35–45 min", intent: light ? "Mantenimiento técnico" : "Fuerza unilateral y estabilidad", exercises: [
                ProposedExercise(name: "Sentadilla búlgara", prescription: "\(rounds) × 8–12 por pierna", cue: "Deja 2 repeticiones en reserva"),
                ProposedExercise(name: "Zancada inversa", prescription: "3 × 10 por pierna", cue: "Controla 3 s la bajada"),
                ProposedExercise(name: "Puente de glúteo unilateral", prescription: "3 × 12–15", cue: "Pausa 1 s arriba"),
                ProposedExercise(name: "Curl femoral deslizante", prescription: "3 × 8–12", cue: "Usa una toalla sobre suelo liso"),
                ProposedExercise(name: "Gemelo unilateral", prescription: "3 × 15–25", cue: "Recorrido completo"),
                ProposedExercise(name: "Plancha lateral", prescription: "3 × 30–45 s por lado", cue: "Pelvis estable")
            ], note: "Evita colocarla junto a otra sesión dura de carrera si las piernas siguen cargadas." + (recoveryCue(for: legMuscles, in: muscles) ?? ""))
        }
        if recommendation.localizedCaseInsensitiveContains("tirón") {
            let pullMuscles = ["Espalda", "Bíceps", "Core"]
            return ProposedWorkout(title: "Tirón y core sin gimnasio", duration: "30–40 min", intent: "Mantener espalda y bíceps", exercises: [
                ProposedExercise(name: "Remo con mochila", prescription: "\(rounds) × 10–15", cue: "Carga la mochila y deja 2 repeticiones en reserva"),
                ProposedExercise(name: "Remo invertido bajo mesa segura", prescription: "3 × 6–12", cue: "Solo si la mesa es completamente estable"),
                ProposedExercise(name: "Pájaros con botellas", prescription: "3 × 15–20", cue: "Sin impulso"),
                ProposedExercise(name: "Curl con mochila", prescription: "3 × 10–15", cue: "Codos quietos"),
                ProposedExercise(name: "Dead bug", prescription: "3 × 8–12 por lado", cue: "Lumbar apoyada")
            ], note: "Si no hay un apoyo seguro para remar, sustituye el remo invertido por otra serie de remo con mochila." + (recoveryCue(for: pullMuscles, in: muscles) ?? ""))
        }
        let pushMuscles = ["Pecho", "Hombros", "Tríceps"]
        return ProposedWorkout(title: "Empuje sin gimnasio", duration: "30–40 min", intent: light ? "Mantenimiento con margen" : "Pecho, hombro y tríceps", exercises: [
            ProposedExercise(name: "Flexiones", prescription: "\(rounds) × 8–20", cue: "Termina con 2 repeticiones en reserva"),
            ProposedExercise(name: "Flexiones pike", prescription: "3 × 6–12", cue: "Cabeza hacia delante de las manos"),
            ProposedExercise(name: "Fondos en banco estable", prescription: "3 × 8–15", cue: "Sin dolor anterior de hombro"),
            ProposedExercise(name: "Flexiones cerradas", prescription: "3 × 6–12", cue: "Prioriza tríceps"),
            ProposedExercise(name: "Hollow hold", prescription: "3 × 20–40 s", cue: "Reduce palanca si arqueas la zona lumbar")
        ], note: "Aumenta dificultad con tempo lento o mochila antes de añadir muchas repeticiones." + (recoveryCue(for: pushMuscles, in: muscles) ?? ""))
    }

    // Internal (not private) so EngineTests can exercise the tracked-lift
    // pinning behavior directly, without needing a full status()-driven
    // .strength decision plus real gym-availability plumbing just to reach it.
    static func gym(for recommendation: String, imports: ImportStore, light: Bool, muscles: [MuscleReadiness]) -> ProposedWorkout {
        let target: [String]
        if recommendation.localizedCaseInsensitiveContains("pierna") { target = ["Cuádriceps", "Glúteos", "Isquios"] }
        else if recommendation.localizedCaseInsensitiveContains("tirón") { target = ["Espalda", "Bíceps"] }
        else { target = ["Pecho", "Hombros", "Tríceps"] }
        let readinessByMuscle = Dictionary(uniqueKeysWithValues: muscles.map { ($0.name, $0.readiness) })
        // Default a muscle éter has no learned data for yet to "fresh" (100)
        // rather than penalizing it for being unmeasured.
        func exerciseReadiness(_ name: String) -> Int {
            let groups = MuscleMap.groups(for: name).filter { target.contains($0) }
            let values = groups.compactMap { readinessByMuscle[$0] }
            return values.isEmpty ? 100 : values.reduce(0, +) / values.count
        }
        var names: [String] = []
        for workout in imports.workouts.sorted(by: { $0.start > $1.start }) {
            for exercise in workout.exercises where !names.contains(exercise.name) && !Set(MuscleMap.groups(for: exercise.name)).isDisjoint(with: target) {
                names.append(exercise.name)
            }
            // Gather a wider pool than the 5 we'll actually prescribe, so
            // there's something real to choose between by freshness — taking
            // only the first 5 by recency would just reintroduce whichever
            // muscle happens to dominate this person's usual routine order.
            if names.count >= 10 { break }
        }
        // These must be names MuscleMap.groups/involvement actually
        // recognizes (its substring matching is English-only, the same
        // convention Hevy's own exports use — "Sentadilla"/"Press banca"
        // silently fell through to its generic "Cuerpo completo" bucket,
        // and "Curl femoral" was misread as a biceps curl via the bare
        // "curl" check). Also exact matches for ExerciseCatalog, so a
        // cold-start proposal gets the right equipment/pattern icon too.
        let fallback = target.first == "Cuádriceps"
            ? ["Squat (Barbell)", "Romanian Deadlift (Barbell)", "Leg Press (Machine)", "Leg Curl (Machine)"]
            : target.first == "Espalda"
            ? ["Pull Up", "Bent Over Row (Barbell)", "Lat Pulldown (Cable)", "Biceps Curl (Dumbbell)"]
            : ["Bench Press (Barbell)", "Standing Military Press (Barbell)", "Incline Bench Press (Dumbbell)", "Triceps Extension (Cable)"]
        var pool = names.isEmpty ? fallback : names.sorted { exerciseReadiness($0) > exerciseReadiness($1) }
        // A specifically tracked lift (bench press, sentadilla) must be
        // the actual exercise trained on its own day, not just whichever
        // variation happens to rank first by muscle-group freshness —
        // freshness ties (same muscle group, same score) resolve by recency,
        // which can quietly bury the tracked lift under a more recently
        // done equivalent (e.g. incline press) indefinitely. A goal whose
        // number is "100 kg de press banca" needs press banca itself,
        // pinned to the top of today's session, whenever this pattern is
        // the one an active tracked-lift goal owns.
        let trackedLiftTerms: [String]?
        // "(barbell)" matters for bench press: bare "bench press" also
        // matches Incline/Dumbbell variations that aren't the tracked
        // flat-barbell lift a "100 kg de press banca" goal actually means.
        if target.first == "Pecho", GoalStore.shared.profile.goals.contains(where: { $0.isActive && $0.kind == .benchPress }) {
            trackedLiftTerms = ["bench press (barbell)", "press banca"]
        } else if target.first == "Cuádriceps", GoalStore.shared.profile.goals.contains(where: { $0.isActive && $0.kind == .squat }) {
            trackedLiftTerms = ["squat (barbell)", "sentadilla"]
        } else {
            trackedLiftTerms = nil
        }
        if let trackedLiftTerms {
            if let pinned = pool.first(where: { name in trackedLiftTerms.contains { name.localizedCaseInsensitiveContains($0) } }) {
                pool.removeAll { $0 == pinned }
                pool.insert(pinned, at: 0)
            } else {
                pool.insert(trackedLiftTerms[0].contains("bench press") ? "Bench Press (Barbell)" : "Squat (Barbell)", at: 0)
            }
        }
        let goals = GoalStore.shared.profile.goals
        let exercises = Self.diversifiedTop(pool, count: 5).map { name in
            let last = imports.workouts.sorted(by: { $0.start > $1.start })
                .lazy.flatMap(\.exercises)
                .first { $0.name == name && $0.averageWeight != nil }
            let load = last?.averageWeight.map { conservativeLoad($0, light: light) }
            let band = StrengthPrescriptionEngine.repRange(for: StrengthPrescriptionEngine.goalContext(for: name, goals: goals), light: light)
            let prescription = band.label
            var cue = load.map { "Empieza con ≈ \($0.formatted()) kg y ajusta al RIR" } ?? "Usa una carga conocida que respete el RIR"
            if !band.rationale.isEmpty { cue += " · " + band.rationale }
            let readiness = exerciseReadiness(name)
            if readiness < 55 { cue += " · su grupo muscular está a \(readiness)/100 de tu recuperación aprendida: no busques el fallo hoy." }
            return ProposedExercise(name: name, prescription: prescription, cue: cue)
        }
        let leastFresh = target.compactMap { muscle in muscles.first { $0.name == muscle } }.min { $0.readiness < $1.readiness }
        let recoveryNote = (leastFresh?.readiness ?? 100) < 55 ? " \(leastFresh!.name) sigue recuperándose (\(leastFresh!.readiness)/100); los ejercicios de arriba ya priorizan el grupo más fresco disponible." : ""
        return ProposedWorkout(title: recommendation, duration: "45–60 min", intent: "Sesión basada en tus ejercicios habituales de Hevy", exercises: Array(exercises), note: "Las cargas se estiman desde tu historial de Hevy y deben ajustarse por técnica y repeticiones en reserva." + recoveryNote)
    }

    /// Picks up to `count` names from `ranked` (already sorted best-first),
    /// preferring one exercise per distinct movement pattern (via
    /// `ExerciseCatalog`) before ever repeating a pattern — muscle-group
    /// freshness alone can fill a whole session with five press variants
    /// ("Empuje horizontal" ×5) while skipping vertical-push or isolation
    /// patterns that would train the same muscles more completely. The
    /// first element is always kept as-is (it may be a goal-pinned tracked
    /// lift) even though that "uses" its pattern before diversity applies
    /// to the rest.
    private static func diversifiedTop(_ ranked: [String], count: Int) -> [String] {
        guard !ranked.isEmpty else { return [] }
        var remaining = ranked
        var selected = [remaining.removeFirst()]
        var usedPatterns = Set([ExerciseCatalog.descriptor(for: selected[0]).pattern])
        while selected.count < count, !remaining.isEmpty {
            let index = remaining.firstIndex { !usedPatterns.contains(ExerciseCatalog.descriptor(for: $0).pattern) } ?? remaining.startIndex
            let name = remaining.remove(at: index)
            selected.append(name)
            usedPatterns.insert(ExerciseCatalog.descriptor(for: name).pattern)
        }
        return selected
    }

    // Every "Calidad de carrera" session used to be the exact same flat-
    // ground, pace-based interval template all block long — real half-
    // marathon periodization also rotates in short sprints/strides
    // (neuromuscular power and running economy, at a fatigue cost too low
    // to interfere with the rest of the week) and hill repeats (the same
    // power/strength-endurance stimulus, at an effort a gradient sets
    // rather than an invented flat-ground pace). Both belong specifically
    // to the base phase — build-specific's job is race-pace-specific
    // threshold work, and taper's is short/fast sharpening, so neither is
    // touched here. Cycling by full weeks since the block started keeps
    // the rotation deterministic and explainable instead of random.
    // vo2Max4x4 added alongside the original three — Helgerud/Wisløff's
    // 4×4 protocol (see vo2Max4x4Prescription below) directly targets the
    // one variable Brandt et al. 2025's real HYROX study found correlates
    // most with race time (VO2max, ρ=-0.71) — more than grip or muscle
    // mass, which is exactly what HyroxForecastEngine's own bottleneck
    // check already flags when VO2max is the limiter.
    enum QualitySessionModality: Equatable { case sprints, hillRepeats, flatIntervals, vo2Max4x4 }

    static func qualitySessionModality(phase: TrainingPhase, block: TrainingBlock, now: Date) -> QualitySessionModality {
        guard phase == .base else { return .flatIntervals }
        let weeksSinceStart = max(0, Int(now.timeIntervalSince(block.start) / (7 * 86_400)))
        switch weeksSinceStart % 4 {
        case 0: return .sprints
        case 1: return .hillRepeats
        case 2: return .vo2Max4x4
        default: return .flatIntervals
        }
    }

    // Short and near-maximal, with full recovery — this is about power and
    // economy, not about pace or aerobic load, so it deliberately never
    // touches the Riegel forecast (nothing to invent or fall back on).
    private static func sprintPrescription(progress: Double) -> (prescription: String, cue: String, basisNote: String) {
        let reps = Int(ramp(6, 10, progress).rounded())
        return (
            "\(reps) × 100 m progresivos (de trote a máximo esfuerzo) · recuperación completa caminando",
            "Potencia y economía de carrera, no resistencia — termina cada repetición cerca del esfuerzo máximo, nunca agotado. Técnica relajada, sin forzar los hombros.",
            "Fase de base: estímulo de velocidad y economía sin la fatiga de un trabajo específico de ritmo de carrera. "
        )
    }

    // Time-based, not pace-based — a gradient invalidates any flat-ground
    // pace claim, so effort (and the existing HR floor cue) drives this one
    // instead of a number this app has no way to compute honestly.
    private static func hillRepeatPrescription(progress: Double, hrFloor: String) -> (prescription: String, cue: String, basisNote: String) {
        let reps = Int(ramp(5, 8, progress).rounded())
        return (
            "\(reps) × 45–60 s cuesta arriba a esfuerzo fuerte y controlado\(hrFloor) · bajada trotando de recuperación",
            "El esfuerzo lo marca la pendiente, no un ritmo — controla la técnica en la bajada; no la conviertas en la parte dura de la sesión.",
            "Fase de base: fuerza-resistencia y potencia en cuesta, sin necesitar una marca de ritmo llano. "
        )
    }

    // Helgerud & Hoff/Wisløff's 4×4 protocol (Helgerud et al. 2007, Med
    // Sci Sports Exerc — high-intensity aerobic intervals improving
    // VO2max more than moderate-intensity training) — one of the most
    // replicated VO2max-specific interval protocols in the exercise
    // science literature. Time/effort-based like hill repeats above, not
    // pace-based: this protocol was validated against heart rate, not a
    // flat-ground pace, so it reuses the same hrFloor cue rather than
    // inventing one.
    private static func vo2Max4x4Prescription(hrFloor: String) -> (prescription: String, cue: String, basisNote: String) {
        (
            "4 × 4 min al 90–95% de tu FC máxima\(hrFloor) · 3 min de trote de recuperación activa entre series",
            "El objetivo es VO2 máx., no ritmo: entra fuerte para llegar a esa frecuencia cardiaca hacia el minuto 2–3 de cada serie y mantenla el resto. La recuperación es trote suave, nunca parada.",
            "Protocolo 4×4 (Helgerud et al. 2007): uno de los más replicados para mejorar el VO2 máx. — la variable que más correlacionó con el resultado en HYROX según Brandt et al. 2025. "
        )
    }

    // The gap this closes: "4-6 repeticiones controladas" told you nothing a
    // coach would actually write down — no pace, no distance, no rest. This
    // anchors on the athlete's own Riegel forecast (RunningPerformanceEngine,
    // fixed earlier this session) — never a guessed pace — and shapes the
    // rep distance/pace/count by training phase: short and fast in base
    // (speed/VO2max without race-specific fatigue), longer and at threshold
    // pace during build-specific (what a half marathon actually demands),
    // short and sharp in taper (sharpening, not loading). `modality`
    // defaults to the flat-ground template below (the only one this
    // function used to have) — sprints/hills are opted into explicitly by
    // the caller once it knows the phase and block, via
    // `qualitySessionModality`.
    static func intervalPrescription(phase: TrainingPhase, progress: Double, health: HealthStore, hrFloor: String,
                                     modality: QualitySessionModality = .flatIntervals)
        -> (prescription: String, cue: String, basisNote: String) {
        switch modality {
        case .sprints: return sprintPrescription(progress: progress)
        case .hillRepeats: return hillRepeatPrescription(progress: progress, hrFloor: hrFloor)
        case .vo2Max4x4: return vo2Max4x4Prescription(hrFloor: hrFloor)
        case .flatIntervals: break
        }
        struct Template { let meters: Int; let minReps: Int; let maxReps: Int; let paceOffsetSeconds: Double; let recovery: String; let paceLabel: String }
        let template: Template
        switch phase {
        case .base:
            template = Template(meters: 400, minReps: 4, maxReps: 6, paceOffsetSeconds: 0, recovery: "90 s trote suave", paceLabel: "tu ritmo de referencia")
        case .buildSpecific:
            template = Template(meters: 1000, minReps: 4, maxReps: 6, paceOffsetSeconds: 12, recovery: "2 min trote suave", paceLabel: "ritmo umbral (tu referencia +12 s/km)")
        case .taper:
            template = Template(meters: 300, minReps: 3, maxReps: 4, paceOffsetSeconds: -5, recovery: "recuperación completa", paceLabel: "tu ritmo de referencia, algo más rápido")
        case .transition, .race:
            template = Template(meters: 600, minReps: 4, maxReps: 5, paceOffsetSeconds: 5, recovery: "2 min trote suave", paceLabel: "tu ritmo de referencia")
        }
        let reps = Int(ramp(Double(template.minReps), Double(template.maxReps), progress).rounded())

        let summary = RunningPerformanceEngine.summarize(workouts: health.workoutHistory, zones: health.runningHeartRateZones, reviews: WorkoutReviewStore.shared.reviews)
        // 5K forecast preferred (closest to a real interval effort); 10K only
        // as a fallback when 5K itself has no basis yet. No forecast at all
        // means no invented pace — the generic prescription stays instead.
        let reference: (secondsPerKm: Double, distanceName: String)?
        if let fiveK = summary.fiveK { reference = (fiveK.seconds / 5, "5 km") }
        else if let tenK = summary.tenK { reference = (tenK.seconds / 10, "10 km") }
        else { reference = nil }

        guard let reference else {
            return (
                "\(reps) repeticiones controladas\(hrFloor)",
                "Recupera lo suficiente para mantener técnica; no es un test.",
                "Sin marca de referencia todavía para calcular un ritmo objetivo: hacen falta más carreras con distancia registrada. Éter ya no inventa un ritmo — usa esta versión general mientras tanto. "
            )
        }
        let targetSecondsPerKm = reference.secondsPerKm + template.paceOffsetSeconds
        let repMinutesPerKm = targetSecondsPerKm / 60
        let repPace = DecisionSimulatorEngine.formatPace(repMinutesPerKm)
        let prescription = "\(reps) × \(template.meters) m a \(repPace) min/km\(hrFloor) · \(template.recovery)"
        let cue = "\(template.paceLabel.capitalized) — recupera lo suficiente para mantener la técnica; no es un test."
        let basisNote = "Ritmo calculado desde tu marca estimada de \(reference.distanceName) (modelo de Riegel sobre tus carreras reales). "
        return (prescription, cue, basisNote)
    }

    // The 8 real HYROX stations, each paired with the 1 km compromised run
    // that actually connects them in the race — not a generic circuit that
    // happens to share the name. `buildReference` is the amount at full
    // ramp inside the build-specific phase; every other phase takes a
    // fraction of it via `hyroxPhaseBand`, the same periodization treatment
    // the running bands above already get.
    struct HyroxStation { let name: String; let unit: String; let buildReference: Double; let muscles: [String]; let cue: String }

    static let hyroxStations: [HyroxStation] = [
        HyroxStation(name: "SkiErg", unit: "m", buildReference: 900, muscles: ["Espalda", "Hombros", "Tríceps"], cue: "Empuja con las piernas y el core, no solo con los brazos"),
        HyroxStation(name: "Sled Push", unit: "m", buildReference: 45, muscles: ["Cuádriceps", "Glúteos"], cue: "Pasos cortos y cadera baja, empuje continuo"),
        HyroxStation(name: "Sled Pull", unit: "m", buildReference: 45, muscles: ["Espalda", "Isquios"], cue: "Tira con la cadera hacia atrás, brazos como cable"),
        HyroxStation(name: "Burpee Broad Jump", unit: "m", buildReference: 70, muscles: ["Cuádriceps", "Core"], cue: "Aterriza suave y encadena sin pausas largas"),
        HyroxStation(name: "Remo (row)", unit: "m", buildReference: 900, muscles: ["Espalda", "Isquios", "Bíceps"], cue: "Piernas, tronco y brazos en ese orden"),
        HyroxStation(name: "Farmers Carry", unit: "m", buildReference: 180, muscles: ["Core", "Hombros"], cue: "Hombros abajo y atrás, pasos rápidos y cortos"),
        HyroxStation(name: "Sandbag Lunges", unit: "m", buildReference: 90, muscles: ["Cuádriceps", "Glúteos"], cue: "Rodilla trasera casi al suelo, torso alto"),
        HyroxStation(name: "Wall Balls", unit: "reps", buildReference: 70, muscles: ["Cuádriceps", "Hombros"], cue: "Recibe la pelota en sentadilla, no la frenes con los brazos")
    ]

    // Base builds general tolerance to the movement patterns; build-specific
    // pushes toward real HYROX volume; taper retreats; race week keeps only
    // enough to stay sharp. Mirrors longRunBand/easyRunBand's structure —
    // the same "understand the challenge, the ambition, the time available"
    // answer, applied to a non-running goal instead of leaving it unmodelled.
    static func hyroxPhaseBand(_ phase: TrainingPhase) -> (min: Double, max: Double) {
        switch phase {
        case .base: return (0.5, 0.75)
        case .buildSpecific: return (0.8, 1.05)
        case .taper: return (0.5, 0.65)
        case .transition: return (0.55, 0.75)
        case .race: return (0.4, 0.4)
        }
    }

    // A full 8-station simulation is itself a specific, race-week tool —
    // not what a Tuesday session should ask for. This rotates a subset
    // through so every station still gets trained regularly, deterministic
    // on the week of year so the same week always proposes the same
    // stations (testable, and it won't reshuffle mid-week) while cycling
    // through all 8 rather than favouring the same handful forever.
    static func hyroxRotation(now: Date, count: Int = 5) -> [HyroxStation] {
        let week = Calendar.current.component(.weekOfYear, from: now)
        let start = week % hyroxStations.count
        return (0..<count).map { hyroxStations[(start + $0) % hyroxStations.count] }
    }

    private static func hyroxWorkout(phase: TrainingPhase, progress: Double, deload: Bool, muscles: [MuscleReadiness], now: Date) -> ProposedWorkout {
        let band = hyroxPhaseBand(phase)
        let intensity = ramp(band.min, band.max, progress) * (deload ? 0.7 : 1.0)
        let stations = hyroxRotation(now: now)
        var exercises: [ProposedExercise] = [
            ProposedExercise(name: "Activación", prescription: "10 min carrera muy suave + movilidad de cadera y tobillo", cue: "Llega a la primera estación ya caliente, no frío")
        ]
        for station in stations {
            let amount = max(station.unit == "reps" ? 15 : 10, Int((station.buildReference * intensity / 5).rounded()) * 5)
            let prescription = station.unit == "reps" ? "\(amount) repeticiones" : "\(amount) m"
            exercises.append(ProposedExercise(name: "Carrera de enlace", prescription: "1 km", cue: "Al ritmo objetivo del HYROX, no un sprint aislado"))
            exercises.append(ProposedExercise(name: station.name, prescription: prescription, cue: station.cue + (recoveryCue(for: station.muscles, in: muscles) ?? "")))
        }
        exercises.append(ProposedExercise(name: "Vuelta a la calma", prescription: "5–8 min suave", cue: "Estira gemelo y antebrazo, hoy han cargado más de lo normal"))
        let title = deload ? "HYROX reducido" : "Simulación HYROX"
        let intent = deload ? "Mantener el patrón de las estaciones sin ampliar fatiga" : "Progresar volumen específico de las \(stations.count) estaciones de hoy hacia el ritmo de competición"
        let note = (deload
            ? "La reducción es deliberada: esta semana buscamos asimilar el patrón, no sumar más volumen a las estaciones."
            : "Fase \(phase == .buildSpecific ? "de construcción específica" : phase == .taper ? "de afinamiento" : phase == .race ? "de competición" : phase == .transition ? "de transición" : "de base"): hoy toca ≈\(Int((intensity * 100).rounded()))% del volumen de referencia por estación (\(Int((progress * 100).rounded()))% del bloque). Rotan 5 de las 8 estaciones reales del HYROX cada semana — esta semana: \(stations.map(\.name).joined(separator: ", ")).")
            + goalTimelineNote()
        return ProposedWorkout(title: title, duration: "60–80 min", intent: intent, exercises: exercises, note: note)
    }

    // Swim leg of a triathlon/Ironman goal. Reuses
    // TriathlonForecastEngine's own personal-pace helper so the pace shown
    // here and the pace the forecast card uses are the same number, never
    // two disconnected guesses — and stays honest when that number is
    // still the generic placeholder (no swim history yet).
    private static func swimWorkout(phase: TrainingPhase, progress: Double, deload: Bool,
                                    targetKilometers: Double?, health: HealthStore, muscles: [MuscleReadiness], now: Date) -> ProposedWorkout {
        let band = swimBand(phase: phase, targetKilometers: targetKilometers)
        let recentLongestSwim = TrainingPlanEngine.recentLongestSessionMinutes(health.workoutHistory, activity: "Natación", now: now)
        let (personalizedCeiling, isPersonalized) = TrainingPlanEngine.progressedCeiling(recent: recentLongestSwim, phaseCeiling: band.max)
        let minutes = deload ? Int((band.min * 0.65).rounded(to: 5)) : Int(ramp(band.min, personalizedCeiling, progress).rounded(to: 5))
        let pace = TriathlonForecastEngine.personalSwimPace100mSeconds(TriathlonForecastEngine.swimSessions(health.workoutHistory))
        let mainSet: String
        let cue: String
        switch phase {
        case .base:
            mainSet = "8–16 × 100 m técnica con 20 s de descanso"
            cue = "Prioriza técnica y respiración bilateral, no velocidad"
        case .buildSpecific:
            if let pace {
                mainSet = "6–10 × 200 m a \(DecisionSimulatorEngine.formatPace(pace / 60))/100 m con 20–30 s de descanso"
            } else {
                mainSet = "6–10 × 200 m controlados, sin marca de referencia todavía"
            }
            cue = "Simula el ritmo real de carrera; no lo conviertas en un test"
        case .taper:
            mainSet = "4–6 × 100 m rápidos y cortos con descanso completo"
            cue = "Activación, no fatiga — llegar fresco importa más que sumar metros"
        case .transition, .race:
            mainSet = "6–8 × 150 m a ritmo moderado"
            cue = "Recupera el patrón sin buscar velocidad máxima"
        }
        let progressionNote = isPersonalized && personalizedCeiling < band.max
            ? " Techo ajustado a tu nado más largo reciente (progresión máxima ~15%/semana)."
            : ""
        return ProposedWorkout(
            title: deload ? "Natación reducida" : "Natación", duration: "\(minutes) min",
            intent: deload ? "Mantener el patrón técnico sin sumar fatiga" : "Construir la resistencia y el ritmo específicos de la pierna de natación",
            exercises: [
                ProposedExercise(name: "Calentamiento", prescription: "300–500 m suave + movilidad de hombro", cue: "Activa el patrón antes de acelerar"),
                ProposedExercise(name: "Serie principal", prescription: mainSet, cue: cue + (recoveryCue(for: ["Espalda", "Hombros", "Core"], in: muscles) ?? "")),
                ProposedExercise(name: "Vuelta a la calma", prescription: "150–200 m muy suave", cue: "Piernas relajadas, respiración larga")
            ],
            note: (pace == nil ? "Sin sesiones de natación registradas todavía: el ritmo de la serie es genérico, no el tuyo. " : "")
                + "Semana \(Int((progress * 100).rounded()))% del bloque · \(minutes) min de referencia.\(progressionNote)" + goalTimelineNote()
        )
    }

    // Bike leg. Same personal-speed reuse as the swim session above; the
    // build-specific block practices race position/nutrition instead of
    // just accumulating time, mirroring how running's build-specific phase
    // asks for threshold pace instead of generic volume.
    private static func bikeWorkout(phase: TrainingPhase, progress: Double, deload: Bool, targetKilometers: Double?,
                                    health: HealthStore, muscles: [MuscleReadiness], zoneRange: String, zoneFloor: String, now: Date) -> ProposedWorkout {
        let band = bikeBand(phase: phase, targetKilometers: targetKilometers)
        let recentLongestBike = TrainingPlanEngine.recentLongestSessionMinutes(health.workoutHistory, activity: "Ciclismo", now: now)
        let (personalizedCeiling, isPersonalized) = TrainingPlanEngine.progressedCeiling(recent: recentLongestBike, phaseCeiling: band.max)
        let minutes = deload ? Int((band.min * 0.6).rounded(to: 5)) : Int(ramp(band.min, personalizedCeiling, progress).rounded(to: 5))
        let speed = TriathlonForecastEngine.personalBikeSpeedKmh(TriathlonForecastEngine.bikeSessions(health.workoutHistory))
        let mainSet: String
        let cue: String
        switch phase {
        case .base:
            mainSet = "\(max(15, minutes - 15)) min continuos · Z2\(zoneRange)"
            cue = "Cadencia alta (85–95 rpm), sin buscar potencia"
        case .buildSpecific:
            mainSet = "3–5 × 8–12 min a ritmo de carrera\(zoneFloor) con 3–4 min suaves de recuperación"
            cue = "Practica la posición y la alimentación que usarás el día de la carrera"
        case .taper:
            mainSet = "3–4 × 5 min a ritmo objetivo con recuperación completa"
            cue = "Activación, no fatiga — las piernas deben llegar frescas"
        case .transition, .race:
            mainSet = "\(max(10, minutes - 10)) min continuos · Z2\(zoneRange)"
            cue = "Recupera el patrón sin buscar potencia"
        }
        return ProposedWorkout(
            title: deload ? "Ciclismo reducido" : "Ciclismo", duration: "\(minutes) min",
            intent: deload ? "Mantener el patrón sin sumar fatiga" : "Construir la resistencia y el ritmo específicos de la pierna de bici",
            exercises: [
                ProposedExercise(name: "Calentamiento", prescription: "10–15 min progresivo", cue: "Sube cadencia antes que potencia"),
                ProposedExercise(name: "Bloque principal", prescription: mainSet, cue: cue + (recoveryCue(for: ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"], in: muscles) ?? "")),
                ProposedExercise(name: "Vuelta a la calma", prescription: "10 min muy suave", cue: "Cadencia ligera, sin carga")
            ],
            note: (speed == nil ? "Sin salidas de bici registradas todavía: la velocidad de referencia es genérica, no la tuya. " : "")
                + "Semana \(Int((progress * 100).rounded()))% del bloque · \(minutes) min de referencia."
                + (isPersonalized && personalizedCeiling < band.max ? " Techo ajustado a tu salida más larga reciente (progresión máxima ~15%/semana)." : "")
                + goalTimelineNote() + nutritionNote(minutes: Double(minutes))
        )
    }

    // The specific stimulus nothing else in the plan provides: running on
    // legs a bike has already fatigued. Deliberately short on the run
    // portion — this trains the transition and the pacing discipline of
    // not chasing the fatigue, not distance.
    private static func brickWorkout(phase: TrainingPhase, progress: Double, deload: Bool,
                                     distance: TriathlonDistance?, muscles: [MuscleReadiness], zoneRange: String) -> ProposedWorkout {
        let bikeBand: (min: Double, max: Double)
        switch phase {
        case .base: bikeBand = (20, 30)
        case .buildSpecific: bikeBand = (30, 45)
        case .taper: bikeBand = (15, 25)
        case .transition: bikeBand = (20, 30)
        case .race: bikeBand = (15, 15)
        }
        let bikeMinutes = deload ? Int((bikeBand.min * 0.7).rounded(to: 5)) : Int(ramp(bikeBand.min, bikeBand.max, progress).rounded(to: 5))
        let runMinutes = deload ? 8 : Int(ramp(10, 20, progress).rounded(to: 5))
        // The athlete's own real transition plan (kit order, nutrition
        // staged, whatever they've actually written down) beats a generic
        // "practice your transition" cue whenever they've entered one.
        let courseDetails = TrainingPlanEngine.primaryEvents(for: GoalStore.shared.profile).first?.courseDetails
        let transitionCue = (courseDetails?.transitionNotes.isEmpty == false)
            ? "Tu plan de transición: \(courseDetails!.transitionNotes)"
            : "Practica el cambio de material como lo harás el día de la carrera"
        return ProposedWorkout(
            title: deload ? "Brick reducido" : "Brick bici-carrera",
            duration: "\(bikeMinutes + runMinutes + 5)–\(bikeMinutes + runMinutes + 10) min",
            intent: deload ? "Mantener la sensación de piernas cansadas sin sumar fatiga" : "Entrenar la transición y el ritmo de carrera con las piernas ya cargadas",
            exercises: [
                ProposedExercise(name: "Bici", prescription: "\(bikeMinutes) min · Z2\(zoneRange)", cue: "Los últimos 5 min sube ligeramente el ritmo, simulando el final de la pierna de bici"),
                ProposedExercise(name: "Transición", prescription: "< 2 min", cue: transitionCue),
                ProposedExercise(name: "Carrera", prescription: "\(runMinutes) min a ritmo objetivo de \((distance ?? .olympic).rawValue)",
                                cue: "Las primeras piernas pesan; no es una señal de mal día" + (recoveryCue(for: ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"], in: muscles) ?? ""))
            ],
            note: "Objetivo de esta fase: acostumbrar al cuerpo a correr con fatiga de bici — la transferencia real que ninguna sesión por separado entrena." + goalTimelineNote()
                + nutritionNote(minutes: Double(bikeMinutes + runMinutes))
        )
    }

    // Today IS the event — this builds an execution protocol (pacing,
    // nutrition, transition, stop criteria), never a workout to perform.
    // Branches by the goal's own kind since a running race, HYROX, and a
    // triathlon/Ironman each need a genuinely different protocol shape.
    private static func raceDayProtocol(event: TrainingGoal, health: HealthStore, imports: ImportStore, now: Date) -> ProposedWorkout {
        switch event.kind {
        case .triathlon, .ironman: return triathlonRaceDayProtocol(event: event, health: health, now: now)
        case .hyrox: return hyroxRaceDayProtocol(event: event, health: health, imports: imports, now: now)
        default: return runningRaceDayProtocol(event: event, health: health, now: now)
        }
    }

    private static func runningRaceDayProtocol(event: TrainingGoal, health: HealthStore, now: Date) -> ProposedWorkout {
        let running = RunningPerformanceEngine.summarize(workouts: health.workoutHistory, zones: health.runningHeartRateZones, reviews: WorkoutReviewStore.shared.reviews, now: now)
        let forecast: RaceForecast?
        switch event.kind {
        case .marathon: forecast = running.marathon
        case .halfMarathon: forecast = running.halfMarathon
        case .tenK: forecast = running.tenK
        case .fiveK: forecast = running.fiveK
        default: forecast = nil
        }
        var exercises = [ProposedExercise(name: "Calentamiento", prescription: "10–15 min muy suave + movilidad", cue: "Nada nuevo hoy: el mismo calentamiento que ya has probado en entrenamientos")]
        if let forecast, let km = event.kind.targetKilometers {
            let paceMinutesPerKm = forecast.seconds / 60 / km
            let confidenceNote = forecast.confidence == .low ? " Confianza baja: sal algo más conservador en el primer tercio." : ""
            exercises.append(ProposedExercise(
                name: "Ritmo objetivo", prescription: "\(DecisionSimulatorEngine.formatPace(paceMinutesPerKm)) min/km · objetivo ≈ \(durationText(forecast.seconds))",
                cue: "La zona cardíaca manda si el día aprieta más de lo esperado." + confidenceNote
            ))
        } else {
            exercises.append(ProposedExercise(name: "Ritmo objetivo", prescription: "Sin marca de referencia todavía", cue: "Sal conservador y ajusta por sensación, no por un ritmo inventado"))
        }
        if let nutrition = EnduranceNutritionEngine.guidance(durationMinutes: (forecast?.seconds ?? 3 * 3_600) / 60, expectedAirTemperatureCelsius: event.courseDetails?.expectedAirTemperatureCelsius) {
            exercises.append(ProposedExercise(name: "Nutrición e hidratación", prescription: EnduranceNutritionEngine.summary(nutrition), cue: nutrition.note))
        }
        exercises.append(stopCriteriaExercise())
        return ProposedWorkout(
            title: "Día de competición: \(event.title)", duration: forecast.map { durationText($0.seconds) } ?? "—",
            intent: "Ejecutar el plan, no entrenar", exercises: exercises,
            note: raceDayDisclaimer + (event.courseDetails?.courseElevationMeters.map { " El recorrido tiene \(Int($0)) m de desnivel — ajusta el ritmo en las subidas." } ?? "")
        )
    }

    private static func triathlonRaceDayProtocol(event: TrainingGoal, health: HealthStore, now: Date) -> ProposedWorkout {
        let distance = event.resolvedTriathlonDistance ?? .olympic
        let running = RunningPerformanceEngine.summarize(workouts: health.workoutHistory, zones: health.runningHeartRateZones, reviews: WorkoutReviewStore.shared.reviews, now: now)
        let forecast = TriathlonForecastEngine.forecast(distance: distance, running: running, workouts: health.workoutHistory, courseDetails: event.courseDetails, now: now)
        var exercises: [ProposedExercise] = []
        if let forecast {
            exercises.append(ProposedExercise(name: "Natación", prescription: "\(distance.swimKilometers.formatted()) km · objetivo ≈ \(durationText(forecast.swimSeconds))",
                                              cue: forecast.swimIsPersonal ? "Ritmo de tu propio historial" : "Ritmo genérico, sin historial propio todavía: no fuerces desde el primer largo"))
            let transitionCue = (event.courseDetails?.transitionNotes.isEmpty == false) ? "Tu plan: \(event.courseDetails!.transitionNotes)" : "Material en orden, sin prisa innecesaria"
            exercises.append(ProposedExercise(name: "T1 (natación → bici)", prescription: "Transición", cue: transitionCue))
            exercises.append(ProposedExercise(name: "Ciclismo", prescription: "\(distance.bikeKilometers.formatted()) km · objetivo ≈ \(durationText(forecast.bikeSeconds))",
                                              cue: forecast.bikeIsPersonal ? "Velocidad de tu propio historial" : "Velocidad genérica, sin historial propio todavía: sal conservador"))
            exercises.append(ProposedExercise(name: "T2 (bici → carrera)", prescription: "Transición", cue: "Piernas pesadas los primeros minutos: es normal, no es mal día"))
            exercises.append(ProposedExercise(name: "Carrera", prescription: "\(distance.runKilometers.formatted()) km · objetivo ≈ \(durationText(forecast.runSeconds))",
                                              cue: "Ritmo controlado — el desgaste de natación y bici ya está hecho, no lo agraves"))
            if let nutrition = EnduranceNutritionEngine.guidance(durationMinutes: forecast.seconds / 60, expectedAirTemperatureCelsius: event.courseDetails?.expectedAirTemperatureCelsius) {
                exercises.append(ProposedExercise(name: "Nutrición e hidratación", prescription: EnduranceNutritionEngine.summary(nutrition), cue: nutrition.note))
            }
        } else {
            exercises.append(ProposedExercise(name: "Sin marca de referencia", prescription: "Falta una carrera de referencia para calcular ritmos objetivo", cue: "Sal por sensación y controla el pulso"))
        }
        exercises.append(stopCriteriaExercise())
        let wetsuitNote = event.courseDetails?.wetsuitLikelyLegal.map { $0 ? " Neopreno probablemente legal por temperatura del agua." : " Neopreno probablemente NO legal por temperatura del agua." } ?? ""
        return ProposedWorkout(
            title: "Día de competición: \(event.title)", duration: forecast.map { durationText($0.seconds) } ?? "—",
            intent: "Ejecutar el plan, no entrenar", exercises: exercises,
            note: raceDayDisclaimer + wetsuitNote + (forecast?.courseCaveat.map { " " + $0 } ?? "")
        )
    }

    private static func hyroxRaceDayProtocol(event: TrainingGoal, health: HealthStore, imports: ImportStore, now: Date) -> ProposedWorkout {
        let running = RunningPerformanceEngine.summarize(workouts: health.workoutHistory, zones: health.runningHeartRateZones, reviews: WorkoutReviewStore.shared.reviews, now: now)
        let forecast = HyroxForecastEngine.forecast(running: running, workouts: imports.workouts, division: event.hyroxDivision ?? .open, now: now)
        var exercises = [ProposedExercise(name: "Calentamiento", prescription: "10–15 min progresivo + movilidad de cadera y hombro", cue: "Nada nuevo hoy")]
        if let forecast {
            exercises.append(ProposedExercise(name: "Ritmo objetivo", prescription: "≈ \(durationText(forecast.seconds)) (\(durationText(forecast.optimisticSeconds))–\(durationText(forecast.conservativeSeconds)))", cue: forecast.bottleneck))
            if let nutrition = EnduranceNutritionEngine.guidance(durationMinutes: forecast.seconds / 60) {
                exercises.append(ProposedExercise(name: "Nutrición e hidratación", prescription: EnduranceNutritionEngine.summary(nutrition), cue: nutrition.note))
            }
        } else {
            exercises.append(ProposedExercise(name: "Sin marca de referencia", prescription: "Falta una carrera de referencia para proyectar un ritmo", cue: "Sal por sensación y controla el pulso"))
        }
        exercises.append(ProposedExercise(name: "Estaciones", prescription: "Reparte el esfuerzo: no vacíes las piernas en las primeras 3", cue: "El roxzone también se entrena — camina rápido, no corras entre estaciones"))
        exercises.append(stopCriteriaExercise())
        return ProposedWorkout(
            title: "Día de competición: \(event.title)", duration: forecast.map { durationText($0.seconds) } ?? "—",
            intent: "Ejecutar el plan, no entrenar", exercises: exercises, note: raceDayDisclaimer
        )
    }

    private static func stopCriteriaExercise() -> ProposedExercise {
        ProposedExercise(name: "Señales para parar", prescription: "Dolor agudo, mareo, opresión en el pecho, confusión o síntomas de golpe de calor",
                         cue: "Terminar no vale más que tu salud — un DNF hoy no borra el trabajo de los últimos meses")
    }

    private static var raceDayDisclaimer: String {
        "Esto no es un entrenamiento: es tu protocolo de ejecución para hoy."
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func conservativeLoad(_ historicalAverage: Double, light: Bool) -> Double {
        let factor = light ? 0.85 : 0.925
        return (historicalAverage * factor / 2.5).rounded() * 2.5
    }
}
