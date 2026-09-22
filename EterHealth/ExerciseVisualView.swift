import SwiftUI

/// Miniatura anatómica de intención: usa el mismo MuscleMap que el motor para
/// enseñar qué pretende cargar el ejercicio. El resumen de sesión, en cambio,
/// muestra el estímulo real después de aplicar series y RIR.
struct ExerciseVisualView: View {
    let exercise: String
    var size: CGFloat = 42

    private var involvement: [String: Double] { MuscleMap.involvement(for: exercise) }

    private var dominantMuscle: String? {
        involvement.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
    }

    private var side: MuscleViewSide {
        guard let dominantMuscle else { return .front }
        return ["Espalda", "Tríceps", "Glúteos", "Isquios", "Gemelos"].contains(dominantMuscle)
            ? .back : .front
    }

    private var imageName: String { side == .front ? "BodyComposition" : "BodyCompositionBack" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(Color.primary.opacity(0.055))

            ZStack {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .saturation(0.10)
                    .contrast(1.08)
                    .brightness(-0.10)
                    .opacity(0.72)
                    .blendMode(side == .front ? .screen : .normal)

                ZStack {
                    ForEach(involvement.keys.sorted(), id: \.self) { muscle in
                        if let weight = involvement[muscle], weight > 0 {
                            AnatomicalMuscleRegion(muscle: muscle, side: side)
                                .fill(targetColor(muscle: muscle, weight: weight).opacity(0.94))
                                .blendMode(.color)
                        }
                    }
                }
                .mask {
                    Image(imageName).resizable().scaledToFit()
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .padding(size * 0.055)
            .drawingGroup()
        }
        .frame(width: size, height: size * 1.18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func targetColor(muscle: String, weight: Double) -> Color {
        if muscle == dominantMuscle {
            return Color(red: 0.94, green: 0.18, blue: 0.16)
        }
        if weight >= 0.5 {
            return Color(red: 1.00, green: 0.46, blue: 0.10)
        }
        return Color(red: 0.95, green: 0.78, blue: 0.18)
    }

    private var accessibilityDescription: String {
        let ordered = involvement.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        guard let first = ordered.first else { return "Sin musculatura objetivo identificada" }
        let secondary = ordered.dropFirst().map(\.key).joined(separator: ", ")
        return secondary.isEmpty
            ? "Músculo objetivo principal: \(first.key)"
            : "Músculo objetivo principal: \(first.key). Secundarios: \(secondary)"
    }
}
