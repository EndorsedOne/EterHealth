import SwiftUI
import UIKit

enum EterTheme {
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.070, blue: 0.064, alpha: 1)
            : UIColor(red: 0.965, green: 0.955, blue: 0.925, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.125, blue: 0.116, alpha: 1)
            : .white
    })
    static let raisedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.135, green: 0.155, blue: 0.145, alpha: 1)
            : UIColor(red: 0.985, green: 0.982, blue: 0.968, alpha: 1)
    })
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.90, green: 0.94, blue: 0.91, alpha: 1)
            : UIColor(red: 0.07, green: 0.18, blue: 0.15, alpha: 1)
    })
    static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.72, blue: 0.57, alpha: 1)
            : UIColor(red: 0.10, green: 0.28, blue: 0.23, alpha: 1)
    })
    static let positive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.78, blue: 0.58, alpha: 1)
            : UIColor(red: 0.13, green: 0.45, blue: 0.34, alpha: 1)
    })
    static let accent = Color(red: 0.84, green: 0.94, blue: 0.55)
    // The dark ink that sits legibly on top of `accent`'s lime — was
    // copied by hand as the same literal RGB in at least three places
    // (this file's own button style, StrengthTrainingView's proposal
    // buttons) instead of being named once.
    static let accentInk = Color(red: 0.07, green: 0.18, blue: 0.15)
    static let warning = Color.orange
    static let danger = Color.red
    // "Worse than your own baseline" — a distinct semantic from `warning`
    // (transient caution copy) and `danger` (genuinely out-of-range/alert
    // severity), even though it renders the same amber. Was previously
    // expressed ad hoc as raw `.orange` in half a dozen places (biological
    // age delta, lab status, baseline deltas...) with no shared name —
    // one token now, so "adverse vs your baseline" always means the same
    // color everywhere it appears.
    static let negative = Color.orange
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 13
    static let pageSpacing: CGFloat = 20
    // The one eyebrow-label letter-spacing value for every card/section
    // header in the app — tracking values of 0.6/1.0/1.1/1.2/1.3/2 were
    // all in use for what is visually the same role before this existed.
    static let eyebrowTracking: CGFloat = 1.2
}

// The single shared answer to "is this value better or worse than the
// reference it's being compared against" — used by every baseline/trend
// comparison in the app instead of each card inventing its own color
// scheme (some used green/red, some green/orange, some left it
// uncolored). `favorableHigh` is the same "which direction is good"
// signal PersonalBaselineEngine and friends already compute; `deadZone`
// lets a card declare "this small a difference isn't really a signal"
// without every caller reimplementing that threshold.
enum Favorability {
    case favorable, neutral, adverse

    var color: Color {
        switch self {
        case .favorable: return EterTheme.positive
        case .neutral: return .secondary
        case .adverse: return EterTheme.negative
        }
    }

    static func of(delta: Double, favorableHigh: Bool, deadZone: Double = 0) -> Favorability {
        guard abs(delta) > deadZone else { return .neutral }
        return (delta >= 0) == favorableHigh ? .favorable : .adverse
    }

}

// "Adecuado/Alto/Excesivo/No requerido" volume-coverage labels appear in
// both running and strength coverage views — was copy-pasted as an
// identical raw-literal switch (green/orange/red/secondary/blue) in each
// instead of shared once. Kept as 3 distinct severity tiers rather than
// Favorability's binary favorable/adverse: "Excesivo" is a harder flag
// than "Alto", not just "also bad".
func coverageStateColor(_ state: String) -> Color {
    switch state {
    case "Adecuado": return EterTheme.positive
    case "Alto": return EterTheme.negative
    case "Excesivo": return EterTheme.danger
    case "No requerido": return .secondary
    default: return .blue
    }
}

private struct EterMinimumTouchTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

extension View {
    func eterTouchTarget() -> some View { modifier(EterMinimumTouchTarget()) }
}

struct EterPageHeader: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.caption2.bold()).tracking(2).foregroundStyle(.secondary)
            Text(title)
                .font(.largeTitle).fontDesign(.serif)
                .foregroundStyle(EterTheme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EterSectionHeader: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?

    init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil) {
        self.title = title
        self.eyebrow = eyebrow
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow {
                Text(eyebrow.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            }
            Text(title).font(.title3.bold()).foregroundStyle(EterTheme.ink)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EterPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(Color.white)
            .background(EterTheme.primary.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct EterAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(EterTheme.accentInk)
            .background(EterTheme.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct AppScaffold<Content: View>: View {
    let isLoading: Bool
    @ViewBuilder let content: Content
    init(isLoading: Bool, @ViewBuilder content: () -> Content) {
        self.isLoading = isLoading
        self.content = content()
    }

    var body: some View {
        ZStack {
            EterTheme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: EterTheme.pageSpacing) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("éter")
                    .font(.title).fontWeight(.medium).fontDesign(.serif)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Circle()
                    .fill(isLoading ? EterTheme.negative : EterTheme.accent)
                    .frame(width: 11, height: 11)
                    .accessibilityLabel(isLoading ? "Actualizando datos" : "Datos preparados")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(EterTheme.canvas.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            }
        }
        .foregroundStyle(EterTheme.ink)
        .tint(EterTheme.primary)
    }
}

extension View {
    func cardStyle() -> some View {
        self.padding(17)
            .background(EterTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: EterTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EterTheme.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.045), radius: 10, y: 4)
    }

    func eterInsetStyle() -> some View {
        self.padding(12)
            .background(EterTheme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
    }
}

struct MuscleRadar: View {
    let current: [String: Double]
    let previous: [String: Double]
    // Estímulo de cardio (carrera, ciclismo, senderismo) traducido a
    // series-equivalentes por el MISMO modelo de fatiga que usa el gemelo
    // (TrainingPlanEngine.cardioMuscleLoad). Se dibuja como una capa aparte,
    // discontinua, NUNCA sumada a `current`: el % de hipertrofia sigue siendo
    // sólo de fuerza, pero así se ve que correr también carga las piernas en
    // vez de fingir que no cuenta. Vacío = no dibuja nada (comportamiento y
    // llamadas antiguas intactos).
    var cardio: [String: Double] = [:]
    // The window `current`/`previous` were actually summed over — the
    // targets below are per-week, so a 10-day window (this view's one
    // real caller) needs them scaled up ~1.43x, not compared directly
    // against a weekly number.
    var periodDays: Double = 7
    private let axes = ["Espalda", "Pecho", "Core", "Hombros", "Brazos", "Piernas"]

    // A full (100%) axis used to just mean "whichever muscle got the most
    // sets this period" — so training only legs a little still drew legs
    // at a "complete" 100%, and a genuinely well-trained back sat at the
    // same 100% whether it had 8 sets or 20. What "complete" should mean
    // is a real, fixed target: Schoenfeld et al.'s hypertrophy-volume
    // meta-analyses and RP-style volume-landmark guidance both land
    // around 10-20 direct sets/muscle/week, adjusted a little per bucket
    // here — larger muscle mass (back, legs) tolerates and needs more,
    // and the "Piernas"/"Brazos" buckets each fold in multiple individual
    // muscles (quads+glutes+isquios+gemelos; biceps+triceps), so a single
    // set can count toward more than one of them at once. These are
    // calibratable defaults, not a fixed law — the point is a stable,
    // evidence-based reference instead of a denominator that moves with
    // whatever you happened to train most.
    // Sourced from MuscleVolumeLandmarkTable (its MAV tier) so this radar
    // and the actual prescription logic in TrainingPlanEngine describe
    // "how much is enough this week" with the same number, not two
    // independently hand-picked ones that used to just happen to agree.
    private func target(_ muscle: String) -> Double { MuscleVolumeLandmarkTable.bucketMAV(muscle) * periodDays / 7 }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height) * 0.68
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2
            Canvas { context, _ in
                for level in 1...5 {
                    let r = radius * Double(level) / 5
                    context.stroke(polygon(center: center, radius: r, values: Array(repeating: 1, count: axes.count)), with: .color(.primary.opacity(0.10)), lineWidth: 1)
                }
                for index in axes.indices {
                    var path = Path()
                    path.move(to: center)
                    path.addLine(to: point(center: center, radius: radius, index: index, count: axes.count))
                    context.stroke(path, with: .color(.primary.opacity(0.10)), lineWidth: 1)
                }
                // Clamped a little past 1.0 (not hard-capped at it) so a
                // muscle pushed past its target visibly pokes past the
                // ring instead of reading identically to "exactly enough".
                drawSeries(context: &context, center: center, radius: radius, values: axes.map { min(1.3, (previous[$0] ?? 0) / target($0)) }, color: .gray)
                // El cardio va DEBAJO del actual y sin relleno sólido: es
                // contexto ("esto también te cargó las piernas"), no el dato
                // principal. Sólo se dibuja si hay algún estímulo real.
                if axes.contains(where: { (cardio[$0] ?? 0) > 0 }) {
                    drawSeries(context: &context, center: center, radius: radius,
                               values: axes.map { min(1.3, (cardio[$0] ?? 0) / target($0)) },
                               color: .orange, dashed: true, fillOpacity: 0.06)
                }
                drawSeries(context: &context, center: center, radius: radius, values: axes.map { min(1.3, (current[$0] ?? 0) / target($0)) }, color: .blue)
            }
            ForEach(axes.indices, id: \.self) { index in
                let position = point(center: center, radius: radius + 22, index: index, count: axes.count)
                VStack(spacing: 0) {
                    Text(axes[index]).font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(((current[axes[index]] ?? 0) / target(axes[index]) * 100).rounded()))%")
                        .font(.caption2.bold()).foregroundStyle(.secondary.opacity(0.8))
                }.position(position)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distribución muscular")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        axes.map { muscle in
            let currentSets = current[muscle] ?? 0
            let percent = Int((currentSets / target(muscle) * 100).rounded())
            let cardioSets = cardio[muscle] ?? 0
            let cardioNote = cardioSets > 0 ? ", más \(Int(cardioSets.rounded())) series-equivalentes de cardio" : ""
            return "\(muscle): actual \(Int(currentSets.rounded())) series de \(Int(target(muscle))) objetivo (\(percent)%)\(cardioNote), anterior \(Int((previous[muscle] ?? 0).rounded()))"
        }.joined(separator: ". ")
    }

    private func polygon(center: CGPoint, radius: Double, values: [Double]) -> Path {
        var path = Path()
        for index in values.indices {
            let position = point(center: center, radius: radius * values[index], index: index, count: values.count)
            index == 0 ? path.move(to: position) : path.addLine(to: position)
        }
        path.closeSubpath()
        return path
    }

    private func point(center: CGPoint, radius: Double, index: Int, count: Int) -> CGPoint {
        let angle = -Double.pi / 2 + (Double(index) * 2 * Double.pi / Double(count))
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func drawSeries(context: inout GraphicsContext, center: CGPoint, radius: Double, values: [Double],
                            color: Color, dashed: Bool = false, fillOpacity: Double = 0.20) {
        let path = polygon(center: center, radius: radius, values: values)
        context.fill(path, with: .color(color.opacity(fillOpacity)))
        let style = dashed
            ? StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [4, 3])
            : StrokeStyle(lineWidth: 2.5, lineJoin: .round)
        context.stroke(path, with: .color(color.opacity(0.85)), style: style)
    }
}
