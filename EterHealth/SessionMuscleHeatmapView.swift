import SwiftUI

/// Lectura visual, no interactiva, del estímulo de una sesión de fuerza.
/// Conserva el render anatómico de composición corporal y colorea regiones
/// integradas en la figura; no coloca símbolos ni "pegatinas" sobre ella.
struct SessionMuscleHeatmapView: View {
    let stimulus: [String: Double]

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                figure(
                    image: "BodyComposition", side: .front,
                    muscles: ["Pecho", "Hombros", "Bíceps", "Core", "Cuádriceps"],
                    label: "Frontal"
                )
                figure(
                    image: "BodyCompositionBack", side: .back,
                    muscles: ["Espalda", "Hombros", "Tríceps", "Glúteos", "Isquios", "Gemelos"],
                    label: "Posterior"
                )
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mapa frontal y posterior de estímulo muscular de la sesión")
            .accessibilityValue(accessibilitySummary)

            HStack(spacing: 10) {
                legend("Sin carga", color: inactiveColor)
                legend("Ligero", color: lightColor)
                legend("Moderado", color: moderateColor)
                legend("Alto", color: highColor)
                legend("Principal", color: primaryColor)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func figure(image: String, side: MuscleViewSide, muscles: [String], label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .saturation(0.16)
                    .contrast(1.08)
                    .brightness(-0.08)
                    .opacity(0.80)
                    .accessibilityHidden(true)

                ZStack {
                    ForEach(muscles, id: \.self) { muscle in
                        let load = stimulus[muscle, default: 0]
                        if load > 0.05 {
                        AnatomicalMuscleRegion(muscle: muscle, side: side)
                                .fill(color(for: load).opacity(0.88))
                                .blur(radius: 0.55)
                                .blendMode(.color)
                        }
                    }
                }
                // La ligera difusión del color aporta volumen, pero nunca
                // debe salir de la anatomía. El alfa del propio render actúa
                // como límite exacto también en hombros, brazos y gemelos.
                .mask {
                    Image(image)
                        .resizable()
                        .scaledToFit()
                }
            }
            // El PNG es 1024 × 1536. La capa anatómica usa exactamente el
            // mismo lienzo 2:3; así nunca vuelve a desalinearse al cambiar el
            // ancho disponible o el tamaño dinámico del texto.
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: 142)
            .drawingGroup()

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func legend(_ label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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

    private var inactiveColor: Color { Color(red: 0.16, green: 0.48, blue: 0.58) }
    private var lightColor: Color { Color(red: 0.35, green: 0.78, blue: 0.40) }
    private var moderateColor: Color { Color(red: 0.95, green: 0.78, blue: 0.18) }
    private var highColor: Color { Color(red: 1.00, green: 0.46, blue: 0.10) }
    private var primaryColor: Color { Color(red: 0.94, green: 0.18, blue: 0.16) }
}

enum MuscleViewSide: Equatable { case front, back }

/// Máscaras vectoriales normalizadas sobre el render 2:3. Los trazados siguen
/// sus volúmenes anatómicos para conservar luces y textura del PNG.
struct AnatomicalMuscleRegion: Shape {
    let muscle: String
    let side: MuscleViewSide

    func path(in rect: CGRect) -> Path {
        var result = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        func mirrored(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: rect.maxX - ($0.x - rect.minX), y: $0.y) }
        }
        func polygon(_ normalized: [(CGFloat, CGFloat)], mirror: Bool = false) {
            var points = normalized.map { point($0.0, $0.1) }
            if mirror { points = mirrored(points) }
            guard points.count > 2, let first = points.first, let last = points.last else { return }
            // Curva cerrada por puntos medios: conserva las coordenadas del
            // músculo pero elimina los vértices de aspecto poligonal.
            result.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
            for index in points.indices {
                let current = points[index]
                let next = points[(index + 1) % points.count]
                result.addQuadCurve(
                    to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2),
                    control: current
                )
            }
            result.closeSubpath()
        }

        if side == .back {
            switch muscle {
            case "Hombros":
                polygon([(0.292,0.180),(0.340,0.164),(0.386,0.178),(0.370,0.232),(0.326,0.252),(0.291,0.222)])
                polygon([(0.292,0.180),(0.340,0.164),(0.386,0.178),(0.370,0.232),(0.326,0.252),(0.291,0.222)], mirror: true)
            case "Tríceps":
                polygon([(0.267,0.235),(0.310,0.224),(0.337,0.259),(0.325,0.338),(0.287,0.365),(0.263,0.321)])
                polygon([(0.267,0.235),(0.310,0.224),(0.337,0.259),(0.325,0.338),(0.287,0.365),(0.263,0.321)], mirror: true)
            case "Espalda":
                polygon([(0.382,0.112),(0.493,0.105),(0.493,0.382),(0.450,0.413),(0.372,0.326),(0.356,0.201)])
                polygon([(0.382,0.112),(0.493,0.105),(0.493,0.382),(0.450,0.413),(0.372,0.326),(0.356,0.201)], mirror: true)
            case "Glúteos":
                polygon([(0.351,0.411),(0.425,0.397),(0.493,0.426),(0.489,0.513),(0.444,0.539),(0.371,0.520),(0.344,0.470)])
                polygon([(0.351,0.411),(0.425,0.397),(0.493,0.426),(0.489,0.513),(0.444,0.539),(0.371,0.520),(0.344,0.470)], mirror: true)
            case "Isquios":
                polygon([(0.348,0.514),(0.425,0.506),(0.464,0.548),(0.447,0.657),(0.405,0.690),(0.363,0.645),(0.343,0.567)])
                polygon([(0.348,0.514),(0.425,0.506),(0.464,0.548),(0.447,0.657),(0.405,0.690),(0.363,0.645),(0.343,0.567)], mirror: true)
            case "Gemelos":
                polygon([(0.355,0.704),(0.414,0.694),(0.445,0.749),(0.425,0.859),(0.393,0.887),(0.358,0.842),(0.346,0.764)])
                polygon([(0.355,0.704),(0.414,0.694),(0.445,0.749),(0.425,0.859),(0.393,0.887),(0.358,0.842),(0.346,0.764)], mirror: true)
            default:
                break
            }
            return result
        }

        switch muscle {
        case "Pecho":
            polygon([(0.365,0.205),(0.425,0.193),(0.495,0.207),(0.495,0.276),(0.470,0.294),(0.405,0.287),(0.367,0.259)])
            polygon([(0.365,0.205),(0.425,0.193),(0.495,0.207),(0.495,0.276),(0.470,0.294),(0.405,0.287),(0.367,0.259)], mirror: true)
        case "Hombros":
            polygon([(0.303,0.183),(0.338,0.166),(0.382,0.173),(0.363,0.227),(0.325,0.250),(0.294,0.222)])
            polygon([(0.303,0.183),(0.338,0.166),(0.382,0.173),(0.363,0.227),(0.325,0.250),(0.294,0.222)], mirror: true)
        case "Bíceps":
            polygon([(0.283,0.247),(0.326,0.226),(0.348,0.249),(0.337,0.321),(0.304,0.350),(0.279,0.326)])
            polygon([(0.283,0.247),(0.326,0.226),(0.348,0.249),(0.337,0.321),(0.304,0.350),(0.279,0.326)], mirror: true)
        case "Core":
            polygon([(0.421,0.289),(0.493,0.293),(0.493,0.458),(0.462,0.472),(0.422,0.432),(0.405,0.350)])
            polygon([(0.421,0.289),(0.493,0.293),(0.493,0.458),(0.462,0.472),(0.422,0.432),(0.405,0.350)], mirror: true)
        case "Cuádriceps":
            polygon([(0.350,0.478),(0.425,0.470),(0.470,0.514),(0.455,0.649),(0.418,0.691),(0.372,0.646),(0.347,0.552)])
            polygon([(0.350,0.478),(0.425,0.470),(0.470,0.514),(0.455,0.649),(0.418,0.691),(0.372,0.646),(0.347,0.552)], mirror: true)
        default:
            break
        }
        return result
    }
}
