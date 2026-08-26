import Foundation

// PR1.5: TwinEngine.assess, TrainingPlanEngine.status/weekAhead and
// PerformanceEngine.balance all used to take the same six values
// (profile/events/reviews/activeInjuries/calibration/personalAnchor) as
// six separate parameters after PR1's injection — every UI call site had
// to repeat the same six labels for whichever of these four it happened
// to call. Bundling them into one value type means a call site builds
// ONE TwinContext from the real stores and reuses it for all four, and a
// function that doesn't need every field (status only reads profile and
// reviews) just ignores the rest instead of not being able to see them.
// Still a plain struct with zero singleton access — TwinCore itself never
// constructs one, only receives it, exactly like the six separate
// parameters it replaces.
struct TwinContext {
    var profile: AthletePlanProfile
    var events: [LifestyleEvent]
    var reviews: [WorkoutReview]
    var activeInjuries: [InjuryRecord]
    var calibration: TwinCalibration
    var personalAnchor: PersonalReadinessAnchor
}
