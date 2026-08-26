import Foundation

enum PlannedSessionKind: String, Codable {
    case easyRun = "Carrera suave"
    case qualityRun = "Calidad de carrera"
    case longRun = "Tirada larga"
    case strength = "Fuerza"
    case hybrid = "Trabajo híbrido"
    case swim = "Sesión de natación"
    case bike = "Sesión de ciclismo"
    case brick = "Brick bici-carrera"
    // A real event on the calendar today used to map onto an ordinary
    // training kind (.hybrid, .brick, .qualityRun depending on the sport)
    // — the rationale said "hoy es el evento, ejecuta" but WorkoutPlanner
    // had no idea and generated an actual *workout* to perform instead of
    // a race-day execution protocol. This is its own kind specifically so
    // WorkoutPlanner can never confuse "today you compete" with "today you
    // train".
    case raceDay = "Día de competición"
    case recovery = "Recuperación"
}

// Was previously implicit in each block's display name (WorkoutPlanner and
// RunningPerformanceEngine.coverage both string-matched block.name.lowercased()
// for "base"/"afinamiento"/etc — fragile, and unavailable to anything that
// needed to know the phase without also knowing the exact Spanish wording).
// Explicit here so both volume progression and interval prescriptions below
// can key off it directly.
enum TrainingPhase { case base, buildSpecific, taper, race, transition }

struct TrainingBlock: Identifiable {
    var id: String { name }
    let name: String
    let phase: TrainingPhase
    let start: Date
    let end: Date
    let objective: String
    let runningSessions: ClosedRange<Int>
    let strengthSessions: ClosedRange<Int>
    let qualitySessions: ClosedRange<Int>
    let emphasis: [String]

    /// 0 at the start of this block, 1 at its end — how far into this phase's
    /// ramp `date` is, so a 6-week block can progress volume/intensity week
    /// to week instead of handing the same flat target on week 1 as week 6.
    func progress(on date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }
}

// A duration-driven discipline's actual weekly dose — minutes completed vs.
// a weekly target — not just a session count. "Dos bicis esta semana"
// used to read as covered even if both were 35-minute rides; a session-
// count target alone can't tell the difference. `targetLongSessionMinutes`
// is today's ceiling for a single long session in that discipline, capped
// by the athlete's own recent tolerance (see progressedCeiling below) —
// `isPersonalizedProgression` says whether real history grounded that cap
// or it's still the honest phase-table default for lack of evidence.
struct DisciplineDose {
    let targetMinutes: Double
    let completedMinutes: Double
    let targetLongSessionMinutes: Double
    let isPersonalizedProgression: Bool
    var deficitMinutes: Double { max(0, targetMinutes - completedMinutes) }
}

struct WeeklyPlanStatus {
    let block: TrainingBlock
    let completedRuns: Int
    let completedStrength: Int
    let completedQuality: Int
    // A triathlon/Ironman goal gets its own weekly budget for the two
    // disciplines nothing else in the plan builds — "hace muchos días que
    // no nadas" alone isn't a dose, it's just a trigger; these are the
    // actual weekly targets that trigger compares against.
    let completedSwim: Int
    let completedBike: Int
    let targetRuns: Int
    let targetStrength: Int
    let targetQuality: Int
    let targetSwim: Int
    let targetBike: Int
    // Real weekly dose (minutes), not just session counts — see
    // DisciplineDose above.
    let swimDose: DisciplineDose
    let bikeDose: DisciplineDose
    let runDose: DisciplineDose
    let brickDose: DisciplineDose
    let nextSession: PlannedSessionKind
    let recommendation: String
    let rationale: String
    let daysToEvent: Int?
    let eventName: String?
    let isDeload: Bool
    let volumeFactor: Double
    // Set from the exact same condition that routes `next` into the
    // "already did something today" branch below — so the UI (the day
    // chip's icon/label) can show "ya entrenado hoy" whenever ANY real
    // session happened today, not only the specific "tren superior, sin
    // piernas" case whose own rationale text used to be the only signal
    // available, via a brittle string match on that one Spanish phrase.
    // A HIIT/cardio HealthKit session, or any other kind of session that
    // routes into the same "asimilar la carga" fallback, used to read as
    // an ordinary, unaccounted-for rest day instead.
    let alreadyTrainedToday: Bool
}

struct DeloadAdjustment: Equatable {
    let runningSessions: Int
    let strengthSessions: Int
    let qualitySessions: Int
    let volumeFactor: Double
}

struct GoalTrainingFocus {
    let running: Double
    let strength: Double
    let hybrid: Double
    // A triathlon/Ironman goal's swim and bike legs are genuinely distinct
    // disciplines — not shared with running/strength the way HYROX's
    // stations are — so they get their own weight bucket instead of riding
    // on `hybrid`, which would blend two goals with very different
    // physical demands into one number. `var` with a default (not `let`):
    // Swift's synthesized memberwise init only exposes a defaulted
    // parameter for a property declared this way, so existing call sites
    // (tests included) that predate this field keep compiling at 0 while
    // goalFocus(for:) below still overrides it explicitly.
    var triathlon: Double = 0
    let leadingGoal: String
}

@MainActor
enum TrainingPlanEngine {
    // The exact goal blocks(for:) periodizes around — same selection (primary
    // events preferred, earliest first). Anything that needs to know the
    // goal's own kind/distance (WorkoutPlanner scaling long-run volume by
    // race distance) asks here instead of re-deriving the selection itself.
    static func primaryEvents(for profile: AthletePlanProfile) -> [TrainingGoal] {
        let datedEvents = profile.goals.filter { $0.isActive && $0.date != nil }
        let primaryEvents = datedEvents.filter { $0.priority == .primary }
        return (primaryEvents.isEmpty ? datedEvents : primaryEvents).sorted { $0.date! < $1.date! }
    }

    static func blocks(for profile: AthletePlanProfile) -> [TrainingBlock] {
        let calendar = Calendar.current
        let events = primaryEvents(for: profile)
        guard let first = events.first, let firstDate = first.date else { return [generalBlock(on: Date(), profile: profile)] }
        func shifted(_ days: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
        func block(_ name: String, _ phase: TrainingPhase, _ start: Date, _ end: Date, _ objective: String,
                   _ runs: ClosedRange<Int>, _ strength: ClosedRange<Int>, _ quality: ClosedRange<Int>, _ emphasis: [String]) -> TrainingBlock {
            TrainingBlock(name: name, phase: phase, start: calendar.startOfDay(for: start), end: calendar.startOfDay(for: end), objective: objective,
                          runningSessions: runs, strengthSessions: strength, qualitySessions: quality, emphasis: emphasis)
        }
        var result: [TrainingBlock] = [
            block("Base para \(first.title)", .base, shifted(-84, from: firstDate), shifted(-43, from: firstDate),
                  "Construir tolerancia y consistencia para \(first.title.lowercased()) sin abandonar las capacidades de mantenimiento.", 3...5, 1...3, 1...2,
                  ["Volumen fácil", "Técnica", profile.gymAvailable ? "Fuerza estructurada" : "Fuerza sin gimnasio"]),
            block("Construcción específica", .buildSpecific, shifted(-42, from: firstDate), shifted(-14, from: firstDate),
                  "Acercar el entrenamiento a las demandas de \(first.title.lowercased()) con carga todavía progresiva.", 4...5, 2...3, 1...2,
                  buildSpecificEmphasis(for: first.kind)),
            block("Afinamiento · \(first.title)", .taper, shifted(-13, from: firstDate), shifted(-1, from: firstDate),
                  "Reducir fatiga conservando los estímulos específicos antes del reto.", 3...4, 1...2, 1...1, ["Menos volumen", "Toques específicos", "Nada al fallo"]),
            block(first.title, .race, firstDate, firstDate, "Llegar fresco y ejecutar el reto previsto.", 1...1,
                  first.kind == .hyrox ? 1...1 : 0...0, 1...1, ["Competición", "Pacing", "Nutrición e hidratación"])
        ]
        for event in events.dropFirst() {
            guard let date = event.date else { continue }
            let previousDate = result.last?.end ?? firstDate
            result.append(block("Transición a \(event.title)", .transition, shifted(1, from: previousDate), shifted(-6, from: date),
                                "Recuperar del reto anterior y transferir la preparación hacia \(event.title.lowercased()).", 2...4, 2...3, 0...1,
                                transitionEmphasis(for: event.kind)))
            result.append(block("Afinamiento · \(event.title)", .taper, shifted(-5, from: date), shifted(-1, from: date),
                                "Llegar fresco manteniendo coordinación y confianza específicas.", 1...2, 1...2, 0...1, ["Sesiones cortas", "Técnica", "Nada al fallo"]))
            result.append(block(event.title, .race, date, date, "Competir y ejecutar el plan previsto.", 1...1,
                                event.kind == .hyrox ? 1...1 : 0...0, 1...1, ["Competición", "Pacing", "Ejecución"]))
        }
        return result.filter { $0.start <= $0.end }
    }

    private static func buildSpecificEmphasis(for kind: TrainingGoalKind) -> [String] {
        switch kind {
        case .hyrox: return ["Carrera bajo fatiga", "Estaciones", "Fuerza funcional"]
        case .triathlon, .ironman: return ["Series en bici y natación", "Brick bici-carrera", "Nutrición e hidratación de carrera"]
        default: return ["Umbral controlado", "Tirada larga", "Fuerza con margen"]
        }
    }

    private static func transitionEmphasis(for kind: TrainingGoalKind) -> [String] {
        switch kind {
        case .hyrox: return ["Recuperación inicial", "Estaciones", "Carrera bajo fatiga"]
        case .triathlon, .ironman: return ["Recuperación inicial", "Base de natación y bici", "Brick progresivo"]
        default: return ["Recuperación", "Especificidad", "Carga gradual"]
        }
    }

    // A missing history is treated as an overdue maintenance stimulus rather
    // than as proof that strength is unnecessary. Extracted out of status()
    // (rather than left as a local) so weekAhead() below can seed its own
    // forward simulation from the exact same real number status() itself
    // uses today, instead of a second, silently-diverging computation.
    static func daysSinceStrength(health: HealthStore, imports: ImportStore, now: Date) -> Double {
        let importedStrengthDates = imports.workouts.filter { $0.end <= now }.map(\.end)
        let healthStrengthDates = health.recentWorkouts.filter {
            $0.date <= now && isStrengthWorkout($0) &&
            !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }.map { $0.date.addingTimeInterval($0.durationMinutes * 60) }
        let lastStrengthDate = (importedStrengthDates + healthStrengthDates).max()
        return lastStrengthDate.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 14
    }

    // Same "overdue, not absent" treatment for the other two triathlon
    // disciplines — nothing else in the plan builds swim/bike fitness, so a
    // missing history must read as neglected, not as unnecessary.
    // The most overdue of any named, tracked lift (bench press, sentadilla)
    // an active goal cares about — see the longer explanation on
    // balancedDecision's own trackedLiftDaysSince parameter. nil when no
    // such goal is active, so this never invents urgency for a lift
    // nobody is tracking.
    static func trackedLiftDaysSince(imports: ImportStore, profile: AthletePlanProfile, now: Date) -> Double? {
        let goals = profile.goals.filter(\.isActive)
        var values: [Double] = []
        if goals.contains(where: { $0.kind == .benchPress }) {
            // "(barbell)" matters: bare "bench press" also matches Incline/
            // Dumbbell variations that aren't the tracked flat-barbell lift.
            values.append(StrengthProgressEngine.daysSinceLastSession(matchingTerms: ["bench press (barbell)", "press banca"], in: imports.workouts, now: now) ?? 999)
        }
        if goals.contains(where: { $0.kind == .squat }) {
            values.append(StrengthProgressEngine.daysSinceLastSession(matchingTerms: ["squat (barbell)", "sentadilla"], in: imports.workouts, now: now) ?? 999)
        }
        if goals.contains(where: { $0.kind == .deadlift }) {
            values.append(StrengthProgressEngine.daysSinceLastSession(matchingTerms: ["deadlift (barbell)", "peso muerto"], in: imports.workouts, now: now) ?? 999)
        }
        return values.max()
    }

    static func daysSince(_ activity: String, health: HealthStore, imports: ImportStore, now: Date) -> Double {
        let dates = health.recentWorkouts.filter {
            $0.date <= now && $0.activity == activity &&
            !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }.map { $0.date.addingTimeInterval($0.durationMinutes * 60) }
        return dates.max().map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 14
    }

    // Hours since the most recent COMPLETED session (within the last 10
    // days) matching `predicate` — the same window/completion rule status()
    // already applied inline for long-run/quality-run spacing.
    static func hoursSinceLastCompleted(matching predicate: (HealthWorkout) -> Bool,
                                        health: HealthStore, imports: ImportStore, now: Date) -> Double? {
        let calendar = Calendar.current
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now) ?? now
        let recentHealth = health.recentWorkouts.filter {
            $0.date >= tenDaysAgo && $0.date <= now && !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }
        let completedRecent = recentHealth.filter { $0.date.addingTimeInterval($0.durationMinutes * 60) <= now }
        guard let last = completedRecent.filter(predicate).max(by: { $0.date < $1.date }) else { return nil }
        return now.timeIntervalSince(last.date.addingTimeInterval(last.durationMinutes * 60)) / 3600
    }

    // Sum of real minutes logged for `activity` in the last `windowDays` —
    // the actual dose, not how many sessions happened to occur.
    static func weeklyMinutes(_ activity: String, health: HealthStore, imports: ImportStore, now: Date, windowDays: Double = 7) -> Double {
        let cutoff = now.addingTimeInterval(-windowDays * 86_400)
        return health.recentWorkouts.filter {
            $0.date >= cutoff && $0.date <= now && $0.activity == activity &&
            !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }.reduce(0) { $0 + $1.durationMinutes }
    }

    // This person's own recent typical weekly volume for `activity` — the
    // mean of the last 3 completed 7-day windows, same "three prior weeks"
    // pattern RunningPerformanceEngine.coverage already uses for its own
    // running-km baseline. nil when there's no real week to anchor on yet.
    static func recentWeeklyMinutesBaseline(_ activity: String, health: HealthStore, imports: ImportStore, now: Date) -> Double? {
        let calendar = Calendar.current
        let priors = (1...3).compactMap { index -> Double? in
            guard let end = calendar.date(byAdding: .day, value: -7 * index, to: now),
                  let start = calendar.date(byAdding: .day, value: -7, to: end) else { return nil }
            let minutes = health.recentWorkouts.filter {
                $0.activity == activity && $0.date >= start && $0.date < end &&
                !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
            }.reduce(0) { $0 + $1.durationMinutes }
            return minutes > 0 ? minutes : nil
        }
        guard !priors.isEmpty else { return nil }
        return priors.reduce(0, +) / Double(priors.count)
    }

    // This person's own longest single session of `activity` in the last
    // `lookbackDays` — current duration tolerance, not an all-time best
    // that could be months stale.
    nonisolated static func recentLongestSessionMinutes(_ workouts: [HealthWorkout], activity: String, now: Date, lookbackDays: Double = 21) -> Double? {
        let cutoff = now.addingTimeInterval(-lookbackDays * 86_400)
        let matches = workouts.filter { $0.activity == activity && $0.date >= cutoff && $0.date <= now }
        return matches.map(\.durationMinutes).max()
    }

    // The actual fix for "progresión máxima semanal basada en tu propio
    // historial, no en una tabla fija": a phase table sets the *ambition*
    // (`phaseCeiling`) but this never lets that override reality — it only
    // ever pulls the ceiling DOWN toward what `recent` (a longest session or
    // a recent weekly total, same math either way) plus a safe week-over-
    // week increase actually supports, the same "don't jump more than
    // ~15%" principle behind the classic 10% rule and this app's own
    // Gabbett-ACWR load guidance elsewhere. With no real history to ground
    // it, it falls back to the phase ceiling honestly — flagged as not
    // personalized, never invented.
    nonisolated static func progressedCeiling(recent: Double?, phaseCeiling: Double, weeklyGrowthCap: Double = 0.15) -> (minutes: Double, isPersonalized: Bool) {
        guard let recent, recent > 0 else { return (phaseCeiling, false) }
        return (min(phaseCeiling, recent * (1 + weeklyGrowthCap)), true)
    }

    // Same reasoning as progressedCeiling above, applied to daily steps:
    // 10,000 is a reasonable general upper reference (step-mortality
    // literature shows real gains up to roughly that range, then
    // diminishing returns), but handing everyone that exact number as
    // "the" target ignores where they actually start. Someone averaging
    // 3,000/day gets an unreachable-feeling goal; someone averaging
    // 12,000/day gets a number they've already beaten. This grounds
    // TODAY's target in this person's own recent habitual average
    // (excluding today itself, which is still incomplete) and lets it
    // ratchet up ~15%/step toward the reference ceiling — never above
    // it, since there's no personal upside claimed past that point.
    // With no real history, it falls back to the flat reference honestly.
    // What the Watch app should do with today's session — it only knows
    // three behaviors (passive "log it with Apple Workout" guidance for
    // running-like sessions, passive "rest today" for recovery, and an
    // active button that starts a *strength* HealthKit session for
    // anything else). This used to be reconstructed on the phone side by
    // lowercasing and substring-matching the rendered Spanish
    // recommendation text, which had two real failure modes: any session
    // whose title didn't contain "carrera"/"tirada"/"recuper..." (swim,
    // bike, hybrid, HYROX, race day) silently fell through to the
    // strength default — meaning tapping the Watch button would start and
    // log a `.traditionalStrengthTraining` HealthKit session for a bike
    // ride — and "Brick bici-carrera" contains "carrera" as a substring,
    // so it would have been misread as a run. Driving this off the
    // session's own structured kind instead removes both failure modes.
    nonisolated static func watchActivity(for kind: PlannedSessionKind) -> String {
        switch kind {
        case .easyRun, .qualityRun, .longRun: return "running"
        case .recovery: return "recovery"
        case .strength: return "strength"
        case .hybrid, .swim, .bike, .brick, .raceDay: return "cardio"
        }
    }

    nonisolated static func personalizedStepTarget(stepsHistory: [TrendPoint], now: Date, referenceCeiling: Double = 10_000) -> (target: Int, isPersonalized: Bool) {
        let calendar = Calendar.current
        let priorDays = stepsHistory.filter { !calendar.isDate($0.date, inSameDayAs: now) }.suffix(14).map(\.value)
        guard priorDays.count >= 5 else { return (Int(referenceCeiling), false) }
        let recentAverage = priorDays.reduce(0, +) / Double(priorDays.count)
        let (ceiling, isPersonalized) = progressedCeiling(recent: recentAverage, phaseCeiling: referenceCeiling)
        return (Int(ceiling.rounded()), isPersonalized)
    }

    // Weekly minutes ceiling by phase — the periodization's idea of how
    // much weekly volume this discipline should carry, expressed as a
    // dose (minutes) instead of a session count. A structural estimate,
    // same treatment the session-count targets above already got.
    private static func weeklyDoseCeiling(for phase: TrainingPhase, base: Double, build: Double, taper: Double, transition: Double, race: Double) -> Double {
        switch phase {
        case .base: return base
        case .buildSpecific: return build
        case .taper: return taper
        case .transition: return transition
        case .race: return race
        }
    }

    // Builds one discipline's full weekly dose: real completed minutes,
    // the phase-implied weekly ceiling scaled by how much this goal
    // actually needs it, personally capped by this person's own recent
    // weekly volume, and — for disciplines where a single long session
    // matters (swim/bike) — a personalized long-session ceiling too.
    private static func disciplineDose(activity: String, health: HealthStore, imports: ImportStore, now: Date,
                                       phase: TrainingPhase, demand: Double,
                                       base: Double, build: Double, taper: Double, transition: Double, race: Double,
                                       longSessionPhaseCeiling: Double, weeklyGrowthCap: Double) -> DisciplineDose {
        let completed = weeklyMinutes(activity, health: health, imports: imports, now: now)
        // 0 demand -> 0 dose (no goal asking for this discipline at all);
        // 0.5 demand (a genuinely invested goal) -> the full table value;
        // capped at 1.6x for a near-single-focus portfolio.
        let structuralCeiling = weeklyDoseCeiling(for: phase, base: base, build: build, taper: taper, transition: transition, race: race) * min(1.6, max(0, demand / 0.5))
        let weeklyBaseline = recentWeeklyMinutesBaseline(activity, health: health, imports: imports, now: now)
        let (target, _) = progressedCeiling(recent: weeklyBaseline, phaseCeiling: structuralCeiling, weeklyGrowthCap: weeklyGrowthCap)
        let longestRecent = recentLongestSessionMinutes(health.workoutHistory, activity: activity, now: now)
        let (longSession, isPersonalized) = progressedCeiling(recent: longestRecent, phaseCeiling: longSessionPhaseCeiling, weeklyGrowthCap: weeklyGrowthCap)
        return DisciplineDose(targetMinutes: target, completedMinutes: completed,
                              targetLongSessionMinutes: longSession, isPersonalizedProgression: isPersonalized)
    }

    // TwinCore: profile/reviews used to be read straight from the GoalStore/
    // WorkoutReviewStore singleton instances throughout this function — both required
    // params now, no default, same reasoning as TwinEngine.assess.
    //
    // readiness/muscles here are a PR2 compatibility shape, not the final
    // target — see TwinPhysiology's own comment. readiness IS
    // TwinReadout.score and muscles' fatigue numbers ARE
    // TwinPhysiology.muscleFatigue (same single source, TwinEngine.
    // calculateMuscles), just not yet passed as those named types: muscles
    // also carries recentSets/lastTrained (for bestStrengthPattern's real
    // MEV/MAV/MRV logic, via balancedDecision below) that TwinPhysiology
    // deliberately does not carry. Migrating this call site to take
    // TwinPhysiology + TwinReadout + a separate MuscleTrainingContext
    // (never merging volume/history into TwinPhysiology) is future work,
    // not done here to avoid losing that fidelity mid-PR.
    static func status(health: HealthStore, imports: ImportStore, readiness: Int, muscles: [MuscleReadiness], checkIn: DailyCheckIn?,
                       context: TwinContext,
                       physiologicalAlert: PhysiologicalAlert? = nil, now: Date = Date()) -> WeeklyPlanStatus {
        let profile = context.profile, reviews = context.reviews
        let calendar = Calendar.current
        let block = activeBlock(on: now, profile: profile)
        // Same pattern WorkoutPlanner already uses to read real recent
        // intensity distribution without threading it through every
        // caller's parameter list. Without real zone data, hardPercentage
        // defaults to 100 (easy% of an empty zone map is 0) — that's a
        // "no data" artifact, not a real polarization problem, so it must
        // never reach the gate as if it were a measured value.
        let runningSummaryForIntensity = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory, zones: health.runningHeartRateZones,
            reviews: reviews, now: now
        )
        let recentHardPercentage = runningSummaryForIntensity.hasZoneData ? runningSummaryForIntensity.hardPercentage : nil
        // A rolling microcycle avoids the artificial reset produced by Monday.
        let windowStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let importedStrength = imports.workouts.filter { $0.start >= windowStart && $0.start <= now }
        let healthWorkouts = health.recentWorkouts.filter {
            $0.date >= windowStart && $0.date <= now && !$0.source.localizedCaseInsensitiveContains("hevy") && !imports.isHealthKitMirror($0)
        }
        let healthStrength = healthWorkouts.filter { isStrengthWorkout($0) }
        let strength = importedStrength.count + healthStrength.count
        let runs = healthWorkouts.filter { $0.activity == "Carrera" }
        let quality = runs.filter { isQualityRun($0) }.count
        let completedSwim = healthWorkouts.filter { $0.activity == "Natación" }.count
        let completedBike = healthWorkouts.filter { $0.activity == "Ciclismo" }.count
        let day = calendar.component(.weekday, from: now)
        let preferredLongRunDay = profile.preferredLongRunWeekday
        let lateWeek = day == preferredLongRunDay || day == 1 || day == 7
        let sessionsToday = healthWorkouts.filter { calendar.isDate($0.date, inSameDayAs: now) && $0.date.addingTimeInterval($0.durationMinutes * 60) <= now }
        // "Already trained today" used to mean *any* completed session at
        // all — a 10×100 m technique swim (real, but genuinely light)
        // tripped the exact same full-stop as a hard session. Same
        // threshold (20) meaningfulTrainingDays72h already uses to tell a
        // real stimulus apart from a short walk or an easy Z1 recovery
        // ride, applied here so a token session doesn't block the rest of
        // the day's plan either.
        let meaningfulSessionsToday = sessionsToday.filter { $0.durationMinutes * PerformanceEngine.cardioFactor($0.activity) >= 20 }
        let runToday = sessionsToday.filter { $0.activity == "Carrera" }.max { $0.date < $1.date }
        // healthWorkouts above deliberately excludes anything Hevy-sourced or
        // Hevy-mirrored (so a session HealthKit also mirrors isn't counted
        // twice) — but that also made a real, decent-volume session logged
        // ONLY in Hevy today (a push day, say) completely invisible to
        // "already trained today": the plan kept proposing a fresh hard
        // session (a long run) as if today were still a blank slate.
        let importedSessionsToday = imports.workouts.filter { calendar.isDate($0.start, inSameDayAs: now) && $0.end <= now }
        let meaningfulImportedSessionToday = importedSessionsToday.filter {
            ($0.end.timeIntervalSince($0.start) / 60) * PerformanceEngine.cardioFactor("Fuerza") >= 20
        }.max { $0.start < $1.start }
        // Hevy's own exercise-level muscleSets is precise enough to tell a
        // push/pull day (no leg involvement) from a leg day — a HealthKit-
        // only strength session can't make that distinction (Watch data
        // doesn't carry it), so it's treated conservatively as leg-involving.
        let legMuscleNames: Set<String> = ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"]
        let strengthTodayInvolvedLegs = meaningfulImportedSessionToday.map { session in
            session.effectiveMuscleSets.contains { legMuscleNames.contains($0.key) && $0.value > 0 }
        } ?? true
        let hoursSinceLong = hoursSinceLastCompleted(matching: isLongRun, health: health, imports: imports, now: now)
        let hoursSinceQuality = hoursSinceLastCompleted(matching: { $0.activity == "Carrera" && isQualityRun($0) }, health: health, imports: imports, now: now)
        let hoursSinceLongSwim = hoursSinceLastCompleted(matching: isLongSwim, health: health, imports: imports, now: now)
        let hoursSinceLongBike = hoursSinceLastCompleted(matching: isLongBike, health: health, imports: imports, now: now)
        let daysSinceStrength = daysSinceStrength(health: health, imports: imports, now: now)
        let daysSinceSwim = daysSince("Natación", health: health, imports: imports, now: now)
        let daysSinceBike = daysSince("Ciclismo", health: health, imports: imports, now: now)
        let trackedLiftDaysSince = trackedLiftDaysSince(imports: imports, profile: profile, now: now)

        let availableSessions = profile.trainingDaysPerWeek
        let goalFocus = goalFocus(for: profile, on: now)
        // Session allocation follows the user's complete goal portfolio. Hybrid
        // demand is partly fulfilled by both running and strength, leaving room
        // for a genuinely combined session when it becomes specific. Triathlon
        // demand contributes more lightly to both — its own swim/bike sessions
        // are counted and prioritized separately in balancedDecision below,
        // not folded into the running/strength targets the way hybrid is.
        let runningDemand = goalFocus.running + goalFocus.hybrid * 0.35 + goalFocus.triathlon * 0.25
        let strengthDemand = goalFocus.strength + goalFocus.hybrid * 0.35 + goalFocus.triathlon * 0.15
        var targetRuns = min(availableSessions, Int((Double(availableSessions) * runningDemand).rounded()))
        var targetStrength = min(availableSessions, Int((Double(availableSessions) * strengthDemand).rounded()))
        // Captured before any floor/fairness trimming below — targetQuality's
        // own gate further down uses this, not the final trimmed targetRuns.
        // A real capacity conflict (e.g. two tracked lifts both needing
        // their own floor) can fairly trim targetRuns down to 1-2 for THIS
        // week's count/scoring purposes without that meaning running was
        // never a real, substantial part of the plan — using the trimmed
        // value here silently zeroed targetQuality (and permanently blocked
        // quality-run from ever being proposed, no matter how overdue)
        // purely because of an unrelated strength-side squeeze.
        let runningIsSubstantialPartOfThePlan = targetRuns >= 3
        if runningDemand >= 0.10 { targetRuns = max(1, targetRuns) }
        if strengthDemand >= 0.10 { targetStrength = max(1, targetStrength) }
        while targetRuns + targetStrength > availableSessions {
            if runningDemand >= strengthDemand, targetStrength > 1 { targetStrength -= 1 }
            else if targetRuns > 1 { targetRuns -= 1 }
            else { break }
        }
        // A specifically tracked lift (bench press, sentadilla) has its own
        // minimum effective dose independent of how it blends into the
        // portfolio-wide strength demand above — the blended count is what
        // let two lifts quietly share a single weekly slot. Dosing follows
        // real frequency/retention literature, not a blended average:
        // Bickel, Cross & Bamman (2011) found reduced-volume, preserved-
        // intensity training as infrequent as 1x/week retains a strength
        // adaptation already achieved for weeks to months — the honest
        // floor for a goal explicitly tagged "Mantenimiento". Ralston et
        // al. (2017), a frequency meta-analysis, found 2x/week per lift
        // outperforms 1x/week for continued 1RM gains at matched volume —
        // the floor once that same lift is actually being progressed
        // (Principal/Secundario), not just held.
        var trackedLiftMinimumSessions = profile.goals
            .filter { $0.isActive && ($0.kind == .benchPress || $0.kind == .squat || $0.kind == .deadlift) }
            .reduce(0) { $0 + ($1.priority == .maintenance ? 1 : 2) }
        // Hypertrophy isn't a tracked lift (no single number to protect),
        // but it has its own real minimum: Schoenfeld et al.'s 2016
        // frequency meta-analysis found 2x/week per muscle group builds
        // more size than 1x/week at matched volume — a floor, not summed
        // with the tracked-lift one above, since a well-built 2x/week
        // full-body split already covers hypertrophy volume in the same
        // sessions that maintain/progress bench and squat, unlike two
        // distinct lifts which genuinely need their own separate attention.
        if profile.goals.contains(where: { $0.isActive && $0.kind == .hypertrophy }) {
            trackedLiftMinimumSessions = max(trackedLiftMinimumSessions, 2)
        }
        // Running has the exact same kind of floor problem, just less
        // visible: three concurrent running-type goals (half marathon,
        // 5K, HYROX's run share) blend into one demand number the same
        // way two lifts did, and a low-availability week can round that
        // blend down to nothing once the strength floor above claims room
        // first. Pfitzinger/Daniels-style plans agree a runner needs at
        // least ~3 sessions/week for either endurance or speed to actually
        // move — below that, frequency itself is the limiter, not which
        // specific race it's for. Running goals share aerobic base and
        // easy volume (unlike two independent lifts), so this doesn't
        // scale with how many are active — one active running-type goal
        // already needs the same 3, not 3 more per extra goal.
        let hasRunningGoal = profile.goals.contains {
            $0.isActive && [.marathon, .halfMarathon, .fiveK, .tenK, .hyrox].contains($0.kind)
        }
        let runningMinimumSessions = hasRunningGoal ? min(availableSessions, 3) : 0
        if trackedLiftMinimumSessions > targetStrength { targetStrength = min(availableSessions, trackedLiftMinimumSessions) }
        if runningMinimumSessions > targetRuns { targetRuns = runningMinimumSessions }
        // When both floors together still don't fit, the shortfall is
        // trimmed in round-robin fashion — one session off whichever side
        // is currently larger — instead of one side (previously always
        // running) absorbing the entire deficit down to a bare floor of 1.
        // That one-sided version was the actual mechanism behind a real
        // week collapsing to all-strength/zero-running once two tracked
        // lifts both moved to a 2x/week "progressing" floor: it silently
        // sacrificed running's own genuine, larger demand to make room.
        while targetRuns + targetStrength > availableSessions, targetRuns > 1 || targetStrength > 1 {
            if targetRuns >= targetStrength, targetRuns > 1 { targetRuns -= 1 }
            else if targetStrength > 1 { targetStrength -= 1 }
            else if targetRuns > 1 { targetRuns -= 1 }
            else { break }
        }
        // Explicit weekly swim/bike budget instead of only "how many days
        // since your last one" — the latter is a trigger for urgency, not a
        // dose. Bike gets slightly more weight than swim (45/55): Ironman-
        // distance training is dominated by bike volume, while swim needs
        // frequency for technique more than raw weekly count. Only the
        // slots running/strength didn't already claim are available, so
        // this never quietly exceeds the athlete's actual weekly capacity.
        var targetSwim = 0
        var targetBike = 0
        if goalFocus.triathlon >= 0.12 {
            let remaining = max(0, availableSessions - targetRuns - targetStrength)
            let swimDemand = goalFocus.triathlon * 0.45
            let bikeDemand = goalFocus.triathlon * 0.55
            targetSwim = min(remaining, max(1, Int((Double(availableSessions) * swimDemand).rounded())))
            targetBike = min(max(0, remaining - targetSwim), max(1, Int((Double(availableSessions) * bikeDemand).rounded())))
        }
        var targetQuality = runningIsSubstantialPartOfThePlan && goalFocus.running >= 0.35 ? midpoint(block.qualitySessions) : 0
        let loadSummary = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        // A competition day is execution, not a deload session, even if the
        // preceding taper has reduced chronic volume.
        let isDeload = loadSummary.loadGuidance == .deload && eventToday(now, profile: profile) == nil
        let adjustedTargets = deloadAdjustment(
            runningSessions: targetRuns, strengthSessions: targetStrength,
            qualitySessions: targetQuality, enabled: isDeload
        )
        targetRuns = adjustedTargets.runningSessions
        targetStrength = adjustedTargets.strengthSessions
        targetQuality = adjustedTargets.qualitySessions
        // Same lateWeek rule as `day` above, one day ahead — what
        // legSensitiveRunLikelyTomorrow actually needs to know.
        let tomorrowWeekday = calendar.component(.weekday, from: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let tomorrowLateWeek = tomorrowWeekday == preferredLongRunDay || tomorrowWeekday == 1 || tomorrowWeekday == 7
        let avoidLegsTomorrow = legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: hoursSinceQuality, hoursSinceLong: hoursSinceLong,
            tomorrowIsLateWeek: tomorrowLateWeek, qualityDeficit: max(0, targetQuality - quality),
            goalFocus: goalFocus
        )
        // Same ~30% reduction deloadAdjustment already applies to running/
        // strength, mirrored here rather than folded into that shared
        // function so its own existing tests (fixed field names, no swim/
        // bike) stay untouched.
        if isDeload {
            targetSwim = targetSwim > 0 ? max(1, Int((Double(targetSwim) * 0.70).rounded())) : 0
            targetBike = targetBike > 0 ? max(1, Int((Double(targetBike) * 0.70).rounded())) : 0
        }
        // Real weekly dose (minutes) per discipline — see DisciplineDose.
        // Ceilings mirror WorkoutPlanner's own per-session bands (swimBand/
        // bikeBand/longRunBand max values) so the two systems never quietly
        // disagree about what "a lot" means for the same phase. Deload
        // shrinks the target the same ~30% running/strength/swim/bike
        // session counts already get above.
        let deloadFactor = isDeload ? 0.70 : 1.0
        var swimDose = disciplineDose(activity: "Natación", health: health, imports: imports, now: now, phase: block.phase,
                                      demand: goalFocus.triathlon, base: 60, build: 100, taper: 45, transition: 60, race: 20,
                                      longSessionPhaseCeiling: weeklyDoseCeiling(for: block.phase, base: 35, build: 50, taper: 25, transition: 30, race: 15),
                                      weeklyGrowthCap: profile.effectiveProgressionPace.weeklyGrowthRate)
        var bikeDose = disciplineDose(activity: "Ciclismo", health: health, imports: imports, now: now, phase: block.phase,
                                      demand: goalFocus.triathlon, base: 90, build: 180, taper: 70, transition: 90, race: 30,
                                      longSessionPhaseCeiling: weeklyDoseCeiling(for: block.phase, base: 70, build: 110, taper: 50, transition: 60, race: 30),
                                      weeklyGrowthCap: profile.effectiveProgressionPace.weeklyGrowthRate)
        // Distance-scaling the run dose the way WorkoutPlanner's own
        // longRunBand does (marathon vs. half vs. 5K) would need the same
        // targetKilometers resolution WorkoutPlanner computes locally —
        // duplicating it here isn't worth it for what's a secondary,
        // decision-weighting signal rather than the actual prescription
        // (which WorkoutPlanner still gets right, distance-scaled).
        let runDose = disciplineDose(activity: "Carrera", health: health, imports: imports, now: now, phase: block.phase,
                                     demand: goalFocus.running, base: 120, build: 220, taper: 90, transition: 120, race: 40,
                                     longSessionPhaseCeiling: weeklyDoseCeiling(for: block.phase, base: 55, build: 80, taper: 40, transition: 50, race: 20),
                                     weeklyGrowthCap: profile.effectiveProgressionPace.weeklyGrowthRate)
        if isDeload {
            swimDose = DisciplineDose(targetMinutes: swimDose.targetMinutes * deloadFactor, completedMinutes: swimDose.completedMinutes,
                                      targetLongSessionMinutes: swimDose.targetLongSessionMinutes, isPersonalizedProgression: swimDose.isPersonalizedProgression)
            bikeDose = DisciplineDose(targetMinutes: bikeDose.targetMinutes * deloadFactor, completedMinutes: bikeDose.completedMinutes,
                                      targetLongSessionMinutes: bikeDose.targetLongSessionMinutes, isPersonalizedProgression: bikeDose.isPersonalizedProgression)
        }
        // Brick has no single HealthKit activity of its own — its dose is
        // the paired bike+run minutes TriathlonForecastEngine already
        // detects for the forecast's brick-evidence count, just windowed
        // to this week instead of the last 120 days. No personal-history
        // cap: there's no single matching activity to measure "recent
        // longest brick" against, so this stays an honest structural
        // estimate rather than a half-personalized one.
        let brickCompletedMinutes = TriathlonForecastEngine.brickMinutes(health.workoutHistory, now: now, lookbackDays: 7)
        let brickTargetMinutes = weeklyDoseCeiling(for: block.phase, base: 0, build: 45, taper: 30, transition: 0, race: 0)
            * min(1.6, max(0, goalFocus.triathlon / 0.5)) * (isDeload ? deloadFactor : 1.0)
        let brickDose = DisciplineDose(
            targetMinutes: brickTargetMinutes, completedMinutes: brickCompletedMinutes,
            targetLongSessionMinutes: weeklyDoseCeiling(for: block.phase, base: 55, build: 70, taper: 50, transition: 55, race: 40),
            isPersonalizedProgression: false
        )
        var next: PlannedSessionKind
        var rationale: String

        // PhysiologicalAlertEngine looks for concordant HRV/pulso/sueño
        // deviation against this person's own baseline — a genuinely
        // different, more sensitive signal than the readiness score below
        // (different math, different thresholds), so a "prioriza
        // recuperación" alert could previously exist on screen at the same
        // time WorkoutPlanner still proposed a demanding session, since the
        // alert was never actually wired into this decision. It now sits at
        // the same hard-override tier as illness/very-low readiness.
        if checkIn?.illness == true || readiness < 42 || physiologicalAlert?.severity == .recover {
            next = .recovery; rationale = "Tus señales actuales tienen prioridad sobre el calendario."
        } else if let event = eventToday(now, profile: profile) {
            // Not a training kind of any sport — a real event today needs
            // a race-day execution protocol (pacing, nutrition, transition,
            // stop criteria), never a workout to perform. WorkoutPlanner
            // branches on this exact kind to build that protocol.
            next = .raceDay
            rationale = "Hoy es \(event.title): el objetivo es ejecutar, no añadir otro entrenamiento."
        } else if let runToday {
            let distance = runToday.distanceKilometers ?? 0
            if distance >= 10 || runToday.durationMinutes >= 60 {
                next = .recovery
                rationale = String(format: "Ya has completado hoy una carrera relevante de %.1f km y %.0f min. Ahora toca asimilarla; no añadir otra sesión de carrera.", distance, runToday.durationMinutes)
            } else if strength < targetStrength && readiness >= 68 {
                next = .strength
                rationale = "La carrera de hoy ya cubre el estímulo aeróbico. Si quieres una segunda sesión, solo fuerza de tren superior con margen."
            } else {
                next = .recovery
                rationale = "La carrera de hoy ya cuenta como la sesión del día. Recuperar ahora protege la siguiente sesión clave."
            }
        } else if !meaningfulSessionsToday.isEmpty || meaningfulImportedSessionToday != nil {
            next = .recovery
            if !strengthTodayInvolvedLegs {
                let legsReadiness = average(muscles.filter { legMuscleNames.contains($0.name) }.map(\.readiness))
                let legsFresh = legsReadiness == 0 || legsReadiness >= 55
                // The actual options (walk/sauna/Z2 run) live in
                // WorkoutPlanner's "Después del tren superior" proposal,
                // each gated on its own real signal (LifestyleFactorStore
                // for sauna, a real Caminata workout today, real hours
                // since this session) — this rationale doesn't repeat that
                // enumeration, so the same fixed list can't show up here
                // AND there, independent of what those checks actually say.
                rationale = legsFresh
                    ? "Ya has entrenado tren superior hoy (empuje/tirón) con volumen real — las piernas siguen frescas. Descansar es la opción por defecto, pero no la única razonable."
                    : "Ya has entrenado hoy. La recomendación se centra ahora en asimilar esa carga."
            } else {
                rationale = "Ya has entrenado hoy. La recomendación se centra ahora en asimilar esa carga."
            }
        // This IS the one real, day-to-day lever "Tres futuros" actually
        // connects to: each pace's own ratioCeiling, not a single
        // universal number anymore. Óptimo's ceiling (1.55) exactly
        // reproduces this app's pre-existing, already-validated behavior
        // — the old unconditional loadSummary.requiresRecovery check this
        // replaces. Conservador backs off earlier (1.30, the existing
        // "absorber" threshold). Agresivo is the only one that can
        // genuinely exceed 1.55 — see ProgressionPace's own comment for
        // why that's bounded at 1.80, not unbounded.
        } else if exceedsPaceCeiling(ratio: loadSummary.loadRatio, pace: profile.effectiveProgressionPace) {
            next = .recovery
            rationale = "Con tu ritmo de progresión (\(profile.effectiveProgressionPace.rawValue.lowercased())), la carga aguda de \(loadSummary.loadRatio.formatted(.number.precision(.fractionLength(2)))) ya pide absorber antes de sumar otra sesión exigente."
        } else if let hoursSinceLong, hoursSinceLong < 36 {
            next = .recovery
            rationale = "La tirada larga anterior terminó hace \(Int(hoursSinceLong.rounded())) h. El estímulo sigue dentro de su ventana principal de recuperación."
        } else if let hoursSinceQuality, hoursSinceQuality < 24 {
            next = .recovery
            rationale = "La última sesión de calidad terminó hace \(Int(hoursSinceQuality.rounded())) h. Hoy conviene absorberla antes de volver a cargar."
        } else if meaningfulTrainingDays72h(loadSummary.daily, now: now) >= 3 {
            // Counting bare "a workout happened" days here (the old
            // trainedDays72h) forced recovery even when one of those three
            // days was a genuinely easy Z1 recovery ride — the load-ratio
            // check just above already exists specifically to judge
            // accumulated stress, so this is now gated the same way: by
            // actual daily load (loadSummary.daily, the same figure the
            // activity-calendar heatmap already uses), not by a blind count
            // of calendar days that happened to have any activity at all.
            next = .recovery
            rationale = "Has acumulado carga real en tres días del último bloque de 72 h. Una pausa ahora mejora la continuidad del microciclo."
        } else if readiness < 58 {
            next = .recovery; rationale = "El plan pedía carga, pero hoy conviene absorberla antes de continuar."
        } else {
            let decision = balancedDecision(
                runs: runs.count, targetRuns: targetRuns,
                strength: strength, targetStrength: targetStrength,
                quality: quality, targetQuality: targetQuality,
                daysSinceStrength: daysSinceStrength,
                daysSinceSwim: daysSinceSwim, daysSinceBike: daysSinceBike,
                swimDeficit: max(0, targetSwim - completedSwim), bikeDeficit: max(0, targetBike - completedBike),
                swimMinutesDeficit: swimDose.deficitMinutes, bikeMinutesDeficit: bikeDose.deficitMinutes, brickMinutesDeficit: brickDose.deficitMinutes,
                hoursSinceLongSwim: hoursSinceLongSwim, hoursSinceLongBike: hoursSinceLongBike,
                hoursSinceLong: hoursSinceLong, hoursSinceQuality: hoursSinceQuality,
                trackedLiftDaysSince: trackedLiftDaysSince,
                recentHardPercentage: recentHardPercentage,
                avoidLegsTomorrow: avoidLegsTomorrow,
                lateWeek: lateWeek, readiness: readiness, muscles: muscles,
                block: block, goalFocus: goalFocus
            )
            next = decision.kind
            rationale = decision.rationale
        }

        // A "caution" alert doesn't override the calendar the way "recover"
        // does, but it should still cap what gets proposed: no quality,
        // long-run, or hybrid work while a moderate concordant deviation is
        // still unconfirmed. Strength is left alone — its own readiness-based
        // load factor already moderates intensity — and easy running or
        // recovery are exactly the "reduced or gentle" alternative this asks for.
        if physiologicalAlert?.severity == .caution, [.qualityRun, .longRun, .hybrid, .brick].contains(next) {
            let alert = physiologicalAlert!
            rationale = "\(alert.summary) \(alert.action) Se sustituye \(next.rawValue.lowercased()) por un estímulo más suave mientras se confirma."
            next = .easyRun
        }
        // Informed, not hidden: today only reaches this point instead of
        // .recovery because Agresivo's own ceiling (1.80) tolerated a
        // ratio that Óptimo/Conservador would already have stopped at
        // (1.55) — say so explicitly every time, not just in a settings
        // screen the user isn't looking at right now.
        if let riskDisclosure = aggressiveRiskDisclosure(ratio: loadSummary.loadRatio, pace: profile.effectiveProgressionPace, kind: next) {
            rationale = "\(riskDisclosure) \(rationale)"
        }

        let event = nextEvent(after: now, profile: profile)
        let recommendation = prescription(
            for: next, block: block, readiness: readiness, muscles: muscles,
            volumeFactor: adjustedTargets.volumeFactor, avoidLegsTomorrow: avoidLegsTomorrow
        )
        if isDeload {
            rationale += next == .recovery
                ? " Los mínimos reducidos de la descarga ya están cubiertos; no hace falta completar el volumen ordinario del bloque."
                : " La carga lleva varias semanas sostenida: esta sesión ya incorpora aproximadamente un 30% menos de volumen y elimina la calidad no imprescindible."
        }
        return WeeklyPlanStatus(
            block: block, completedRuns: runs.count,
            completedStrength: strength, completedQuality: quality,
            completedSwim: completedSwim, completedBike: completedBike,
            targetRuns: targetRuns, targetStrength: targetStrength, targetQuality: targetQuality,
            targetSwim: targetSwim, targetBike: targetBike,
            swimDose: swimDose, bikeDose: bikeDose, runDose: runDose, brickDose: brickDose,
            nextSession: next, recommendation: recommendation, rationale: rationale,
            daysToEvent: event.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0.date).day ?? 0 },
            eventName: event?.name, isDeload: isDeload,
            volumeFactor: adjustedTargets.volumeFactor,
            alreadyTrainedToday: !meaningfulSessionsToday.isEmpty || meaningfulImportedSessionToday != nil
        )
    }

    struct DayForecast: Identifiable {
        var id: Date { date }
        let date: Date
        let kind: PlannedSessionKind
        let isDeload: Bool
        let rationale: String
        // Only ever true for today (the real, non-simulated first day) —
        // the forward simulation for the rest of the week has no way to
        // know a real session happened on a day that hasn't occurred yet.
        var alreadyTrainedToday: Bool = false
        // What the week strip was missing: SOME sense of exigencia per day,
        // not just a kind + one-line rationale. Reuses the exact same
        // estimatedSessionMinutes/intensityLabel this function's own
        // simulation already computes internally (muscle-load estimation,
        // deciding which sessions to schedule) — not a second, separately
        // invented duration/zone guess. nil for kinds with no fixed
        // duration in this app's model (recovery, strength, race day —
        // strength's real duration depends on which exercises get chosen,
        // not a phase band). Deliberately no distance in km: this app
        // doesn't compute a per-session target distance anywhere, real or
        // simulated — only duration + zone — and this doesn't start
        // guessing one from an assumed pace.
        let targetMinutes: Int?
        let intensityLabel: String
    }

    // Same duration/zone shape "Propuesta de hoy" already shows per
    // session (Z1 for recovery, Z2 for easy/long/swim/bike, Z3–Z5 for
    // quality intervals) — a single label per kind, reused here so the
    // week strip and today's real card can never quietly disagree about
    // what "calidad" or "tirada larga" mean in terms of effort.
    nonisolated static func intensityLabel(for kind: PlannedSessionKind) -> String {
        switch kind {
        case .recovery: return "Z1 · muy suave"
        case .easyRun: return "Z2 · suave"
        case .qualityRun: return "Z3–Z5 · calidad"
        case .longRun: return "Z2 · continuo"
        case .strength: return "Fuerza"
        case .hybrid: return "Mixto · carrera + estaciones"
        case .swim: return "Z2 · técnica/continuo"
        case .bike: return "Z2 · continuo"
        case .brick: return "Mixto · bici + carrera"
        case .raceDay: return "Competición"
        }
    }

    // A rough, disclosed training-stress estimate per session kind, in the
    // same units PerformanceEngine's real daily load history uses (minutes
    // × cardioFactor, or sets × 3 for strength). There's no way to split a
    // user's own history by *planned* kind ahead of time, so this is a
    // structural estimate, not a personal one — the same treatment HYROX's
    // station-time band or the generic swim/bike pace already get elsewhere.
    nonisolated static func forecastSessionLoad(_ kind: PlannedSessionKind) -> Double {
        switch kind {
        case .recovery: return 8
        case .easyRun: return 34
        case .qualityRun: return 46
        case .longRun: return 58
        case .strength: return 28
        case .hybrid: return 50
        case .swim: return 30
        case .bike: return 42
        case .brick: return 56
        // Genuinely high — a real event is the hardest, most complete
        // effort in the whole plan, well above any single training session.
        case .raceDay: return 85
        }
    }

    // What actually happens today, when it's not éter's own real
    // recommendation — the link between "Simular decisión" and this
    // forecast the user asked for: pick a different decision there, and
    // the rest of the week recomputes from that alternate starting point
    // instead of silently continuing to show the real plan.
    struct DecisionOverride {
        /// nil for a lifestyle-only override (alcohol, fasting, hydration,
        /// sauna) — those don't replace today's training session, only
        /// shift the readiness that feeds into it.
        let kind: PlannedSessionKind?
        /// The load today's (possibly overridden) session actually
        /// contributes. DecisionSimulatorEngine already computes this from
        /// the person's own historical sessions of that type when
        /// available — reused here instead of the generic structural
        /// estimate, so the simulator and this forecast never disagree.
        let load: Double
        /// Readiness as of tomorrow, already computed by whichever model
        /// produced this override — DecisionSimulatorEngine's fatigue/
        /// recovery mechanics for a training swap, or its habit-learned
        /// adjustment for a lifestyle choice.
        let tomorrowReadiness: Int
        let todayRationale: String
    }

    // Advances every primitive balancedDecision keys off by exactly one
    // assumed day — shared by both today's own (possibly overridden)
    // session and every simulated day after it, so there's one place this
    // mechanic lives instead of two copies drifting apart.
    private struct ForwardState {
        var acute: Double
        var chronic: Double
        var readiness: Int
        // PR2, actually wired now (not just documented as the intent):
        // readiness below evolves through the SAME step()/TwinReadout.derive
        // mechanism TwinStateStore's own tomorrow-prediction uses, seeded
        // from today's real assessment.physiology — so the plan's own
        // forward simulation and the "mañana" prediction on Hoy can no
        // longer silently disagree about how fatigue/fitness evolve.
        // acute/chronic above deliberately stay on the old combined-channel
        // EWMA: splitting that ratio into separate aerobic/strength
        // channels for the pace-ceiling gate (exceedsPaceCeiling) is PR3's
        // job (DualLoad), not redone here — this only fixes the readiness/
        // score side of the promise, not the ratio-gate side.
        var physiology: TwinPhysiology
        let anchor: PersonalReadinessAnchor
        let calibration: TwinCalibration
        var runs: Int
        var strength: Int
        var quality: Int
        var swim: Int
        var bike: Int
        var hoursSinceLong: Double?
        var hoursSinceQuality: Double?
        var hoursSinceLongSwim: Double?
        var hoursSinceLongBike: Double?
        var daysSinceStrength: Double
        var daysSinceSwim: Double
        var daysSinceBike: Double
        // Never reset within the simulation, same honesty as
        // hoursSinceLongSwim/Bike above: a simulated .strength day is
        // generic (PlannedSessionKind can't say whether it specifically
        // included the tracked lift), so this only ever carries a real
        // seeded value forward, aging it, rather than pretending a
        // simulated day resolved it.
        var trackedLiftDaysSince: Double?
        var recentDailyLoads: [DailyTraining]

        // muscleFatigue: the caller's own per-exercise-precise tracker
        // (weekAhead's local `muscleFatigue`, seeded from
        // assessment.physiology.muscleFatigue and updated by
        // applyMuscleLoad/applyStrengthLoad with real MuscleMap.involvement
        // detail a scalar SessionLoad can't carry) — always wins over
        // step()'s own generic, no-exercise-detail decay of that same
        // field, which is discarded below rather than double-applied on
        // top of it. Not a second, competing muscle-fatigue tracker: this
        // is what keeps physiology.muscleFatigue in sync with the one real
        // source instead of silently diverging from it.
        mutating func apply(_ kind: PlannedSessionKind, on date: Date, load: Double, muscleFatigue: [String: Double]) {
            acute = PerformanceEngine.stepWeeklyEquivalent(acute, dayLoad: load, timeConstant: 7)
            chronic = PerformanceEngine.stepWeeklyEquivalent(chronic, dayLoad: load, timeConstant: 28)
            var stepped = step(physiology, session: SessionLoad.forecast(kind), recoverySignals: .none, dtDays: 1)
            stepped.muscleFatigue = muscleFatigue
            physiology = stepped
            readiness = TwinReadout.derive(from: physiology, anchor: anchor, calibration: calibration).score

            switch kind {
            case .easyRun: runs += 1
            case .qualityRun: runs += 1; quality += 1
            case .longRun: runs += 1
            case .strength: strength += 1
            case .swim: swim += 1
            case .bike: bike += 1
            default: break
            }
            daysSinceStrength = kind == .strength ? 0 : daysSinceStrength + 1
            daysSinceSwim = kind == .swim ? 0 : daysSinceSwim + 1
            daysSinceBike = kind == .bike ? 0 : daysSinceBike + 1
            trackedLiftDaysSince = trackedLiftDaysSince.map { $0 + 1 }
            hoursSinceLong = kind == .longRun ? 0 : (hoursSinceLong ?? 240) + 24
            // Unlike running, PlannedSessionKind has no separate "long swim"/
            // "long bike" case — a simulated .swim/.bike day is always
            // generic, so this can't tell whether it would have been a long
            // one. Rather than guess, it only ever carries a still-active
            // *real* constraint forward (it naturally clears itself once 24h
            // have elapsed), never invents a new one from a simulated day.
            hoursSinceLongSwim = (hoursSinceLongSwim ?? 240) + 24
            hoursSinceLongBike = (hoursSinceLongBike ?? 240) + 24
            // Hybrid/brick are treated as their own hard-session reset too —
            // they compete for the same next-day recovery window a quality
            // run would, so letting them re-arm the 24h gate is the safer
            // (more conservative) direction of error, not a looser one.
            hoursSinceQuality = [.qualityRun, .hybrid, .brick].contains(kind) ? 0 : (hoursSinceQuality ?? 240) + 24
            recentDailyLoads.append(DailyTraining(date: date, sessions: kind == .recovery ? 0 : 1, load: load))
        }
    }

    // A day-by-day forward look — today plus the next `days - 1` days — of
    // what éter would recommend if the plan is actually followed. With no
    // `override`, day 0 is exactly today's real recommendation (identical
    // to calling status() directly, same numbers, nothing re-derived).
    // Passing one — built from a "Simular decisión" result — replaces
    // today's own session (or, for a lifestyle choice, only tomorrow's
    // readiness) and recomputes every day after it from that alternate
    // starting point, which is the actual link between that simulator and
    // this forecast: choosing a different decision there changes the
    // 7-day cycle shown here, not just a single readiness number.
    //
    // Days 1+ always simulate forward under one deliberate, disclosed
    // assumption: readiness stays at *today's own* real value (or the
    // override's tomorrow value) — there is no way to know further-out
    // sleep or HRV, so this never pretends to predict them — and only
    // evolves mechanically from the same acute:chronic load ratio and
    // hours/days-since-last-session spacing rules status() itself already
    // uses today, advanced one simulated day at a time assuming each day's
    // own recommendation actually happened. This is what makes "vamos a
    // entrenar mañana, pasado, etc." something the model actually assumes,
    // instead of a projection that quietly treats every future day as rest.
    //
    // Two known simplifications, both erring toward *fewer* forced changes
    // rather than more: the weekly session targets and per-muscle readiness
    // are held at today's values across the whole window (they move slowly
    // day to day in practice), and the rolling 7-day completed-session
    // counters only ever increase during the simulation, even though a
    // session from today's real count would eventually roll out of a live
    // 7-day window — so by day 6 this can slightly overstate how "covered"
    // the week already is, never understate it.
    // TwinCore: same required-injection reasoning as status()/assess()
    // above — every value here used to come from a singleton instance
    // read somewhere inside this function's own call chain (directly, or
    // via the TwinEngine.assess/status calls it makes internally).
    static func weekAhead(health: HealthStore, imports: ImportStore, checkIn: DailyCheckIn?,
                          context: TwinContext,
                          now: Date = Date(), days: Int = 7, override: DecisionOverride? = nil) -> [DayForecast] {
        let profile = context.profile, reviews = context.reviews
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let assessment = TwinEngine.assess(health: health, imports: imports, checkIn: checkIn, context: context, now: now)
        // PR2: readiness routed through TwinReadout (same value assess()
        // always computed — score is still real-signal-driven, never fed
        // from physiology) instead of a bare Int.
        let real = status(health: health, imports: imports, readiness: assessment.readout.score, muscles: assessment.muscles,
                          checkIn: checkIn, context: context,
                          physiologicalAlert: assessment.physiologicalAlert, now: now)
        let todayKind = override?.kind ?? real.nextSession
        let todayRationale = override?.todayRationale ?? real.rationale
        // Same activeBlock(on:profile:) called again further down for the
        // muscle-load fold-in (todayBlock) — cheap and pure, not worth
        // reordering that later computation just to share this one call.
        let todayMinutesEstimate = Int(estimatedSessionMinutes(for: todayKind, phase: activeBlock(on: today, profile: profile).phase).rounded())
        var results = [DayForecast(date: today, kind: todayKind, isDeload: override == nil && real.isDeload, rationale: todayRationale,
                                   alreadyTrainedToday: override == nil && real.alreadyTrainedToday,
                                   targetMinutes: todayMinutesEstimate > 0 ? todayMinutesEstimate : nil,
                                   intensityLabel: intensityLabel(for: todayKind))]
        guard days > 1 else { return results }

        let loadSummary = PerformanceEngine.summarize(health: health, imports: imports, now: now)
        // Held at today's real value across the whole simulated window —
        // same "moves slowly day to day" simplification already applied
        // to weekly targets and muscle readiness above.
        let runningSummaryForIntensity = RunningPerformanceEngine.summarize(
            workouts: health.workoutHistory, zones: health.runningHeartRateZones,
            reviews: reviews, now: now
        )
        let recentHardPercentage = runningSummaryForIntensity.hasZoneData ? runningSummaryForIntensity.hardPercentage : nil
        var state = ForwardState(
            acute: loadSummary.acuteLoad, chronic: loadSummary.habitualLoad,
            readiness: assessment.readout.score,
            physiology: assessment.physiology, anchor: context.personalAnchor, calibration: context.calibration,
            runs: real.completedRuns, strength: real.completedStrength, quality: real.completedQuality,
            swim: real.completedSwim, bike: real.completedBike,
            hoursSinceLong: hoursSinceLastCompleted(matching: isLongRun, health: health, imports: imports, now: now),
            hoursSinceQuality: hoursSinceLastCompleted(matching: { $0.activity == "Carrera" && isQualityRun($0) }, health: health, imports: imports, now: now),
            hoursSinceLongSwim: hoursSinceLastCompleted(matching: isLongSwim, health: health, imports: imports, now: now),
            hoursSinceLongBike: hoursSinceLastCompleted(matching: isLongBike, health: health, imports: imports, now: now),
            daysSinceStrength: daysSinceStrength(health: health, imports: imports, now: now),
            daysSinceSwim: daysSince("Natación", health: health, imports: imports, now: now),
            daysSinceBike: daysSince("Ciclismo", health: health, imports: imports, now: now),
            trackedLiftDaysSince: trackedLiftDaysSince(imports: imports, profile: profile, now: now),
            // Seeded from the real 72h/28-day load history so the "3
            // meaningful days in 72h" rule still sees real training that
            // happened just before today, not a history reset to empty.
            recentDailyLoads: loadSummary.daily
        )
        // Fold today's own session in before projecting forward — otherwise
        // day+1's decision would ignore that today's real (or overridden)
        // session is actually happening, and e.g. still see the *previous*
        // long run as the most recent one instead of today's.
        state.apply(todayKind, on: today, load: override?.load ?? forecastSessionLoad(todayKind), muscleFatigue: assessment.physiology.muscleFatigue)
        // The override's own model (fatigue/recovery for a training swap,
        // or habit-learned impact for a lifestyle choice) already computed
        // tomorrow's readiness more precisely than apply()'s generic bump
        // above — that number wins so the simulator and this forecast
        // never show two different answers for the same hypothetical.
        if let override { state.readiness = override.tomorrowReadiness }

        let goalFocus = goalFocus(for: profile, on: now)
        // balancedDecision's per-muscle readiness gates (quality/long run/
        // hybrid/bike/brick all require effectiveLegReadiness >= 55-65)
        // exist to catch REAL fatigue from something the run-spacing rules
        // (hoursSinceLong/hoursSinceQuality, load ratio) wouldn't otherwise
        // see — e.g. a heavy leg day at the gym. This used to pass a
        // constant "everything at 75/100" for all 6 simulated days
        // regardless of what the simulation itself decided to schedule —
        // a plan that puts three leg-heavy strength days in one week would
        // show every one of them as equally fresh. Instead, seed real
        // per-muscle fatigue from today's actual assessment and decay/
        // reload it day by day as the simulation itself picks sessions,
        // using the same exponential-decay shape TwinEngine.calculateMuscles
        // already uses for the real (non-simulated) readiness — so a
        // strength day proposed on day 3 genuinely makes day 4's legs less
        // fresh for the rest of the projection, instead of every day
        // starting from the same invented number.
        //
        // PR2: seeded from assessment.physiology.muscleFatigue (the formal
        // vector) instead of re-deriving from assessment.muscles inline —
        // same numbers (physiology.muscleFatigue IS assessment.muscles
        // converted, not a second computation), now genuinely read from
        // TwinPhysiology as the brief asks, not just implicitly consistent
        // with it.
        var muscleFatigue = assessment.physiology.muscleFatigue
        // Default half-life TwinEngine.calculateMuscles itself falls back
        // to for a muscle with no learned recovery rate yet (per-muscle
        // learned rates live in TwinEngine's private state, not exposed
        // here) — the same neutral assumption, not a separately invented one.
        let defaultHalfLifeHours = 36.0
        // bestStrengthPattern's volumeUrgency (MEV/MAV/MRV) reads each
        // muscle's own `recentSets` — real for today's actual decision, but
        // simulatedMuscles() used to hardcode 0 for every muscle on every
        // simulated day. Since every muscle's landmark MEV is > 0, 0 sets
        // always reads as "real deficit" for all of them at once: the same
        // uniform +25 for every candidate pattern, which cancels out of the
        // ranking entirely (every candidateTotal shifts by the same amount)
        // and silently collapses the simulated week back to readiness-only
        // selection — so a plan that puts "empuje" on day 1, day 3 AND day 5
        // never sees that pecho already blew past its own MAV, and a group
        // sitting under its MEV all week never gets pulled toward. Seeded
        // from the same real 7-day recentSets `muscleFatigue` above is
        // seeded from, then accumulated forward as applyStrengthLoad below
        // proposes real exercises — so a simulated day's own choice moves
        // the NEXT simulated day's volume urgency, the same way it already
        // moves muscleFatigue. One known imprecision, deliberately
        // accepted: the real seed itself never rolls off its own 7-day
        // window as simulated days pass (a set logged 6 real days ago is
        // still counted on simulated day+6, when it's actually 12 days
        // old by then) — the same "held at today's value across the whole
        // window" simplification this function already applies to
        // readiness and hoursSince*, not a new one invented for this fix.
        var simulatedSets = Dictionary(uniqueKeysWithValues: assessment.muscles.map { ($0.name, $0.recentSets) })
        func simulatedMuscles() -> [MuscleReadiness] {
            muscleFatigue.map { MuscleReadiness(name: $0.key, readiness: min(100, max(0, Int((100 - $0.value).rounded()))), lastTrained: nil, recentSets: simulatedSets[$0.key] ?? 0) }
        }
        // Strength load now comes from the actual session WorkoutPlanner.gym
        // would propose for this simulated day — real exercise names, each
        // mapped through MuscleMap.involvement for which muscles it really
        // trains and how much, and a real effective-set count (goal-aware
        // set count × the same RPE-proximity effort-weighting real logged
        // sessions get, derived from the prescribed RIR) instead of a flat
        // "4 sets to every muscle in the pattern" that had no idea which
        // exercises, or how many sets each, the day would actually contain.
        func applyStrengthLoad(avoidLegs: Bool = false) {
            let muscles = simulatedMuscles()
            let pattern = bestStrengthPattern(muscles, avoidLegs: avoidLegs)
            let goals = profile.goals
            let proposed = WorkoutPlanner.gym(for: pattern, imports: imports, light: false, muscles: muscles)
            for exercise in proposed.exercises {
                let context = StrengthPrescriptionEngine.goalContext(for: exercise.name, goals: goals)
                let band = StrengthPrescriptionEngine.repRange(for: context, light: false)
                let effort = StrengthProgressEngine.effortWeight(forRPE: max(0, 10 - band.estimatedRIR))
                let effectiveSets = Double(band.sets) * effort
                for (muscle, weight) in MuscleMap.involvement(for: exercise.name) {
                    muscleFatigue[muscle, default: 0] += effectiveSets * weight * 5.2
                    // Same effectiveSets × involvement-weight product
                    // TwinEngine's real effectiveMuscleSets already sums
                    // per workout — just without the 5.2 fatigue scaling,
                    // which only belongs on the fatigue side.
                    simulatedSets[muscle, default: 0] += Int((effectiveSets * weight).rounded())
                }
            }
        }
        // Real duration/elevation when a matching session already
        // happened on that date (today, typically — a simulated future
        // day has no concrete session yet); a phase-aware estimate
        // otherwise. Either way, cardioMuscleLoad now scales by an actual
        // session length instead of one fixed vector per kind regardless
        // of whether it was 70 or 150 minutes, flat or a mountain.
        func applyMuscleLoad(_ kind: PlannedSessionKind, on date: Date, phase: TrainingPhase, avoidLegs: Bool = false) {
            if kind == .strength { applyStrengthLoad(avoidLegs: avoidLegs); return }
            let matchingActivity: String?
            switch kind {
            case .easyRun, .qualityRun, .longRun: matchingActivity = "Carrera"
            case .bike: matchingActivity = "Ciclismo"
            default: matchingActivity = nil
            }
            // Sum every same-day, same-activity workout instead of picking
            // just the first match — a double session day (e.g. an easy
            // morning run plus an evening quality run) was silently scored
            // on whichever one happened to come first in the array, losing
            // the other session's real load entirely.
            let realMatches = matchingActivity.map { activity in
                health.recentWorkouts.filter { calendar.isDate($0.date, inSameDayAs: date) && $0.activity == activity }
            } ?? []
            let durationMinutes = realMatches.isEmpty
                ? Self.estimatedSessionMinutes(for: kind, phase: phase)
                : realMatches.reduce(0) { $0 + $1.durationMinutes }
            let elevationMeters = realMatches.reduce(0) { $0 + ($1.elevationMeters ?? 0) }
            // Real, not derived from ascent — a loop route descends
            // roughly what it climbs, but a point-to-point course
            // (a downhill race, an out-and-back with a net descent)
            // doesn't, and eccentric braking on the way down is real
            // muscle damage a climb-only figure can't see. nil (no route,
            // indoor session, older Watch) contributes 0, same as
            // elevationMeters' own ?? 0 above — never guessed.
            let elevationDescendedMeters = realMatches.reduce(0) { $0 + ($1.elevationDescendedMeters ?? 0) }
            let intensityFactor = Self.realIntensityFactor(
                matches: realMatches, restingHRHistory: health.restingHeartRateHistory.suffix(14).map(\.value),
                restingHRSnapshot: Double(health.snapshot.restingHeartRate),
                configuredMaxHR: profile.maximumHeartRate.map(Double.init),
                birthDate: profile.birthDate, manualBoundaries: profile.manualHeartRateZones
            )
            for (muscle, sets) in Self.cardioMuscleLoad(for: kind, durationMinutes: durationMinutes, elevationMeters: elevationMeters,
                                                        elevationDescendedMeters: elevationDescendedMeters, intensityFactor: intensityFactor) {
                muscleFatigue[muscle, default: 0] += sets * 5.2
            }
        }
        // Today's own session (already folded into `state` above) also
        // needs to load the muscle model before day+1 decays it — otherwise
        // a real strength session logged/proposed for today would vanish
        // from tomorrow's simulated fatigue entirely.
        let todayBlock = activeBlock(on: today, profile: profile)
        let tomorrowWeekdayFromToday = calendar.component(.weekday, from: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        let tomorrowLateWeekFromToday = tomorrowWeekdayFromToday == profile.preferredLongRunWeekday || tomorrowWeekdayFromToday == 1 || tomorrowWeekdayFromToday == 7
        let avoidLegsAfterToday = legSensitiveRunLikelyTomorrow(
            hoursSinceQuality: state.hoursSinceQuality, hoursSinceLong: state.hoursSinceLong,
            tomorrowIsLateWeek: tomorrowLateWeekFromToday, qualityDeficit: max(0, real.targetQuality - state.quality),
            goalFocus: goalFocus
        )
        applyMuscleLoad(todayKind, on: today, phase: todayBlock.phase, avoidLegs: avoidLegsAfterToday)

        // Real weekly minute deficits for swim/bike/brick used to stay
        // fixed at today's own value across every simulated day — able to
        // project real fatigue, but with no way to show whether the
        // week's own plan would actually complete the weekly dose. Each
        // mutates as the simulation itself picks (or skips) swim/bike/
        // brick days, using the same estimated duration per session
        // cardioMuscleLoad above now uses.
        var remainingSwimMinutes = real.swimDose.deficitMinutes
        var remainingBikeMinutes = real.bikeDose.deficitMinutes
        var remainingBrickMinutes = real.brickDose.deficitMinutes
        func applyDoseProgress(_ kind: PlannedSessionKind, phase: TrainingPhase) {
            let minutes = Self.estimatedSessionMinutes(for: kind, phase: phase)
            switch kind {
            case .swim: remainingSwimMinutes = max(0, remainingSwimMinutes - minutes)
            case .bike: remainingBikeMinutes = max(0, remainingBikeMinutes - minutes)
            case .brick: remainingBrickMinutes = max(0, remainingBrickMinutes - minutes)
            default: break
            }
        }
        applyDoseProgress(todayKind, phase: todayBlock.phase)

        for offset in 1..<days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            // One day's worth of decay on whatever fatigue the previous
            // simulated (or today's real) session left behind, before this
            // day's own session — if any — adds fresh load on top.
            for muscle in muscleFatigue.keys { muscleFatigue[muscle]! *= pow(0.5, 24.0 / defaultHalfLifeHours) }
            let block = activeBlock(on: date, profile: profile)
            let ratio = state.chronic > 0 ? state.acute / state.chronic : 0
            let weekday = calendar.component(.weekday, from: date)
            let lateWeek = weekday == profile.preferredLongRunWeekday || weekday == 1 || weekday == 7
            let tomorrowWeekday = calendar.component(.weekday, from: calendar.date(byAdding: .day, value: 1, to: date) ?? date)
            let tomorrowLateWeek = tomorrowWeekday == profile.preferredLongRunWeekday || tomorrowWeekday == 1 || tomorrowWeekday == 7
            let avoidLegsTomorrow = legSensitiveRunLikelyTomorrow(
                hoursSinceQuality: state.hoursSinceQuality, hoursSinceLong: state.hoursSinceLong,
                tomorrowIsLateWeek: tomorrowLateWeek, qualityDeficit: max(0, real.targetQuality - state.quality),
                goalFocus: goalFocus
            )

            let kind: PlannedSessionKind
            let rationale: String
            if let event = eventToday(date, profile: profile) {
                kind = .raceDay
                rationale = "Día de \(event.title): el objetivo es ejecutar, no añadir otro entrenamiento."
            } else if state.readiness < 58 {
                kind = .recovery
                rationale = "Disponibilidad prevista por debajo del umbral de carga."
            // Same pace-dependent ceiling status() applies to today's real
            // decision — see ProgressionPace's own comment. Replaces the
            // old unconditional "ratio >= 1.55" check: Óptimo's ceiling IS
            // 1.55, so this reproduces the exact old behavior by default;
            // only Agresivo can genuinely go further.
            } else if exceedsPaceCeiling(ratio: ratio, pace: profile.effectiveProgressionPace) {
                kind = .recovery
                rationale = "Con tu ritmo de progresión (\(profile.effectiveProgressionPace.rawValue.lowercased())), la carga acumulada prevista ya pide absorber antes de sumar otra sesión exigente."
            } else if let hoursSinceLong = state.hoursSinceLong, hoursSinceLong < 36 {
                kind = .recovery
                rationale = "Sigue dentro de la ventana de recuperación de la tirada larga prevista."
            } else if let hoursSinceQuality = state.hoursSinceQuality, hoursSinceQuality < 24 {
                kind = .recovery
                rationale = "Sigue dentro de la ventana de recuperación de la sesión de calidad prevista."
            } else if meaningfulTrainingDays72h(state.recentDailyLoads, now: date) >= 3 {
                kind = .recovery
                rationale = "Tres días de carga real asumida en las últimas 72 h del plan."
            } else {
                let decision = balancedDecision(
                    runs: state.runs, targetRuns: real.targetRuns,
                    strength: state.strength, targetStrength: real.targetStrength,
                    quality: state.quality, targetQuality: real.targetQuality,
                    daysSinceStrength: state.daysSinceStrength,
                    daysSinceSwim: state.daysSinceSwim, daysSinceBike: state.daysSinceBike,
                    swimDeficit: max(0, real.targetSwim - state.swim), bikeDeficit: max(0, real.targetBike - state.bike),
                    // Decremented day by day as the simulation itself
                    // schedules swim/bike/brick sessions (applyDoseProgress
                    // below), using an estimated duration per session —
                    // instead of holding today's real deficit fixed for
                    // the whole simulated week regardless of what got
                    // scheduled since. This is what lets the forecast show
                    // whether its own week actually closes the weekly dose.
                    swimMinutesDeficit: remainingSwimMinutes, bikeMinutesDeficit: remainingBikeMinutes,
                    brickMinutesDeficit: remainingBrickMinutes,
                    hoursSinceLongSwim: state.hoursSinceLongSwim, hoursSinceLongBike: state.hoursSinceLongBike,
                    hoursSinceLong: state.hoursSinceLong, hoursSinceQuality: state.hoursSinceQuality,
                    trackedLiftDaysSince: state.trackedLiftDaysSince,
                    recentHardPercentage: recentHardPercentage,
                    avoidLegsTomorrow: avoidLegsTomorrow,
                    lateWeek: lateWeek, readiness: state.readiness, muscles: simulatedMuscles(),
                    block: block, goalFocus: goalFocus
                )
                kind = decision.kind
                rationale = decision.rationale
            }

            applyMuscleLoad(kind, on: date, phase: block.phase, avoidLegs: avoidLegsTomorrow)
            applyDoseProgress(kind, phase: block.phase)
            state.apply(kind, on: date, load: forecastSessionLoad(kind), muscleFatigue: muscleFatigue)
            // Same informed-not-hidden disclosure status() applies to
            // today — a simulated day this far ahead can equally be one
            // Agresivo's extra margin (over 1.55) is what actually let
            // through.
            let finalRationale: String
            if let riskDisclosure = aggressiveRiskDisclosure(ratio: ratio, pace: profile.effectiveProgressionPace, kind: kind) {
                finalRationale = "\(riskDisclosure) \(rationale)"
            } else {
                finalRationale = rationale
            }
            let simulatedMinutesEstimate = Int(estimatedSessionMinutes(for: kind, phase: block.phase).rounded())
            results.append(DayForecast(date: date, kind: kind, isDeload: false, rationale: finalRationale,
                                       targetMinutes: simulatedMinutesEstimate > 0 ? simulatedMinutesEstimate : nil,
                                       intensityLabel: intensityLabel(for: kind)))
        }
        return results
    }

    nonisolated static func deloadAdjustment(runningSessions: Int, strengthSessions: Int,
                                              qualitySessions: Int, enabled: Bool) -> DeloadAdjustment {
        guard enabled else {
            return DeloadAdjustment(runningSessions: runningSessions, strengthSessions: strengthSessions,
                                    qualitySessions: qualitySessions, volumeFactor: 1)
        }
        func reduced(_ value: Int) -> Int {
            guard value > 0 else { return 0 }
            return max(1, Int((Double(value) * 0.70).rounded()))
        }
        return DeloadAdjustment(
            runningSessions: reduced(runningSessions),
            strengthSessions: reduced(strengthSessions),
            qualitySessions: 0,
            volumeFactor: 0.70
        )
    }

    // A day only counts toward "you need an actual rest day" if it carried
    // real training stress — not just "some activity happened". 20 mirrors
    // the same light/moderate/heavy load banding activityCalendar already
    // uses (light < 35): well below a normal session, but enough to exclude
    // a short walk or a genuinely easy Z1 recovery ride — exactly the case
    // that used to force recovery here even though the accumulated-load
    // check right above (loadSummary.requiresRecovery, the acute:chronic
    // ratio) correctly saw nothing to worry about.
    nonisolated static func meaningfulTrainingDays72h(_ daily: [DailyTraining], now: Date, threshold: Double = 20) -> Int {
        let cutoff = now.addingTimeInterval(-72 * 3600)
        return daily.filter { $0.date >= cutoff && $0.date <= now && $0.load >= threshold }.count
    }

    static func activeBlock(on date: Date, profile: AthletePlanProfile) -> TrainingBlock {
        let blocks = blocks(for: profile)
        if let exact = blocks.first(where: { date >= $0.start && date < Calendar.current.date(byAdding: .day, value: 1, to: $0.end)! }) { return exact }
        if date < blocks[0].start { return blocks[0] }
        return generalBlock(on: date, profile: profile)
    }

    private static func generalBlock(on date: Date, profile: AthletePlanProfile) -> TrainingBlock {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: date)!
        let end = Calendar.current.date(byAdding: .day, value: 365, to: date)!
        let focus = goalFocus(for: profile, on: date)
        let runs: ClosedRange<Int>
        let strength: ClosedRange<Int>
        let quality: ClosedRange<Int>
        if focus.strength >= 0.55 {
            runs = 1...3; strength = 3...5; quality = 0...1
        } else if focus.running >= 0.60 {
            runs = 3...5; strength = 1...3; quality = 1...2
        } else if focus.hybrid >= 0.25 {
            runs = 2...4; strength = 2...4; quality = 0...1
        } else {
            runs = 2...4; strength = 2...4; quality = 0...1
        }
        return TrainingBlock(name: "Desarrollo híbrido", phase: .base, start: start, end: end,
                             objective: "Desarrollar las capacidades que más transfieren a los objetivos activos sin abandonar las de mantenimiento.",
                             runningSessions: runs, strengthSessions: strength, qualitySessions: quality,
                             emphasis: ["Consistencia", "Progresión", "Recuperación"])
    }

    private static func prescription(for kind: PlannedSessionKind, block: TrainingBlock, readiness: Int,
                                     muscles: [MuscleReadiness], volumeFactor: Double = 1, avoidLegsTomorrow: Bool = false) -> String {
        let deload = volumeFactor < 0.95
        switch kind {
        case .easyRun: return deload
            ? "Carrera suave 25–40 min · Z1–Z2 · sin progresión final; termina claramente fresco."
            : "Carrera suave 35–55 min · principalmente Z2 · termina con sensación de poder continuar."
        case .qualityRun:
            if deload { return "Descarga: sustituye la calidad por 25–40 min suaves y 3–4 progresivos breves, sin acumular tiempo en Z4–Z5." }
            return block.name.contains("Afinamiento") ? "Sesión corta de ritmo: 10–15 min suaves + 3–5 bloques controlados + vuelta a la calma." : "Calidad controlada: calentamiento + intervalos o cuestas con recuperación completa; evita convertirla en un test."
        case .longRun: return deload
            ? "Tirada reducida 45–65 min · Z2 cómoda · sin ampliar distancia aunque las sensaciones sean buenas."
            : "Tirada larga cómoda · aumenta duración solo si la carga de las últimas semanas lo permite · mayoritariamente Z2."
        case .strength:
            // "Evita interferir con la próxima carrera clave" used to be
            // fixed prose attached to every non-deload strength day
            // regardless of whether a run was actually imminent — now
            // avoidLegsTomorrow is a real, computed check
            // (legSensitiveRunLikelyTomorrow), and the pattern itself
            // changes when it fires: pierna is removed from the running
            // for today, not just mentioned as a concern.
            let ready = bestStrengthPattern(muscles, avoidLegs: avoidLegsTomorrow)
            if deload {
                return "Fuerza de \(ready.lowercased()) · 2–3 series por ejercicio, RIR 3–4 y sin llegar al fallo."
            }
            return avoidLegsTomorrow
                ? "Fuerza de \(ready.lowercased()) · deja 2–3 repeticiones en reserva; piernas fuera de hoy a propósito para llegar frescas a la sesión de carrera prevista."
                : "Fuerza de \(ready.lowercased()) · deja 2–3 repeticiones en reserva."
        case .hybrid: return deload
            ? "Técnica híbrida al 70% del volumen habitual · transiciones limpias y ninguna estación al límite."
            : "Sesión híbrida específica y controlada · alterna carrera y estaciones sin buscar fatiga máxima."
        case .swim: return deload
            ? "Natación técnica y suave · sin series al límite esta semana."
            : "Natación con series calibradas a tu ritmo · técnica primero, fatiga después."
        case .bike: return deload
            ? "Salida de bici suave · sin buscar potencia ni ritmo, solo mantener el patrón."
            : "Salida de bici con bloques específicos · cadencia alta antes que fuerza bruta."
        case .brick: return deload
            ? "Brick reducido · bici corta y carrera muy breve, solo para mantener la sensación de piernas cansadas."
            : "Brick bici-carrera · transición realista y unos kilómetros a ritmo objetivo con las piernas ya cargadas."
        case .recovery: return readiness < 42 ? "Descanso o paseo suave; prioriza sueño, alimentación y evolución de síntomas." : "Recuperación activa 25–40 min en Z1 o movilidad suave."
        case .raceDay: return "Protocolo de competición, no un entrenamiento: repasa ritmo objetivo, nutrición/hidratación, transición y material antes de empezar."
        }
    }

    // Readiness alone only answers "how recovered is this muscle" — it
    // says nothing about whether that muscle has actually gotten its own
    // weekly dose yet. Before this, a pattern whose muscles were merely
    // the freshest kept winning even after it had already passed its own
    // MRV for the week, while a pattern sitting well below its MEV never
    // got a real pull toward it as long as something else was slightly
    // fresher. volumeUrgency adds that missing signal without letting it
    // override genuine fatigue — the readiness floor below still gates that.
    private static func volumeUrgency(_ muscle: String, muscles: [MuscleReadiness]) -> Double {
        guard let recentSets = muscles.first(where: { $0.name == muscle })?.recentSets else { return 0 }
        let landmarks = MuscleVolumeLandmarkTable.landmarks(for: muscle)
        let sets = Double(recentSets)
        if sets >= landmarks.mrv { return -25 } // past this week's ceiling — actively discourage more
        if sets < landmarks.mev { return 25 }   // real deficit — actively encourage
        if sets < landmarks.mav { return 10 }   // still building toward the productive target
        return -10                               // between MAV and MRV — no urgency either way
    }

    // Internal (not private) so EngineTests can drive the volume-landmark
    // gating directly with constructed MuscleReadiness arrays, instead of
    // only being reachable indirectly through a full status() call.
    private static func averageDouble(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    // The other, previously-missing half of interference protection: a
    // fatigued leg already blocks a scheduled run elsewhere in this file
    // (the effectiveLegReadiness gates) — real, but reactive to fatigue
    // that already happened. This answers the forward-looking question
    // instead: "does tomorrow plausibly want fresh legs?" None of the
    // three checks depend on what pattern gets chosen today — only
    // elapsed time, day-of-week and goal focus — so it can be answered
    // without simulating tomorrow at all.
    static func legSensitiveRunLikelyTomorrow(
        hoursSinceQuality: Double?, hoursSinceLong: Double?, tomorrowIsLateWeek: Bool,
        qualityDeficit: Int, goalFocus: GoalTrainingFocus
    ) -> Bool {
        let tomorrowHoursSinceQuality = (hoursSinceQuality ?? 240) + 24
        let tomorrowHoursSinceLong = (hoursSinceLong ?? 240) + 24
        let qualityRunPlausible = qualityDeficit > 0 && tomorrowHoursSinceQuality >= 72
        let longRunPlausible = goalFocus.running > 0.05 && tomorrowIsLateWeek && tomorrowHoursSinceLong >= 96
        let hybridPlausible = goalFocus.hybrid >= 0.22 && tomorrowHoursSinceQuality >= 48
        return qualityRunPlausible || longRunPlausible || hybridPlausible
    }

    // The one real connection between "Tres futuros, 8 semanas" and the
    // actual day-to-day plan — see ProgressionPace's own comment for what
    // each pace's ceiling means and why Agresivo's is allowed higher than
    // the other two. Internal (not private) so EngineTests can verify the
    // gate directly instead of only through a full status()/weekAhead() call.
    nonisolated static func exceedsPaceCeiling(ratio: Double, pace: ProgressionPace) -> Bool {
        ratio >= pace.ratioCeiling
    }

    // Agresivo is the only pace whose ceiling actually crosses
    // PerformanceEngine's own literature-anchored danger line
    // (ProgressionPace.elevatedRiskRatio, 1.55) — every real day that
    // extra margin actually gets used (ratio in [1.55, 1.80), still under
    // the day's own kind decision rather than forced to .recovery) must
    // say so explicitly, not proceed as if the elevated risk weren't
    // there. Internal (not private) so EngineTests can verify this
    // directly.
    nonisolated static func aggressiveRiskDisclosure(ratio: Double, pace: ProgressionPace, kind: PlannedSessionKind) -> String? {
        guard pace == .aggressive, kind != .recovery, ratio >= ProgressionPace.elevatedRiskRatio else { return nil }
        return "⚠️ Zona de riesgo elevado de lesión (carga \(ratio.formatted(.number.precision(.fractionLength(2))))×, por encima de 1.55 — Gabbett et al.). Tu ritmo Agresivo lo permite hasta 1.80, pero no es la operación habitual."
    }

    static func bestStrengthPattern(_ muscles: [MuscleReadiness], avoidLegs: Bool = false) -> String {
        let ready = Dictionary(uniqueKeysWithValues: muscles.map { ($0.name, $0.readiness) })
        var groups: [(String, [String])] = [("pierna", ["Cuádriceps", "Glúteos", "Isquios"]), ("empuje", ["Pecho", "Hombros", "Tríceps"]), ("tirón", ["Espalda", "Bíceps"])]
        // Removed as a candidate entirely, not merely penalized — the
        // point of protecting tomorrow's run is that today's choice
        // shouldn't load legs at all when a real alternative exists.
        if avoidLegs { groups.removeAll { $0.0 == "pierna" } }
        var scored: [(name: String, readiness: Double, urgency: Double)] = []
        for (name, members) in groups {
            let readiness = average(members.map { ready[$0] ?? 50 })
            let urgency = averageDouble(members.map { volumeUrgency($0, muscles: muscles) })
            scored.append((name: name, readiness: readiness, urgency: urgency))
        }
        // Volume urgency can shift which of the reasonably-recovered
        // patterns wins, but never rescues one that's genuinely fatigued —
        // same >=50 floor already used elsewhere in this file for "don't
        // pick a truly tired muscle group."
        let eligible = scored.filter { $0.readiness >= 50 }
        let pool = eligible.isEmpty ? scored : eligible
        var best = pool.first
        for candidate in pool.dropFirst() {
            let candidateTotal = candidate.readiness + candidate.urgency
            let bestTotal = (best?.readiness ?? 0) + (best?.urgency ?? 0)
            if candidateTotal > bestTotal { best = candidate }
        }
        return best?.name ?? "cuerpo completo"
    }

    // Cardio's own, lighter local-muscle load for weekAhead's forward
    // fatigue simulation — running and cycling genuinely fatigue specific
    // leg muscles (a long run leaves real quad/calf/hamstring fatigue; a
    // hard ride leaves real quad/glute fatigue), just at a real fraction
    // of a dedicated strength session's cost, not zero. Ramped by how
    // demanding the running type actually is (easy < quality < long)
    // rather than one flat number for every run. Swim deliberately isn't
    // included here — it doesn't load these same lower-body muscles the
    // way weight-bearing running/cycling do. A real, standalone function
    // (not a closure nested inside weekAhead) so it's directly testable.
    //
    // `durationMinutes`/`elevationMeters` scale that base credit by the
    // actual session, instead of the same fixed vector for a 70-minute
    // flat long run and a 150-minute mountainous one — a real duration
    // (this session's own, or an estimated one for a day that hasn't
    // happened yet) and real elevation gain both matter. There's no
    // separate "surface" field anywhere in the data model, so elevation
    // gain doubles as the best available proxy for "trail vs road" — a
    // genuinely hilly session gets extra credit for the reason that
    // actually drives it (eccentric loading), even without a literal
    // surface label to key off.
    // intensityFactor: 1.0 means "no real HR data, assume nothing" — never
    // guessed from kind alone (a qualityRun already gets a higher base
    // than easyRun for exactly that reason). When real average-HR zone
    // data IS available for the actual completed session, this scales
    // the SAME real drivers of muscle damage a hard effort actually adds
    // on top of duration/elevation — same capped, proportional shape as
    // elevationFactor below, not a validated physiological formula.
    // Z1-Z2 (easy, the dominant real-world case) leaves load unchanged;
    // each zone above that adds 15%, capped at Z5's +45%. See
    // TrainingPlanEngine.weekAhead's applyMuscleLoad for where the real
    // zone comes from (HeartRateZoneClassifier, this person's own
    // Karvonen %HRR or manual lactate-test boundaries).
    static func cardioMuscleLoad(for kind: PlannedSessionKind, durationMinutes: Double? = nil, elevationMeters: Double = 0,
                                 elevationDescendedMeters: Double = 0, intensityFactor: Double = 1.0) -> [String: Double] {
        let base: [String: Double]
        let referenceMinutes: Double
        switch kind {
        case .easyRun: base = ["Gemelos": 0.5, "Cuádriceps": 0.5, "Isquios": 0.5]; referenceMinutes = 27.5
        case .qualityRun: base = ["Gemelos": 0.75, "Cuádriceps": 0.75, "Isquios": 0.75]; referenceMinutes = 45
        case .longRun: base = ["Gemelos": 1.0, "Cuádriceps": 1.0, "Isquios": 1.0]; referenceMinutes = 45
        case .bike: base = ["Cuádriceps": 0.75, "Glúteos": 0.75]; referenceMinutes = 55
        // Unscaled — brick/hybrid are already a composite of several
        // disciplines with no single duration/elevation of their own in
        // this model yet.
        case .hybrid, .brick: return ["Cuádriceps": 2.0, "Glúteos": 2.0, "Core": 2.0]
        default: return [:]
        }
        // Clamped so a 10-minute jog can't erase fatigue accounting and a
        // multi-hour outlier doesn't blow the model up either.
        let durationFactor = durationMinutes.map { min(2.5, max(0.4, $0 / referenceMinutes)) } ?? 1.0
        let ascentFactor = 1 + min(1.0, max(0, elevationMeters) / 500 * 0.5)
        // Same capped shape as ascent, kept as its own separate factor
        // (not folded into ascentFactor) because concentric climbing and
        // eccentric descending are different loading mechanisms — an
        // out-and-back or loop route gets real credit for both instead of
        // whichever direction happened to be in the metadata.
        // elevationDescendedMeters defaults to 0 (no extra load) for
        // every existing caller that hasn't supplied it, same as
        // elevationMeters' own default above.
        let descentFactor = 1 + min(1.0, max(0, elevationDescendedMeters) / 500 * 0.5)
        return base.mapValues { $0 * durationFactor * ascentFactor * descentFactor * max(1.0, intensityFactor) }
    }

    // Duration-weighted average HR across every real completed session
    // matched to this simulated day (a double session day shouldn't let
    // whichever workout happens to be first in the array decide the whole
    // day's intensity), classified against this person's own real zone
    // thresholds — never a guess from pace or session kind. Returns 1.0
    // (no change) whenever there's genuinely nothing to classify: no real
    // match, no averageHeartRate on any of them, or the classifier itself
    // has neither a manual boundary nor any way to estimate a max (no
    // configured max and no birthDate) — silence, not a fabricated
    // "assume Z2" default. Internal (not private) so EngineTests can
    // drive this directly instead of only through a full weekAhead() call.
    static func realIntensityFactor(
        matches: [HealthWorkout], restingHRHistory: [Double], restingHRSnapshot: Double,
        configuredMaxHR: Double?, birthDate: Date?, manualBoundaries: HeartRateZoneBoundaries?
    ) -> Double {
        let withHR = matches.filter { $0.averageHeartRate != nil && $0.durationMinutes > 0 }
        guard !withHR.isEmpty else { return 1.0 }
        guard manualBoundaries != nil || configuredMaxHR != nil || birthDate != nil else { return 1.0 }
        let totalMinutes = withHR.reduce(0) { $0 + $1.durationMinutes }
        guard totalMinutes > 0 else { return 1.0 }
        let weightedBPM = withHR.reduce(0.0) { $0 + $1.averageHeartRate! * $1.durationMinutes } / totalMinutes
        // The workout's own recorded peak stands in for classifyHeartRateZones'
        // per-second "observedPeak" — both describe the same thing (how high
        // this effort actually reached), just already computed once by
        // HealthKit instead of requiring a fresh sample query here.
        let observedPeak = withHR.compactMap(\.maxHeartRate).max()
        let effectiveMax = HeartRateZoneClassifier.effectiveMaximum(configured: configuredMaxHR, birthDate: birthDate, observedPeak: observedPeak)
        let restingHR = HeartRateZoneClassifier.restingHR(recentHistory: restingHRHistory, snapshotFallback: restingHRSnapshot)
        let zone = HeartRateZoneClassifier.zone(bpm: weightedBPM, manualBoundaries: manualBoundaries, effectiveMax: effectiveMax, restingHR: restingHR)
        return 1 + Double(max(0, zone - 2)) * 0.15
    }

    // A representative session duration for a given kind/phase — reused
    // both to scale cardioMuscleLoad above by real session length, and to
    // decrement weekAhead's own swim/bike/brick minute deficits day by
    // day instead of holding them fixed for the whole simulated week.
    // Real, goal/phase-aware bands (WorkoutPlanner's own) where one
    // already exists; a disclosed flat estimate otherwise — quality
    // running has no phase band today (WorkoutPlanner.gym's own "Calidad
    // de carrera" duration is a fixed 40–55 min regardless of phase), and
    // brick's own bike-leg band lives private inside
    // WorkoutPlanner.brickWorkout, so this approximates it from the
    // public bike band instead of duplicating those exact private numbers.
    static func estimatedSessionMinutes(for kind: PlannedSessionKind, phase: TrainingPhase) -> Double {
        switch kind {
        case .easyRun:
            let band = WorkoutPlanner.easyRunBand(phase: phase)
            return (band.min + band.max) / 2
        case .qualityRun:
            return 47.5
        case .longRun:
            let band = WorkoutPlanner.longRunBand(phase: phase)
            return (band.min + band.max) / 2
        case .bike:
            let band = WorkoutPlanner.bikeBand(phase: phase)
            return (band.min + band.max) / 2
        case .swim:
            let band = WorkoutPlanner.swimBand(phase: phase)
            return (band.min + band.max) / 2
        case .brick:
            let bikeLeg = WorkoutPlanner.bikeBand(phase: phase)
            return (bikeLeg.min + bikeLeg.max) / 2 * 0.6 + 15 + 7
        default:
            return 0
        }
    }

    /// Compares the opportunity cost of the available sessions. Running keeps a
    /// small priority in race blocks, while an overdue strength stimulus grows in
    /// urgency instead of waiting indefinitely for every running target to be met.
    ///
    /// `muscles: [MuscleReadiness]` below is the same PR2 compatibility
    /// shape status() takes — see its own comment. Kept as-is here on
    /// purpose: this function hands `muscles` straight to
    /// bestStrengthPattern, which needs recentSets (MEV/MAV/MRV) that
    /// TwinPhysiology.muscleFatigue alone can't provide.
    static func balancedDecision(
        runs: Int, targetRuns: Int,
        strength: Int, targetStrength: Int,
        quality: Int, targetQuality: Int,
        daysSinceStrength: Double,
        daysSinceSwim: Double = 14, daysSinceBike: Double = 14,
        swimDeficit: Int = 0, bikeDeficit: Int = 0,
        // Real weekly dose deficit in minutes — "you're N minutes short of
        // this week's swim/bike/brick target" — scored alongside the
        // session-count deficit above (which still matters for technique
        // frequency) instead of replacing it: a session count alone let
        // "two 35-minute rides" read as a covered week even when the real
        // dose wasn't there.
        swimMinutesDeficit: Double = 0, bikeMinutesDeficit: Double = 0, brickMinutesDeficit: Double = 0,
        hoursSinceLongSwim: Double? = nil, hoursSinceLongBike: Double? = nil,
        hoursSinceLong: Double?, hoursSinceQuality: Double?,
        // Days since a named, tracked lift (bench press, sentadilla) was
        // actually trained — independent of daysSinceStrength, which only
        // knows "some strength happened". A "Mantenimiento"-priority lift
        // goal has the lowest goalFocus weight by design (it shouldn't
        // outcompete a Principal goal for *which category* wins the day),
        // but once a strength day IS warranted, this is what stops an
        // unrelated pattern from quietly satisfying the quota while the
        // actual tracked lift never gets touched — "mantener" a 1RM needs
        // that lift trained, not just any strength.
        trackedLiftDaysSince: Double? = nil,
        // The polarized/pyramidal target (RunningPerformanceEngine.
        // hardIntensityTarget) was computed and shown on the Rendimiento
        // tab already, but nothing in session *selection* ever read it —
        // a real 80/20-busting week of hard running couldn't stop this
        // gate from proposing yet another quality session. Optional and
        // defaults to never gating (nil), matching every other real-data
        // gate here (e.g. effectiveLegReadiness's own honest fallback).
        recentHardPercentage: Double? = nil,
        // Computed by the caller via legSensitiveRunLikelyTomorrow — this
        // function only needs the yes/no answer to keep it from having to
        // know about hoursSinceQuality/hoursSinceLong/goalFocus twice.
        // Only ever reaches bestStrengthPattern through this fallback
        // branch's own strength-pattern text below.
        avoidLegsTomorrow: Bool = false,
        lateWeek: Bool, readiness: Int, muscles: [MuscleReadiness],
        block: TrainingBlock? = nil, goalFocus: GoalTrainingFocus
    ) -> (kind: PlannedSessionKind, rationale: String) {
        struct Candidate {
            let kind: PlannedSessionKind
            let score: Double
        }

        let runDeficit = max(0, targetRuns - runs)
        let strengthDeficit = max(0, targetStrength - strength)
        let qualityDeficit = max(0, targetQuality - quality)
        let legReadiness = average(muscles.filter {
            ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"].contains($0.name)
        }.map(\.readiness))
        let effectiveLegReadiness = legReadiness == 0 ? 50 : legReadiness
        let legPenalty = max(0, 75 - effectiveLegReadiness) * 1.35
        let readinessAdjustment = Double(readiness - 65) * 0.15
        var candidates: [Candidate] = []

        // trackedLiftDaysSince deliberately never resets within weekAhead's
        // forward simulation (ForwardState.apply — a generic .strength day
        // can't tell the model which specific lift it addressed, so it
        // can't invent that resolution). That's correct for a single real
        // "what should I do today" call, but it used to also sit in this
        // gate's OR — which made a genuinely stale tracked lift reopen
        // the candidate on literally every simulated day of the week, long
        // after that week's own strength quota (which the targetStrength
        // floor above already sizes to cover both tracked lifts' MED) had
        // been met — the concrete cause of a week-ahead forecast collapsing
        // to strength every day with no running at all. The count-based
        // deficit is now the sufficient gate; trackedLiftDaysSince still
        // shapes the score (and, via TwinEngine, which pattern gets named)
        // whenever strength is already a candidate through the two
        // self-correcting signals below.
        if targetStrength > 0 && (strengthDeficit > 0 || daysSinceStrength >= 8) {
            let overdue = max(0, daysSinceStrength - 6)
            var score = 30.0 + goalFocus.strength * 34 + Double(strengthDeficit) * 16 + min(36, overdue * 4) + readinessAdjustment
            if daysSinceStrength >= 10 { score += 12 }
            // A tracked lift going stale still sharpens the ranking on a day
            // strength is already in play, even if some OTHER strength
            // pattern happened recently enough that daysSinceStrength alone
            // wouldn't have flagged anything.
            if let trackedLiftDaysSince, trackedLiftDaysSince >= 10 {
                score += min(30, (trackedLiftDaysSince - 10) * 2 + 14)
            }
            // Fatigued legs do not prevent maintaining torso/core.
            if effectiveLegReadiness < 58 { score += 8 }
            candidates.append(Candidate(kind: .strength, score: score))
        }

        // Kept exactly as before (including the runDeficit term) for all
        // three run-type candidates — being generally behind on running
        // volume still makes any of them more attractive, that scoring
        // logic wasn't the bug. What changes below is only the *gating*:
        // quality and long run used to live inside `if runDeficit > 0`,
        // which meant hitting the raw weekly run-count target with nothing
        // but easy runs permanently locked both out for the rest of that
        // week — qualityDeficit/lateWeek could stay true the whole time and
        // still never get proposed once runDeficit reached 0. A real week
        // needs the right mix of session types, not just enough total runs
        // logged, so each now has its own independent gate.
        let baseRunScore = 28.0 + goalFocus.running * 34 + Double(runDeficit) * 8 - legPenalty + readinessAdjustment
        if runDeficit > 0 {
            candidates.append(Candidate(kind: .easyRun, score: baseRunScore))
        }

        // Closes the loop between the polarized target this app already
        // computes (RunningPerformanceEngine.hardIntensityTarget) and what
        // it actually proposes: once real recent hard% has already pushed
        // past this phase's own upper bound, another quality session would
        // only push it further out of range — the deficit in *session
        // count* stops being the thing to fix once intensity *distribution*
        // is already the problem.
        let alreadyOverHardTarget: Bool = {
            guard let recentHardPercentage, let block else { return false }
            return recentHardPercentage > RunningPerformanceEngine.hardIntensityTarget(for: block).upperBound
        }()
        if qualityDeficit > 0,
           (hoursSinceQuality.map { $0 >= 72 } ?? true),
           effectiveLegReadiness >= 62,
           !alreadyOverHardTarget {
            candidates.append(Candidate(kind: .qualityRun,
                score: baseRunScore + 8 + Double(qualityDeficit) * 6))
        }

        if goalFocus.running > 0.05, lateWeek, effectiveLegReadiness >= 62,
           (hoursSinceLong.map { $0 >= 96 } ?? true) {
            let longRunSpacing = min(10, (hoursSinceLong ?? 168) / 24)
            candidates.append(Candidate(kind: .longRun,
                score: baseRunScore + 7 + longRunSpacing))
        }

        // Hybrid work is a distinct adaptation for goals such as HYROX. It only
        // enters the competition when that goal has meaningful current weight.
        if goalFocus.hybrid >= 0.22, readiness >= 65, effectiveLegReadiness >= 62,
           (hoursSinceQuality.map { $0 >= 48 } ?? true) {
            let incomplete = Double(runDeficit + strengthDeficit) * 3
            candidates.append(Candidate(kind: .hybrid,
                score: 28 + goalFocus.hybrid * 42 + incomplete - legPenalty * 0.6 + readinessAdjustment))
        }

        // Triathlon/Ironman's swim and bike are distinct adaptations nothing
        // else in the plan builds — like hybrid above, they only enter the
        // competition once that goal carries meaningful weight. Each scores
        // on two independent signals, same treatment strength gets above:
        // how overdue it is (days since the last one) AND how far behind
        // its own weekly budget it is (swimDeficit/bikeDeficit, status()'s
        // targetSwim/targetBike minus what's already been done this week)
        // — "muchos días sin nadar" alone is a trigger, not a dose; the
        // deficit term is the actual weekly dose catching up.
        if goalFocus.triathlon >= 0.15, readiness >= 60 {
            let swimOverdue = max(0, daysSinceSwim - 2)
            let bikeOverdue = max(0, daysSinceBike - 2)
            // A long swim/bike earns the same kind of spacing a long run
            // does — gentler window (24h vs running's 36h) since these are
            // generally lower-impact, but still real accumulated fatigue.
            // Minutes-deficit term capped at the same ~30-point scale the
            // other urgency terms already use — the actual "dosis, no
            // sesiones" fix: a real 80+ minute weekly shortfall now moves
            // the decision on its own, not just how many days it's been.
            let swimDoseUrgency = min(30, swimMinutesDeficit * 0.35)
            let bikeDoseUrgency = min(30, bikeMinutesDeficit * 0.35)
            if hoursSinceLongSwim.map({ $0 >= 24 }) ?? true {
                candidates.append(Candidate(kind: .swim,
                    score: 24 + goalFocus.triathlon * 30 + min(24, swimOverdue * 5) + Double(swimDeficit) * 6 + swimDoseUrgency + readinessAdjustment))
            }
            if effectiveLegReadiness >= 55, hoursSinceLongBike.map({ $0 >= 24 }) ?? true {
                candidates.append(Candidate(kind: .bike,
                    score: 24 + goalFocus.triathlon * 30 + min(24, bikeOverdue * 5) + Double(bikeDeficit) * 6 + bikeDoseUrgency - legPenalty * 0.4 + readinessAdjustment))
            }
            // Brick is the specific "run on dead legs" stimulus a triathlon
            // needs and nothing else provides — only worth proposing once
            // the block is actually building toward or tapering for the
            // race (base doesn't need race-specific fatigue yet), and only
            // when legs and readiness can absorb a bike immediately
            // followed by a run.
            if let block, [.buildSpecific, .taper].contains(block.phase),
               readiness >= 68, effectiveLegReadiness >= 65,
               (hoursSinceQuality.map { $0 >= 48 } ?? true) {
                candidates.append(Candidate(kind: .brick,
                    score: 30 + goalFocus.triathlon * 38 + min(30, brickMinutesDeficit * 0.35) - legPenalty * 0.6 + readinessAdjustment))
            }
        }

        // This is "nothing is mandatory today", not "you must rest" — every
        // candidate above only enters the running once its own deficit/
        // overdue/spacing condition is true, so reaching here means every
        // weekly target is already met and no discipline is overdue.
        // Readiness is already guaranteed >=58 by the hard gates that run
        // before balancedDecision is ever called (status()'s own
        // readiness<58 check, and weekAhead's equivalent) — so a real
        // coach wouldn't stop outright here either: they'd keep some light,
        // purposeful rhythm going rather than default to enforced rest for
        // however many consecutive days quotas happen to stay met, which
        // is exactly what previously made an entire week of real
        // availability read as "descanso obligatorio toda la semana".
        // Only genuinely fatigued legs (real muscle data saying so, not
        // just the neutral 50 fallback weekAhead's own muscle-blind
        // simulation always uses) still fall through to true recovery.
        guard let winner = candidates.max(by: { $0.score < $1.score }) else {
            let rationale = "Ya cumples los mínimos de esta semana y ninguna disciplina está atrasada — hoy no hay nada obligatorio."
            // Prefers whichever discipline has actually gone longest without
            // a stimulus, not a fixed goal-weight comparison that would
            // otherwise pick the same one every single day this fallback
            // fires — a real week rotates, it doesn't repeat. trackedLiftDaysSince
            // is deliberately excluded here for the same reason it was pulled
            // from the main gate above: reaching this branch already means
            // strength's own fair-trimmed weekly target was met without it
            // (strengthDeficit <= 0, daysSinceStrength < 8) — but that signal
            // never resets within the forward simulation, so keeping it here
            // let it re-win this "nothing mandatory" slot on every remaining
            // day of the week regardless, silently consuming every leftover
            // slot that should have been free to rotate to running — the
            // second half of a week collapsing to all-strength/zero-running
            // even after the main-gate fix. daysSinceStrength alone (which
            // does reset) is enough to still rotate back to strength once a
            // real gap reopens.
            if effectiveLegReadiness >= 45, daysSinceStrength >= 4, goalFocus.strength > 0 {
                return (.strength, rationale + " Esto es una sesión de mantenimiento ligera y opcional, no una sesión obligatoria.")
            }
            if effectiveLegReadiness >= 45, goalFocus.running > 0 {
                return (.easyRun, rationale + " Esto es volumen aeróbico ligero y opcional, no una sesión obligatoria.")
            }
            return (.recovery, rationale + " Recuperar es la opción por defecto mientras las piernas siguen en ventana de recuperación.")
        }

        let strengthAge = Int(daysSinceStrength.rounded(.down))
        switch winner.kind {
        case .strength:
            let pattern = bestStrengthPattern(muscles, avoidLegs: avoidLegsTomorrow)
            return (.strength, "Para \(goalFocus.leadingGoal), la necesidad de fuerza y sus \(strengthAge) días sin estímulo superan hoy a las alternativas. Prioriza \(pattern) con margen.")
        case .longRun:
            return (.longRun, "La tirada larga es hoy el estímulo con más transferencia a \(goalFocus.leadingGoal). Las piernas y la separación desde la anterior permiten asumirla sin vulnerar los mínimos de otras capacidades.")
        case .qualityRun:
            return (.qualityRun, "La calidad de carrera ofrece hoy la mayor transferencia a \(goalFocus.leadingGoal), con separación y disponibilidad suficientes.")
        case .easyRun:
            if effectiveLegReadiness < 62 {
                return (.easyRun, "Falta volumen aeróbico, pero la disponibilidad de piernas limita la sesión a carrera realmente suave y recortable.")
            }
            return (.easyRun, "El volumen aeróbico aporta hoy la mejor relación entre transferencia a \(goalFocus.leadingGoal), fatiga y continuidad del resto del plan.")
        case .hybrid:
            return (.hybrid, "El trabajo combinado de carrera y estaciones es ahora el estímulo con más transferencia a \(goalFocus.leadingGoal), sin justificar una sesión máxima.")
        case .swim:
            return (.swim, "La natación lleva \(Int(daysSinceSwim.rounded(.down))) días sin estímulo específico; \(goalFocus.leadingGoal) no se construye sin ese volumen.")
        case .bike:
            return (.bike, "El ciclismo lleva \(Int(daysSinceBike.rounded(.down))) días sin estímulo específico y hoy ofrece más transferencia a \(goalFocus.leadingGoal) que otra sesión de carrera.")
        case .brick:
            return (.brick, "Un brick bici-carrera entrena piernas cansadas justo antes de correr — la demanda específica de \(goalFocus.leadingGoal) que ninguna otra sesión cubre.")
        default:
            return (.recovery, "Recuperar ofrece hoy el mejor equilibrio entre adaptación y continuidad.")
        }
    }

    /// Converts the complete goal portfolio into current adaptation priorities.
    /// Priority expresses importance; proximity increases specificity as an event
    /// approaches. Maintenance goals keep weight but cannot displace a primary
    /// event unless their capacity has been neglected.
    static func goalFocus(for profile: AthletePlanProfile, on date: Date) -> GoalTrainingFocus {
        var running = 0.0
        var strength = 0.0
        var hybrid = 0.0
        var triathlon = 0.0
        var leader: (name: String, score: Double)?
        let calendar = Calendar.current

        for goal in profile.goals where goal.isActive {
            if let eventDate = goal.date, eventDate < calendar.startOfDay(for: date) { continue }
            let priority = Double(goal.priority.weight)
            let proximity: Double
            if let eventDate = goal.date {
                let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: eventDate).day ?? 365)
                proximity = days <= 14 ? 1.65 : days <= 42 ? 1.40 : days <= 84 ? 1.18 : 1.0
            } else {
                proximity = 1.0
            }
            let score = priority * proximity
            if leader == nil || score > leader!.score { leader = (goal.title, score) }
            switch goal.kind {
            case .marathon, .halfMarathon, .fiveK, .tenK:
                running += score
            case .benchPress, .squat, .deadlift, .hypertrophy:
                strength += score
            case .hyrox:
                running += score * 0.35
                strength += score * 0.35
                hybrid += score * 0.30
            case .triathlon, .ironman:
                // The run leg is still real running (shares that adaptation),
                // and some functional strength keeps injury risk down across
                // three disciplines — but the majority of the demand is the
                // swim/bike volume nothing else in the plan builds.
                running += score * 0.30
                strength += score * 0.15
                triathlon += score * 0.55
            case .custom:
                // Unknown challenges remain balanced until the product collects
                // their physical demands explicitly.
                running += score * 0.25
                strength += score * 0.25
                hybrid += score * 0.50
            }
        }

        let total = running + strength + hybrid + triathlon
        guard total > 0 else {
            return GoalTrainingFocus(running: 0.4, strength: 0.4, hybrid: 0.2, triathlon: 0, leadingGoal: "tu desarrollo híbrido")
        }
        return GoalTrainingFocus(running: running / total, strength: strength / total, hybrid: hybrid / total,
                                 triathlon: triathlon / total, leadingGoal: leader?.name ?? "tus objetivos")
    }

    private static func legsFatigued(_ muscles: [MuscleReadiness]) -> Bool {
        let legs = muscles.filter { ["Cuádriceps", "Glúteos", "Isquios", "Gemelos"].contains($0.name) }
        return average(legs.map(\.readiness)) < 58
    }

    // Shared with DecisionSimulatorEngine so "Intervalos"/"Tirada larga" there
    // classify sessions with the exact same rule the weekly plan already uses —
    // one definition of what counts as a quality run or a long run, not two.
    static func isQualityRun(_ workout: HealthWorkout) -> Bool {
        workout.durationMinutes <= 50 && (workout.calories ?? 0) / max(workout.durationMinutes, 1) >= 10
    }
    // Not private (nor a second definition): TwinPhysiology.derive reuses
    // this exact same rule to split real history into aerobic/strength
    // channels, instead of guessing "Fuerza" activities a second time.
    nonisolated static func isStrengthWorkout(_ workout: HealthWorkout) -> Bool {
        workout.activity == "Fuerza" || workout.activity == "Fuerza funcional"
    }
    static func isLongRun(_ workout: HealthWorkout) -> Bool {
        workout.activity == "Carrera" && ((workout.distanceKilometers ?? 0) >= 10 || workout.durationMinutes >= 60)
    }
    // Same "suave/calidad/larga" classification running already has,
    // extended to the other two triathlon disciplines — a long bike/swim
    // deserves its own recovery spacing, the same way a long run does.
    static func isLongBike(_ workout: HealthWorkout) -> Bool {
        workout.activity == "Ciclismo" && ((workout.distanceKilometers ?? 0) >= 60 || workout.durationMinutes >= 120)
    }
    static func isLongSwim(_ workout: HealthWorkout) -> Bool {
        workout.activity == "Natación" && ((workout.distanceKilometers ?? 0) >= 3 || workout.durationMinutes >= 75)
    }
    private static func midpoint(_ range: ClosedRange<Int>) -> Int { Int(ceil(Double(range.lowerBound + range.upperBound) / 2)) }
    private static func average(_ values: [Int]) -> Double { values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count) }
    // Not private: WorkoutPlanner needs the actual TrainingGoal (kind,
    // resolvedTriathlonDistance, courseDetails, hyroxDivision) to build a
    // race-day protocol, not just the PlannedSessionKind that resulted from it.
    static func eventToday(_ date: Date, profile: AthletePlanProfile) -> TrainingGoal? {
        profile.activeGoals.first { goal in goal.date.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false }
    }
    private static func nextEvent(after date: Date, profile: AthletePlanProfile) -> (name: String, date: Date)? {
        profile.nextEvent(after: date).flatMap { goal in goal.date.map { (goal.title, $0) } }
    }
}
