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

/// Miniatura de una rutina completa. Agrega la implicación de todos sus
/// ejercicios y enseña frontal + posterior porque una sesión puede cargar
/// ambas caras. Usa el mismo render, MuscleMap y máscaras que el resumen.
struct RoutineMuscleVisualView: View {
    let exercises: [RoutineExercise]
    var height: CGFloat = 64

    private var involvement: [String: Double] {
        exercises.reduce(into: [:]) { result, exercise in
            for (muscle, weight) in MuscleMap.involvement(for: exercise.name) {
                result[muscle, default: 0] += weight * Double(max(1, exercise.sets.count))
            }
        }
    }

    private var maximum: Double { involvement.values.max() ?? 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            figure(
                image: "BodyComposition", side: .front,
                muscles: ["Pecho", "Hombros", "Bíceps", "Core", "Cuádriceps"]
            )
            figure(
                image: "BodyCompositionBack", side: .back,
                muscles: ["Espalda", "Hombros", "Tríceps", "Glúteos", "Isquios", "Gemelos"]
            )
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func figure(image: String, side: MuscleViewSide, muscles: [String]) -> some View {
        ZStack {
            Image(image)
                .resizable().scaledToFit()
                .saturation(0.10).contrast(1.08).brightness(-0.10)
                .opacity(0.72)

            ZStack {
                ForEach(muscles, id: \.self) { muscle in
                    if let load = involvement[muscle], load > 0 {
                        AnatomicalMuscleRegion(muscle: muscle, side: side)
                            .fill(color(for: load).opacity(0.94))
                            .blendMode(.color)
                    }
                }
            }
            .mask { Image(image).resizable().scaledToFit() }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .drawingGroup()
    }

    private func color(for load: Double) -> Color {
        let ratio = load / max(0.01, maximum)
        if ratio >= 0.85 { return Color(red: 0.94, green: 0.18, blue: 0.16) }
        if ratio >= 0.50 { return Color(red: 1.00, green: 0.46, blue: 0.10) }
        return Color(red: 0.95, green: 0.78, blue: 0.18)
    }

    private var accessibilityDescription: String {
        let ordered = involvement.sorted { $0.value > $1.value }.map(\.key)
        return ordered.isEmpty
            ? "Rutina sin musculatura identificada"
            : "Rutina para " + ordered.joined(separator: ", ")
    }
}
