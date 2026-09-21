import SwiftUI

/// Lectura visual, no interactiva, del estímulo de una sesión de fuerza.
/// La figura no intenta diagnosticar daño ni recuperación: colorea únicamente
/// las series efectivas ya calculadas por `ImportedWorkout.effectiveMuscleSets`.
struct SessionMuscleHeatmapView: View {
    let stimulus: [String: Double]

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Image("BodyComposition")
                    .resizable()
                    .scaledToFit()
                    .saturation(0)
                    .opacity(0.34)
                    .accessibilityHidden(true)

                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack {
                        // Pecho y deltoides
                        spot("Pecho", x: 0.43, y: 0.285, width: 0.145, height: 0.095, size: size)
                        spot("Pecho", x: 0.57, y: 0.285, width: 0.145, height: 0.095, size: size)
                        spot("Hombros", x: 0.285, y: 0.25, width: 0.105, height: 0.075, size: size)
                        spot("Hombros", x: 0.715, y: 0.25, width: 0.105, height: 0.075, size: size)

                        // Brazos: se mantienen separados porque el motor sí
                        // distingue trabajo directo de bíceps y tríceps.
                        spot("Bíceps", x: 0.255, y: 0.355, width: 0.075, height: 0.12, size: size)
                        spot("Bíceps", x: 0.745, y: 0.355, width: 0.075, height: 0.12, size: size)
                        spot("Tríceps", x: 0.205, y: 0.36, width: 0.055, height: 0.135, size: size)
                        spot("Tríceps", x: 0.795, y: 0.36, width: 0.055, height: 0.135, size: size)

                        // Tronco. Espalda se representa en dorsales laterales;
                        // las cifras inferiores conservan el detalle completo.
                        spot("Espalda", x: 0.34, y: 0.405, width: 0.09, height: 0.17, size: size)
                        spot("Espalda", x: 0.66, y: 0.405, width: 0.09, height: 0.17, size: size)
                        spot("Core", x: 0.50, y: 0.41, width: 0.15, height: 0.18, size: size)

                        // Tren inferior
                        spot("Cuádriceps", x: 0.405, y: 0.61, width: 0.13, height: 0.20, size: size)
                        spot("Cuádriceps", x: 0.595, y: 0.61, width: 0.13, height: 0.20, size: size)
                        spot("Glúteos", x: 0.50, y: 0.535, width: 0.22, height: 0.10, size: size)
                        spot("Isquios", x: 0.355, y: 0.655, width: 0.075, height: 0.16, size: size)
                        spot("Isquios", x: 0.645, y: 0.655, width: 0.075, height: 0.16, size: size)
                        spot("Gemelos", x: 0.40, y: 0.80, width: 0.075, height: 0.16, size: size)
                        spot("Gemelos", x: 0.60, y: 0.80, width: 0.075, height: 0.16, size: size)
                    }
                }
            }
            .frame(maxWidth: 230, minHeight: 285, maxHeight: 285)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mapa de estímulo muscular de la sesión")
            .accessibilityValue(accessibilitySummary)

            HStack(spacing: 12) {
                legend("Sin carga", color: inactiveColor)
                legend("Ligero", color: lightColor)
                legend("Moderado", color: moderateColor)
                legend("Alto", color: highColor)
                legend("Principal", color: primaryColor)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func spot(_ muscle: String, x: CGFloat, y: CGFloat,
                      width: CGFloat, height: CGFloat, size: CGSize) -> some View {
        Capsule()
            .fill(color(for: stimulus[muscle, default: 0]))
            .frame(width: size.width * width, height: size.height * height)
            .position(x: size.width * x, y: size.height * y)
            .shadow(color: color(for: stimulus[muscle, default: 0]).opacity(0.65), radius: 7)
            .blendMode(.plusLighter)
    }

    private func legend(_ label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Umbrales absolutos: una sesión diminuta no pinta de rojo un músculo
    /// sólo por ser el mayor dentro de esa sesión.
    private func color(for effectiveSets: Double) -> Color {
        switch effectiveSets {
        case ...0.05: inactiveColor
        case ..<1.5: lightColor
        case ..<3.0: moderateColor
        case ..<5.0: highColor
        default: primaryColor
        }
    }

    private var accessibilitySummary: String {
        let active = stimulus.filter { $0.value > 0.05 }.sorted { $0.value > $1.value }
        guard !active.isEmpty else { return "Sin estímulo muscular registrado" }
        return active.map { "\($0.key), \($0.value.formatted(.number.precision(.fractionLength(0...1)))) series efectivas" }
            .joined(separator: ". ")
    }

    private var inactiveColor: Color { Color(red: 0.12, green: 0.60, blue: 0.82).opacity(0.72) }
    private var lightColor: Color { Color(red: 0.43, green: 0.80, blue: 0.38) }
    private var moderateColor: Color { Color(red: 0.92, green: 0.78, blue: 0.24) }
    private var highColor: Color { Color(red: 0.96, green: 0.52, blue: 0.16) }
    private var primaryColor: Color { Color(red: 0.88, green: 0.20, blue: 0.18) }
}
