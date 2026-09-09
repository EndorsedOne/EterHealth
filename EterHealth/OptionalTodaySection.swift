import SwiftUI

/// Tarjeta "Opcional para hoy": la sesión discrecional que el gemelo propone si
/// hoy tienes ganas y cuerpo, distinta de la próxima sesión calendarizada.
struct OptionalTodaySection: View {
    let assessment: TwinAssessment

    var body: some View {
        let session = OptionalTodayEngine.recommend(assessment: assessment)
        VStack(alignment: .leading, spacing: 10) {
            Text("OPCIONAL PARA HOY")
                .font(.caption2.bold()).tracking(EterTheme.eyebrowTracking)
                .foregroundStyle(EterTheme.accent)
            Text(session.title).font(.title3.bold())
            Text("Si hoy tienes ganas, tiempo y te encuentras bien. No es obligatoria: tu próxima sesión seria es la de arriba.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)

            HStack(spacing: 14) {
                Label(session.duration, systemImage: "clock")
                Label("\(session.exercises.count) bloques", systemImage: "list.bullet")
            }.font(.caption2).foregroundStyle(.secondary)

            Text(session.rationale).font(.caption).foregroundStyle(.secondary).lineSpacing(3)

            if let avoid = session.avoid {
                Label(avoid, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(EterTheme.warning).lineSpacing(2)
            }

            Divider()
            ForEach(session.exercises) { exercise in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(exercise.name).font(.caption.bold())
                    Spacer()
                    Text(exercise.detail).font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if exercise.id != session.exercises.last?.id { Divider().opacity(0.4) }
            }
        }.cardStyle()
    }
}
