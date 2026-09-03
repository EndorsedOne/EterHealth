import SwiftUI
import WidgetKit

private let suiteName = "group.com.angelmartinez.eterhealth"
private let eterGreen = Color(red: 0.50, green: 0.78, blue: 0.39)

private struct EnergyEntry: TimelineEntry {
    let date: Date
    let energy: Int
    let energyCurve: [Double]
    let currentHour: Double
    let caffeineCurve: [Double]
    let caffeineNowMg: Double
    let caffeineBedtimeMg: Double
}

private struct EnergyProvider: TimelineProvider {
    func placeholder(in context: Context) -> EnergyEntry { sample }
    func getSnapshot(in context: Context, completion: @escaping (EnergyEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EnergyEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(20 * 60))))
    }

    private func load() -> EnergyEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        let curve = defaults?.array(forKey: "watch.energyCurve") as? [Double] ?? []
        guard !curve.isEmpty else { return sample }
        return EnergyEntry(
            date: defaults?.object(forKey: "watch.updatedAt") as? Date ?? Date(),
            energy: defaults?.integer(forKey: "watch.energy") ?? 0,
            energyCurve: curve,
            currentHour: defaults?.double(forKey: "watch.currentHour") ?? 0,
            caffeineCurve: defaults?.array(forKey: "watch.caffeineCurve") as? [Double] ?? [],
            caffeineNowMg: defaults?.double(forKey: "watch.caffeineNowMg") ?? 0,
            caffeineBedtimeMg: defaults?.double(forKey: "watch.caffeineBedtimeMg") ?? 0
        )
    }

    private var sample: EnergyEntry {
        EnergyEntry(date: .now, energy: 72, energyCurve: [25, 40, 58, 74, 82, 76, 72],
                    currentHour: 12, caffeineCurve: [0, 95, 72, 52, 38, 27, 18],
                    caffeineNowMg: 38, caffeineBedtimeMg: 8)
    }
}

private struct WatchEnergyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: EnergyEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        default: rectangular
        }
    }

    private var circular: some View {
        Gauge(value: Double(entry.energy), in: 0...100) {
            Image(systemName: "bolt.fill")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text("\(entry.energy)").font(.headline.bold()).monospacedDigit()
                if entry.caffeineNowMg >= 1 {
                    Text("☕︎\(Int(entry.caffeineNowMg.rounded()))").font(.system(size: 7))
                }
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(eterGreen)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Energía", systemImage: "bolt.fill").font(.caption2.bold())
                Spacer()
                Text("\(entry.energy)").font(.headline.bold()).monospacedDigit().foregroundStyle(eterGreen)
            }
            HStack(spacing: 5) {
                EnergySparkline(values: entry.energyCurve, currentHour: entry.currentHour)
                    .stroke(eterGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                VStack(alignment: .trailing, spacing: 1) {
                    Label("~\(Int(entry.caffeineNowMg.rounded())) mg", systemImage: "cup.and.saucer.fill")
                    Text("noche ~\(Int(entry.caffeineBedtimeMg.rounded())) mg")
                }.font(.system(size: 8)).foregroundStyle(.secondary)
            }
            CaffeineBar(values: entry.caffeineCurve).frame(height: 5)
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energía \(entry.energy) de 100. Cafeína estimada \(Int(entry.caffeineNowMg.rounded())) miligramos ahora y \(Int(entry.caffeineBedtimeMg.rounded())) por la noche.")
    }
}

private struct EnergySparkline: Shape {
    let values: [Double]
    let currentHour: Double
    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * CGFloat(index) / CGFloat(values.count - 1),
                                y: rect.height * (1 - CGFloat(min(100, max(0, value)) / 100)))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

private struct CaffeineBar: View {
    let values: [Double]
    var body: some View {
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule().fill(Color.brown.opacity(0.75)).frame(maxWidth: .infinity)
                    .frame(height: max(1, 5 * value / peak))
            }
        }
    }
}

struct EterWatchEnergyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EterWatchEnergyWidget", provider: EnergyProvider()) {
            WatchEnergyView(entry: $0)
        }
        .configurationDisplayName("Energía Éter")
        .description("Energía y cafeína restante de un vistazo.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

@main
struct EterHealthWatchWidgets: WidgetBundle {
    var body: some Widget { EterWatchEnergyWidget() }
}
