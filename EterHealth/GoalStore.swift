import Foundation

enum TrainingGoalKind: String, Codable, CaseIterable, Identifiable {
    case marathon = "Maratón"
    case halfMarathon = "Media maratón"
    case triathlon = "Triatlón"
    case ironman = "Ironman"
    case hyrox = "HYROX"
    case fiveK = "5 km"
    case tenK = "10 km"
    case benchPress = "Press banca"
    case squat = "Sentadilla"
    case deadlift = "Peso muerto"
    // Its own kind (not folded into benchPress/squat/deadlift) because it
    // isn't about a single tracked lift's number — it's a general muscle-
    // growth goal, sized by weekly frequency per muscle group rather than
    // a 1RM.
    case hypertrophy = "Hipertrofia"
    case custom = "Otro reto"
    var id: String { rawValue }
    var usesDate: Bool {
        switch self {
        case .marathon, .halfMarathon, .fiveK, .tenK, .hyrox, .triathlon, .ironman, .custom: return true
        case .benchPress, .squat, .deadlift, .hypertrophy: return false
        }
    }
    var defaultUnit: String {
        switch self {
        case .marathon, .halfMarathon, .fiveK, .tenK: return "min"
        case .hyrox, .triathlon, .ironman: return "min"
        case .benchPress, .squat, .deadlift: return "kg"
        case .hypertrophy, .custom: return ""
        }
    }
    // Only meaningful for running goals — nil for HYROX and triathlon/Ironman
    // (multi-discipline, no single continuous distance), strength, and custom
    // challenges éter has no physical model for. WorkoutPlanner scales long-
    // run/easy-run volume bands off this instead of using one fixed band for
    // every running distance regardless of how far the actual race is.
    // (WorkoutPlanner separately resolves the run *leg* of a triathlon/Ironman
    // goal via TrainingGoal.resolvedTriathlonDistance — a half-Ironman's
    // 21.1 km run leg should scale that band exactly like a standalone half
    // marathon would, which this property alone can't express.)
    var targetKilometers: Double? {
        switch self {
        case .marathon: return 42.195
        case .halfMarathon: return 21.0975
        case .tenK: return 10
        case .fiveK: return 5
        case .hyrox, .triathlon, .ironman, .benchPress, .squat, .deadlift, .hypertrophy, .custom: return nil
        }
    }
}

// Sprint/Olympic/Half (70.3)/Full (140.6, "Ironman distance") — the four
// standard triathlon distances, each with its own real swim/bike/run split.
// `.triathlon` goals let the athlete pick any of the four; `.ironman` always
// resolves to `.full` (see TrainingGoal.resolvedTriathlonDistance) since
// "Ironman" as a challenge name specifically means the full iron distance.
enum TriathlonDistance: String, Codable, CaseIterable, Identifiable {
    case sprint = "Sprint"
    case olympic = "Olímpico"
    case half = "Half (70.3)"
    case full = "Ironman (140.6)"
    var id: String { rawValue }
    var swimKilometers: Double {
        switch self { case .sprint: return 0.75; case .olympic: return 1.5; case .half: return 1.9; case .full: return 3.8 }
    }
    var bikeKilometers: Double {
        switch self { case .sprint: return 20; case .olympic: return 40; case .half: return 90; case .full: return 180 }
    }
    var runKilometers: Double {
        switch self { case .sprint: return 5; case .olympic: return 10; case .half: return 21.0975; case .full: return 42.195 }
    }
}

enum GoalPriority: String, Codable, CaseIterable, Identifiable {
    case primary = "Principal"
    case secondary = "Secundario"
    case maintenance = "Mantenimiento"
    var id: String { rawValue }
    var weight: Int { self == .primary ? 3 : self == .secondary ? 2 : 1 }
}

enum HyroxDivision: String, Codable, CaseIterable, Identifiable {
    case open = "Individual Open"
    case pro = "Individual Pro"
    case doubles = "Doubles"
    var id: String { rawValue }
}

enum WaterType: String, Codable, CaseIterable, Identifiable {
    case pool = "Piscina"
    case lake = "Lago"
    case sea = "Mar"
    case river = "Río"
    var id: String { rawValue }
}

// Real event-day specifics for a triathlon/Ironman (or any distance goal
// with a known course) — entered by hand, same philosophy as the lactate-
// test zone boundaries above: éter never guesses a course profile or race-
// day weather, but if the athlete knows theirs, using it beats pretending
// every race is flat, wetsuit-legal, and 20°C. Every field optional and
// nil by default — an unset course behaves exactly as it did before this
// existed.
struct EventCourseDetails: Codable, Equatable {
    var courseElevationMeters: Double? = nil
    var waterType: WaterType? = nil
    var expectedWaterTemperatureCelsius: Double? = nil
    var expectedAirTemperatureCelsius: Double? = nil
    var transitionNotes: String = ""

    var isEmpty: Bool {
        courseElevationMeters == nil && waterType == nil && expectedWaterTemperatureCelsius == nil
            && expectedAirTemperatureCelsius == nil && transitionNotes.isEmpty
    }

    // World Triathlon / USAT wetsuits are legal (and give a real ~3-6%
    // swim-speed advantage from added buoyancy) below roughly 24.5°C water
    // temperature — above that they're typically restricted or banned.
    // nil when the temperature itself isn't known, never assumed.
    var wetsuitLikelyLegal: Bool? {
        guard let expectedWaterTemperatureCelsius else { return nil }
        return expectedWaterTemperatureCelsius < 24.5
    }
}

struct TrainingGoal: Codable, Identifiable {
    var id: UUID
    var kind: TrainingGoalKind
    var title: String
    var date: Date?
    var targetValue: Double?
    var unit: String
    var priority: GoalPriority
    var isActive: Bool
    var hyroxDivision: HyroxDivision? = nil
    var triathlonDistance: TriathlonDistance? = nil
    var courseDetails: EventCourseDetails? = nil

    // `.ironman` always means the full iron distance regardless of what's
    // stored (a saved profile might predate this field); `.triathlon` lets
    // the athlete pick, defaulting to Olympic — the most common "triatlón"
    // distance — rather than guessing at the most demanding one. nil for
    // every other kind.
    var resolvedTriathlonDistance: TriathlonDistance? {
        switch kind {
        case .ironman: return .full
        case .triathlon: return triathlonDistance ?? .olympic
        default: return nil
        }
    }

    var displayTarget: String? {
        guard let targetValue else { return nil }
        if unit == "min" {
            let totalSeconds = Int((targetValue * 60).rounded())
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
        return "\(targetValue.formatted(.number.precision(.fractionLength(targetValue.rounded() == targetValue ? 0 : 1)))) \(unit)"
    }
}

// The 4 bpm cut points between Z1/Z2, Z2/Z3, Z3/Z4 and Z4/Z5, entered by hand
// from a real lactate test report — whatever boundaries the lab gives you,
// typed in directly, rather than éter guessing a formula for a protocol it
// has never seen. Once %HRmax-based estimation (Tanaka or a configured max)
// is the best éter can do; a lactate test's own zone boundaries beat any
// formula because they're measured from your actual blood lactate curve.
struct HeartRateZoneBoundaries: Codable, Equatable {
    var z1z2: Int
    var z2z3: Int
    var z3z4: Int
    var z4z5: Int
}

// The choice TrainingScenarioCardView's three simulated futures used to
// have no connection to: which of them you're actually trying to follow.
// ratioCeiling is the acute:chronic load ratio (PerformanceEngine's own
// loadRatio — the same Gabbett-style ACWR figure the rest of this app
// already reads) each pace tolerates before the plan proactively hands
// you a recovery day instead of another session.
//
// Óptimo equals the app's existing, already-validated behavior exactly
// (1.55, PerformanceEngine.loadGuidance's own "sobrecarga" line) —
// choosing it changes nothing for anyone who never touches this setting.
// Conservador stops at the existing "absorb" threshold (1.30) without
// ever entering it, trading progression speed for more rest days.
//
// Agresivo is the one pace that genuinely crosses the 1.55 line — the
// literature this app already cites elsewhere (Gabbett 2016, Blanch &
// Gabbett 2016: acute:chronic ratios above ~1.5 carry meaningfully
// elevated injury risk, climbing further as the ratio keeps rising) puts
// anything past 1.55 in real elevated-risk territory, not a grey area.
// 1.80 is a deliberately wide, capped ceiling INSIDE that same
// literature's "high risk" band — not a second validated number, just a
// bound so this stays "deliberately elevated risk, chosen with eyes
// open" rather than "unbounded into the rarely-recommended >2.0 range."
// Every real day this pace's extra margin actually gets used (ratio
// 1.55–1.80) must say so explicitly in its own rationale — see
// TrainingPlanEngine.status()/weekAhead's aggressive-risk-disclosure
// step — and the UI (TrainingScenarioCardView, GoalEditorView) requires
// an explicit confirmation before switching TO this pace. Never silent.
enum ProgressionPace: String, Codable, CaseIterable, Identifiable {
    case conservative = "Conservador"
    case optimal = "Óptimo"
    case aggressive = "Agresivo"
    var id: String { rawValue }

    var ratioCeiling: Double {
        switch self {
        case .conservative: return 1.30
        case .optimal: return 1.55
        case .aggressive: return 1.80
        }
    }

    // The literature's own danger-zone entry point — where Agresivo's
    // extra margin (over Óptimo) actually starts being used, and where
    // the explicit risk disclosure kicks in.
    static let elevatedRiskRatio = 1.55

    var explanation: String {
        switch self {
        case .conservative: return "Descansa en cuanto la carga se acerca a la zona de absorber (1.30) — más días de recuperación, progresión más lenta y con más margen de seguridad. Ritmo de crecimiento simulado en \"Tres futuros\": ~4%/semana."
        case .optimal: return "El comportamiento por defecto de siempre: usa margen hasta el límite de sobrecarga establecido (1.55, Gabbett et al.) antes de pedir descanso. Ritmo de crecimiento simulado: ~9%/semana."
        case .aggressive: return "Tolera carga hasta 1.80 — por encima de 1.55 ya es zona de riesgo elevado de lesión según la evidencia (Gabbett 2016; Blanch & Gabbett 2016), y esta app te lo permite con aviso explícito cada vez que ocurre, no en silencio. Ritmo de crecimiento simulado: ~15%/semana."
        }
    }
}

struct AthletePlanProfile: Codable {
    var goals: [TrainingGoal]
    var gymAvailable: Bool
    var trainingDaysPerWeek: Int
    var preferredLongRunWeekday: Int
    var maximumHeartRate: Int?
    // Optional so profiles saved before this field existed still decode (missing
    // key -> nil). Only used today for BiologicalAgeEngine's chronological-age
    // input; GoalStore.init backfills it from angelDefault for existing saves.
    var birthDate: Date? = nil
    // Optional, no backfill needed (nil is the correct default for everyone
    // until they actually get a lactate test done). Takes priority over
    // maximumHeartRate in HealthStore.loadHeartRateZones — see there.
    var manualHeartRateZones: HeartRateZoneBoundaries? = nil
    // Optional (never a non-optional field with a default — Swift's
    // synthesized Decodable ignores property initializers for anything
    // that isn't Optional, so a plain `= .optimal` here would throw on
    // every profile saved before this field existed, and GoalStore.init's
    // `try?` would silently replace the whole real profile with
    // .angelDefault). Read via effectiveProgressionPace, never directly.
    var progressionPace: ProgressionPace? = nil
    var effectiveProgressionPace: ProgressionPace { progressionPace ?? .optimal }

    static var angelDefault: AthletePlanProfile {
        let calendar = Calendar(identifier: .gregorian)
        func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
        // Confirmado en informes de laboratorio (Axpe).
        let birthDate = calendar.date(from: DateComponents(year: 1983, month: 7, day: 23))!
        return AthletePlanProfile(goals: [
            TrainingGoal(id: UUID(), kind: .halfMarathon, title: "Media maratón", date: date(10, 17), targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .hyrox, title: "HYROX", date: date(10, 31), targetValue: nil, unit: "min", priority: .primary, isActive: true),
            TrainingGoal(id: UUID(), kind: .fiveK, title: "5 km", date: nil, targetValue: 20, unit: "min", priority: .secondary, isActive: true),
            TrainingGoal(id: UUID(), kind: .benchPress, title: "Press banca", date: nil, targetValue: 100, unit: "kg", priority: .maintenance, isActive: true),
            TrainingGoal(id: UUID(), kind: .squat, title: "Sentadilla", date: nil, targetValue: 100, unit: "kg", priority: .maintenance, isActive: true)
        ], gymAvailable: false, trainingDaysPerWeek: 5, preferredLongRunWeekday: 7, maximumHeartRate: nil, birthDate: birthDate)
    }
}

@MainActor
final class GoalStore: ObservableObject {
    static let shared = GoalStore()
    @Published private(set) var profile: AthletePlanProfile

    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("athlete-plan-profile.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storageURL),
           var saved = try? JSONDecoder().decode(AthletePlanProfile.self, from: data) {
            // Backfill birthDate for profiles saved before this field existed.
            if saved.birthDate == nil { saved.birthDate = AthletePlanProfile.angelDefault.birthDate }
            profile = saved
        }
        else { profile = .angelDefault }
    }

    func save(_ profile: AthletePlanProfile) {
        self.profile = profile
        try? JSONEncoder().encode(profile).write(to: Self.storageURL, options: .atomic)
    }

    func restore(_ restored: AthletePlanProfile) {
        // A backup made before birthDate existed would otherwise blank out an
        // already-set one on merge — same backfill as init(), applied here too.
        var restored = restored
        if restored.birthDate == nil { restored.birthDate = AthletePlanProfile.angelDefault.birthDate }
        save(restored)
    }

    // Thin delegates onto AthletePlanProfile's own pure versions below —
    // kept here too since existing UI call sites read them straight off
    // GoalStore.shared. TwinCore engines call the profile's versions
    // directly instead, with the real profile passed in as a parameter.
    var activeGoals: [TrainingGoal] { profile.activeGoals }
    func goal(_ kind: TrainingGoalKind) -> TrainingGoal? { profile.goal(kind) }
    func nextEvent(after date: Date = Date()) -> TrainingGoal? { profile.nextEvent(after: date) }
}

extension AthletePlanProfile {
    var activeGoals: [TrainingGoal] {
        goals.filter(\.isActive).sorted {
            if $0.priority.weight != $1.priority.weight { return $0.priority.weight > $1.priority.weight }
            return ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        }
    }

    func goal(_ kind: TrainingGoalKind) -> TrainingGoal? { activeGoals.first { $0.kind == kind } }
    func nextEvent(after date: Date = Date()) -> TrainingGoal? {
        activeGoals.filter { ($0.date ?? .distantPast) >= Calendar.current.startOfDay(for: date) }
            .min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
}
