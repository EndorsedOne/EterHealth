//
//  ContentView.swift
//  EterHealthWatch Watch App
//
//  Created by Ángel Martínez on 12/8/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager
    @State private var showDiscardConfirmation = false
    @State private var reviewEffort = 6
    @State private var reviewPain = false

    var body: some View {
        Group {
        if workout.isRunning {
            activeWorkout
        } else if let summary = workout.completedSummary {
            postWorkoutSummary(summary)
        } else {
            home
        }
        }
        .alert("No se pudo iniciar", isPresented: Binding(get: { workout.errorMessage != nil }, set: { if !$0 { workout.errorMessage = nil } })) {
            Button("Aceptar") {}
        } message: { Text(workout.errorMessage ?? "") }
    }

    private func postWorkoutSummary(_ summary: WatchWorkoutSummary) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
                Text("Entrenamiento guardado").font(.headline)
                Text(summary.routine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    metric("clock", value: duration(summary.duration), unit: "tiempo", color: .blue)
                    metric("flame.fill", value: "\(Int(summary.energy.rounded()))", unit: "kcal", color: .orange)
                    metric("heart.fill", value: "\(Int(summary.averageHeartRate.rounded()))", unit: "ppm med.", color: .red)
                }
                HStack {
                    Text("Zonas").font(.caption2.bold()).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { index in
                        VStack(spacing: 2) {
                            Text("Z\(index + 1)").font(.system(size: 8, weight: .bold))
                            Text(zonePercent(summary, index: index)).font(.system(size: 9)).monospacedDigit()
                        }.frame(maxWidth: .infinity)
                    }
                }
                if summary.completedSets > 0 {
                    Text("\(summary.completedSets) series · \(Int(summary.totalVolume.rounded())) kg de volumen")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                Text("Esfuerzo percibido · \(reviewEffort)/10").font(.caption.bold())
                Picker("RPE", selection: $reviewEffort) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.wheel).frame(height: 55)
                Toggle("Dolor o molestia", isOn: $reviewPain).font(.caption)
                Button("Guardar valoración") { workout.saveReview(effort: reviewEffort, pain: reviewPain) }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button("Ahora no") { workout.dismissSummary() }.font(.caption)
            }.padding(.horizontal, 4)
        }
    }

    private func zonePercent(_ summary: WatchWorkoutSummary, index: Int) -> String {
        let total = summary.zoneSeconds.reduce(0, +)
        guard total > 0, summary.zoneSeconds.indices.contains(index) else { return "—" }
        return "\(Int((Double(summary.zoneSeconds[index]) / Double(total) * 100).rounded()))%"
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    readinessRing
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.readinessState.uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(readinessColor)
                        Text(workout.recommendation)
                            .font(.headline).lineLimit(2).minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

                Text(workout.recommendationReason)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    healthMetric("HRV", value: workout.hrv.map { "\($0)" } ?? "—", unit: "ms")
                    healthMetric("Reposo", value: workout.restingHeartRate.map { "\($0)" } ?? "—", unit: "ppm")
                    healthMetric("Sueño", value: workout.sleepHours.map { String(format: "%.1f", $0) } ?? "—", unit: "h")
                }

                // "cardio" covers swim/bike/brick/HYROX/race-day — this app has
                // no live tracking built for those yet, and the old fallback
                // (anything that wasn't literally "running" or "recovery")
                // used to route them into the strength button below, which
                // would start and log a mislabeled traditionalStrengthTraining
                // HealthKit session for a bike ride. Only a real "strength"
                // session gets the active button now.
                if workout.recommendedActivity == "running" || workout.recommendedActivity == "cardio" {
                    passiveRecommendation("Regístrala con Entreno de Apple", icon: "applewatch")
                } else if workout.recommendedActivity == "recovery" {
                    passiveRecommendation("Hoy toca asimilar, no registrar otra sesión", icon: "bed.double.fill")
                } else {
                    Button { Task { await workout.startRecommendation() } } label: {
                        Label(startLabel, systemImage: activityIcon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(readinessColor)
                }

                HStack(spacing: 5) {
                    Circle().fill(syncColor).frame(width: 6, height: 6)
                    Text(syncText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 3)
        }
    }

    private func healthMetric(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 1) {
            Text(title.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.caption.bold()).monospacedDigit()
                Text(unit).font(.system(size: 7)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func passiveRecommendation(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
                        .font(.caption.bold()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var readinessRing: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle().trim(from: 0, to: Double(workout.readiness ?? 0) / 100)
                .stroke(readinessColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(workout.readiness.map(String.init) ?? "—").font(.title3.bold()).monospacedDigit()
        }
        .frame(width: 57, height: 57)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disponibilidad")
        .accessibilityValue(workout.readiness.map { "\($0) de 100" } ?? "Pendiente de sincronización")
    }

    private var readinessColor: Color {
        guard let score = workout.readiness else { return .gray }
        return score >= 70 ? .green : score >= 45 ? .orange : .red
    }

    private var syncColor: Color { workout.summaryUpdatedAt == nil ? .orange : .green }
    private var activityIcon: String { workout.recommendedActivity == "recovery" ? "figure.cooldown" : "dumbbell.fill" }
    private var startLabel: String { "Empezar fuerza" }

    // "Already tracking, not a strength set" state — reached while a
    // session is active but not walking through exercises/sets. "cardio"
    // gets its own generic copy instead of literally "Carrera en curso",
    // since it may well be a bike ride or a HYROX simulation.
    private var inProgressIcon: String {
        switch workout.recommendedActivity {
        case "running": return "figure.run"
        case "cardio": return "figure.outdoor.cycle"
        default: return "iphone.and.arrow.forward"
        }
    }
    private var inProgressTitle: String {
        switch workout.recommendedActivity {
        case "running": return "Carrera en curso"
        case "cardio": return "Sesión en curso"
        default: return "Abre la rutina en el iPhone"
        }
    }
    private var inProgressSubtitle: String {
        switch workout.recommendedActivity {
        case "running", "cardio": return "El detalle de ritmo llegará en la siguiente mejora."
        default: return "Cuando el iPhone abra el entrenamiento aparecerán aquí ejercicio, peso y repeticiones."
        }
    }
    private var syncText: String {
        guard let date = workout.summaryUpdatedAt else { return workout.connectionState }
        return "\(workout.connectionState) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var activeWorkout: some View {
        TabView {
            liveMetricsPage
            currentSetPage
            VStack(spacing: 14) {
                Button { workout.togglePause() } label: { Label(workout.isPaused ? "Continuar" : "Pausar", systemImage: workout.isPaused ? "play.fill" : "pause.fill") }.tint(.orange)
                Button { Task { await workout.finish() } } label: { Label("Finalizar y guardar", systemImage: "checkmark") }.tint(.green)
                Button(role: .destructive) { showDiscardConfirmation = true } label: { Label("Descartar", systemImage: "trash") }
            }.buttonStyle(.borderedProminent)
        }.tabViewStyle(.verticalPage)
        .confirmationDialog("¿Descartar entrenamiento?", isPresented: $showDiscardConfirmation) {
            Button("Descartar en ambos dispositivos", role: .destructive) { workout.discard() }
            Button("Continuar", role: .cancel) {}
        }
    }

    private var liveMetricsPage: some View {
        VStack(spacing: 8) {
            HStack {
                Text(workout.isPaused ? "PAUSA" : workout.routineName.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(workout.isPaused ? .orange : .secondary).lineLimit(1)
                Spacer()
                Text(duration(workout.elapsed)).font(.caption.monospacedDigit().bold())
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "heart.fill").foregroundStyle(zoneColor)
                Text("\(Int(workout.heartRate.rounded()))").font(.system(size: 37, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("ppm").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Label("Z\(heartZone)", systemImage: "waveform.path.ecg").foregroundStyle(zoneColor)
                Spacer()
                Label("\(Int(workout.activeEnergy.rounded())) kcal", systemImage: "flame.fill").foregroundStyle(.orange)
            }.font(.caption.bold())
            ProgressView(value: heartZoneProgress).tint(zoneColor)
            Text(workout.maximumHeartRate == nil ? "Zona estimada · configura FC máx. en iPhone" : "Zona según FC máxima configurada")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var currentSetPage: some View {
        if workout.totalSets > 0 && workout.completedSets >= workout.totalSets {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Rutina completada").font(.headline)
                Text("\(workout.completedSets) series realizadas").font(.caption).foregroundStyle(.secondary)
                Button { Task { await workout.finish() } } label: { Label("Finalizar y guardar", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
        } else if let exercise = workout.exerciseName, workout.totalSets > 0, let restEndsAt = workout.restEndsAt, restEndsAt > Date() {
            restTimerPage(exercise: exercise, restEndsAt: restEndsAt)
        } else if let exercise = workout.exerciseName, workout.totalSets > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(workout.routineName.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).lineLimit(1)
                Text(exercise).font(.headline).lineLimit(2).minimumScaleFactor(0.75)
                HStack(spacing: 7) {
                    setValue("SERIE", "\(workout.setNumber)/\(workout.totalSets)")
                    setValue("KG", workout.setWeight.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")
                    setValue("REPS", workout.setReps.map(String.init) ?? "—")
                }
                Button { workout.completeSetOnPhone() } label: {
                    Label(workout.phoneReachable ? "Completar serie" : "Abre el iPhone", systemImage: workout.phoneReachable ? "checkmark.circle.fill" : "iphone")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.green).disabled(!workout.phoneReachable)
            }.padding(.horizontal, 4)
        } else {
            VStack(spacing: 10) {
                Image(systemName: inProgressIcon)
                    .font(.title2).foregroundStyle(.blue)
                Text(inProgressTitle)
                    .font(.headline).multilineTextAlignment(.center)
                Text(inProgressSubtitle)
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    // Matches the shape of Hevy's own Watch rest screen — the reference
    // the size/usability comparison was made against: a big, glanceable
    // countdown and progress bar you can read from across the gym, "Next
    // set" info so you know what's coming without unlocking the phone,
    // and Skip/±15s controls for the two things you actually do mid-rest.
    private func restTimerPage(exercise: String, restEndsAt: Date) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("Skip") { workout.skipRestOnPhone() }
                    .font(.caption.bold()).buttonStyle(.bordered).tint(.secondary)
                Spacer()
                Label("\(Int(workout.activeEnergy.rounded()))", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
                Label("\(Int(workout.heartRate.rounded()))", systemImage: "heart.fill")
                    .foregroundStyle(.red)
            }.font(.system(size: 11).bold())

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, restEndsAt.timeIntervalSince(context.date))
                VStack(spacing: 6) {
                    Text(duration(remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    ProgressView(value: restProgress(remaining: remaining, restEndsAt: restEndsAt))
                        .tint(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SIGUIENTE SERIE").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(exercise).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Text("Serie \(workout.setNumber)/\(workout.totalSets)")
                    if let weight = workout.setWeight {
                        Text("· \(weight.formatted(.number.precision(.fractionLength(0...1)))) kg")
                    }
                    if let reps = workout.setReps { Text("× \(reps)") }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                restAdjustButton("-15s", seconds: -15)
                restAdjustButton("+15s", seconds: 15)
            }
        }
        .padding(.horizontal, 4)
    }

    private func restAdjustButton(_ label: String, seconds: Int) -> some View {
        Button(label) { workout.adjustRestOnPhone(seconds: seconds) }
            .font(.caption.bold()).buttonStyle(.bordered).tint(.blue).frame(maxWidth: .infinity)
    }

    private func restProgress(remaining: TimeInterval, restEndsAt: Date) -> Double {
        guard let startedAt = workout.restStartedAt else { return 0 }
        let total = restEndsAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    private func setValue(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }

    private var heartZone: Int {
        let maximum = Double(workout.maximumHeartRate ?? max(170, Int(workout.heartRate.rounded()) + 5))
        let fraction = workout.heartRate / max(1, maximum)
        return fraction < 0.60 ? 1 : fraction < 0.70 ? 2 : fraction < 0.80 ? 3 : fraction < 0.90 ? 4 : 5
    }

    private var heartZoneProgress: Double {
        let maximum = Double(workout.maximumHeartRate ?? max(170, Int(workout.heartRate.rounded()) + 5))
        return min(1, max(0, workout.heartRate / max(1, maximum)))
    }

    private var zoneColor: Color {
        switch heartZone { case 1: return .cyan; case 2: return .blue; case 3: return .green; case 4: return .orange; default: return .red }
    }

    private func metric(_ icon: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 2) { Image(systemName: icon).foregroundStyle(color); Text(value).font(.title3.monospacedDigit().bold()); Text(unit).font(.caption2).foregroundStyle(.secondary) }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval)); return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
