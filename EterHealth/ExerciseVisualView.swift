import SwiftUI

/// Compact anatomical cue. It deliberately shows the loaded regions rather
/// than pretending to teach technique with an inaccurate generic animation.
struct ExerciseVisualView: View {
    let exercise: String
    var size: CGFloat = 42

    private var muscles: Set<String> { Set(MuscleMap.groups(for: exercise)) }
    private let active = Color(red: 0.16, green: 0.56, blue: 0.39)
    private let inactive = Color.primary.opacity(0.18)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color.primary.opacity(0.08))
            VStack(spacing: size * 0.035) {
                Circle().fill(inactive).frame(width: size * 0.18, height: size * 0.18)
                HStack(spacing: size * 0.035) {
                    limb(upperActive, width: 0.10, height: 0.36).rotationEffect(.degrees(10))
                    Capsule().fill(torsoActive ? active : inactive).frame(width: size * 0.25, height: size * 0.34)
                    limb(upperActive, width: 0.10, height: 0.36).rotationEffect(.degrees(-10))
                }
                HStack(spacing: size * 0.07) {
                    limb(lowerActive, width: 0.11, height: 0.30).rotationEffect(.degrees(4))
                    limb(lowerActive, width: 0.11, height: 0.30).rotationEffect(.degrees(-4))
                }
            }
            .frame(width: size * 0.72, height: size * 0.84)
        }
        .frame(width: size, height: size * 1.18)
        .accessibilityLabel("Musculatura principal: \(MuscleMap.groups(for: exercise).joined(separator: ", "))")
    }

    private func limb(_ highlighted: Bool, width: CGFloat, height: CGFloat) -> some View {
        Capsule().fill(highlighted ? active : inactive).frame(width: size * width, height: size * height)
    }

    private var upperActive: Bool {
        !muscles.intersection(["Pecho", "Espalda", "Hombros", "Bíceps", "Tríceps"]).isEmpty
    }

    private var torsoActive: Bool {
        !muscles.intersection(["Pecho", "Espalda", "Core"]).isEmpty
    }

    private var lowerActive: Bool {
        !muscles.intersection(["Cuádriceps", "Glúteos", "Isquios", "Gemelos", "Piernas"]).isEmpty
    }
}
