import SwiftUI
import Charts

struct PhysiologicalHealthView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var imports: ImportStore
    @EnvironmentObject private var injuries: InjuryStore
    @EnvironmentObject private var twinStates: TwinStateStore
    @EnvironmentObject private var goals: GoalStore

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            longevityIndexCard
            biologicalAgeCard
            personalBaselineCard
            cardiovascularContextCard
            extendedHealthSignalsCard
            TemperatureCheckInCardView(points: health.wristTemperatureHistory)
            sleepCard
            trendCharts
        }
    }

    private var longevityIndexCard: some View {
        let index = LongevityEngine.calculate(health: health, imports: imports, injuries: injuries)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Índice híbrido de longevidad").font(.headline)
                    Text("Reserva funcional, protección y resiliencia").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: DataTrust(
                    nature: .calculated, source: "Apple Salud, entrenamientos y analíticas",
                    measuredAt: health.lastUpdated, samples: index.dimensions.count,
                    level: index.confidence,
                    explanation: "Separa tres pilares: reserva funcional, protección cardiometabólica y resiliencia. Combina mediciones fisiológicas, analíticas y rendimiento, y normaliza únicamente sobre dimensiones disponibles.",
                    limitations: "No predice años de vida, edad biológica, enfermedad ni mortalidad. No debe compararse con la puntuación de otra persona y la cobertura incompleta puede mover el resultado."
                ))
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(index.score.map(String.init) ?? "—").font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
                Text("/100").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Cobertura \(index.coverage)%").font(.subheadline.bold())
                    Text("Confianza \(index.confidence.rawValue.lowercased())").font(.caption).foregroundStyle(index.confidence.color)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], spacing: 9) {
                ForEach(index.pillars) { pillar in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pillar.pillar.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text("\(pillar.score)").font(.title3.bold()).monospacedDigit()
                        ProgressView(value: Double(pillar.score), total: 100).tint(scoreColor(pillar.score))
                        Text("Cobertura \(pillar.coverage)%").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10).background(EterTheme.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pillar.pillar.rawValue)
                    .accessibilityValue("\(pillar.score) de 100, cobertura \(pillar.coverage) por ciento")
                }
            }
            if let priority = index.priority {
                Label(priority, systemImage: "scope")
                    .font(.caption.bold()).foregroundStyle(EterTheme.primary).lineSpacing(3)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(EterTheme.accent.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: EterTheme.controlRadius, style: .continuous))
            }
            Divider()
            ForEach(index.dimensions) { dimension in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(dimension.name).font(.caption.bold())
                        Circle().fill(dimension.confidence.color).frame(width: 6, height: 6)
                            .accessibilityLabel("Confianza \(dimension.confidence.rawValue)")
                        Spacer()
                        Text("\(dimension.score)").font(.caption.bold()).monospacedDigit()
                    }
                    ProgressView(value: Double(dimension.score), total: 100).tint(scoreColor(dimension.score))
                    Text("\(dimension.pillar.rawValue) · \(dimension.evidence)").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dimension.name)
                .accessibilityValue("\(dimension.score) de 100. Confianza \(dimension.confidence.rawValue). \(dimension.evidence)")
            }
            if !index.missing.isEmpty {
                Text("Para aumentar cobertura: \(index.missing.prefix(3).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Es un índice personal, no clínico ni una edad biológica. Importan más su tendencia, sus pilares y la cobertura que una cifra aislada.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
            .accessibilityElement(children: .contain)
    }

    private var biologicalAgeCard: some View {
        let estimate = BiologicalAgeEngine.calculate(labs: imports.labs, birthDate: goals.profile.birthDate)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edad estimada por biomarcadores").font(.headline)
                    Text("Aproximación (PhenoAge) — no es tu edad biológica clínicamente validada").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let estimate {
                    DataTrustBadge(trust: DataTrust(
                        nature: .calculated, source: "Analítica clínica importada",
                        measuredAt: estimate.drawDate, samples: 6, level: estimate.confidence,
                        explanation: "PhenoAge (Levine et al. 2018, Aging 10(4):573-591), calculada con 6 de 9 biomarcadores reales de tu analítica del \(estimate.drawDate.formatted(date: .abbreviated, time: .omitted)). Coeficientes y valores poblacionales de referencia verificados frente a la implementación de referencia ajsteele/bioage.",
                        limitations: "No predice mortalidad ni enfermedad, no sustituye una valoración médica y depende de una única analítica puntual. Incertidumbre por imputación: ±\(estimate.uncertainty.formatted(.number.precision(.fractionLength(1)))) años."
                    ))
                }
            }
            if let estimate {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("≈ \(estimate.estimatedAge.formatted(.number.precision(.fractionLength(0)))) años").font(.largeTitle.bold()).fontDesign(.rounded).monospacedDigit()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("edad real \(estimate.chronologicalAge)").font(.caption).foregroundStyle(.secondary)
                        Text("\(estimate.delta >= 0 ? "+" : "")\(estimate.delta.formatted(.number.precision(.fractionLength(1)))) años")
                            .font(.caption.bold()).foregroundStyle(estimate.delta <= 0 ? EterTheme.positive : EterTheme.negative)
                    }
                }
                if !estimate.imputedMarkers.isEmpty {
                    // Not "this would make it real" — PhenoAge stays an
                    // epidemiological approximation regardless — but this is
                    // exactly what would make it fully yours instead of
                    // partly population-average: name the missing inputs so
                    // there's something concrete to ask for.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Para que se calcule con tus propios datos", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold()).foregroundStyle(EterTheme.warning)
                        Text("Ahora mismo \(estimate.imputedMarkers.count) de 9 variables se sustituyen por la media poblacional de tu edad porque nunca se han pedido en tus análisis: \(estimate.imputedMarkers.joined(separator: ", ")). Pídelas en tu próxima extracción de sangre junto al resto del panel.")
                            .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                    }
                    .padding(10).background(EterTheme.warning.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                biomarkerContributionBreakdown(estimate.contributions)
            } else {
                Text("Hace falta una analítica con glucosa, creatinina, leucocitos, VCM y ADE/RDW de la misma extracción, y tu fecha de nacimiento en Plan del gemelo, para poder estimarla.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
            Text("Es una aproximación con fines de seguimiento personal, calculada a partir de una fórmula publicada — no un diagnóstico ni una medida clínica de edad biológica.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
            .accessibilityElement(children: .contain)
    }

    // The formula's own weighting, laid out per input — same idea as the web
    // dashboard's domain-row breakdown for "Índice de capacidad". Sorted by
    // how strongly the model weighs each one (|coeficiente|), not by value,
    // since that's what "cómo ponderan" actually means here.
    private func biomarkerContributionBreakdown(_ contributions: [BiomarkerContribution]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Desglose de variables del modelo").font(.caption.bold())
            ForEach(contributions.sorted { abs($0.coefficient) > abs($1.coefficient) }) { term in
                HStack {
                    Circle().fill(term.isImputed ? Color.orange : EterTheme.positive).frame(width: 6, height: 6)
                    Text(term.name).font(.caption2)
                    Text(term.isImputed ? "media poblacional" : "tu dato").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(term.value.formatted(.number.precision(.fractionLength(1)))) \(term.unit)")
                        .font(.caption2.bold()).monospacedDigit()
                    Text("coef. \(term.coefficient >= 0 ? "+" : "")\(term.coefficient.formatted(.number.precision(.fractionLength(4))))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 92, alignment: .trailing)
                }
            }
            Text("El coeficiente es el peso que la fórmula publicada asigna a cada variable, no una cifra en años: la relación entre esta combinación y la edad estimada no es lineal.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }
    }

    private var cardiovascularContextCard: some View {
        let systolic = health.systolicBloodPressureHistory.last?.value
        let diastolic = health.diastolicBloodPressureHistory.last?.value
        let ldl = imports.labs.first { $0.name.localizedCaseInsensitiveContains("ldl") }
        let pressureDate = [health.systolicBloodPressureHistory.last?.date, health.diastolicBloodPressureHistory.last?.date]
            .compactMap { $0 }.max()
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Contexto cardiovascular").font(.headline)
                    Text("Señales complementarias, no un diagnóstico ni una puntuación clínica").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: DataTrust(
                    nature: .measured,
                    source: "Apple Salud y analíticas importadas",
                    measuredAt: pressureDate ?? ldl?.date,
                    samples: health.systolicBloodPressureHistory.count + health.diastolicBloodPressureHistory.count + (ldl == nil ? 0 : 1),
                    level: ConfidenceEngine.samples(health.systolicBloodPressureHistory.count + health.diastolicBloodPressureHistory.count + (ldl == nil ? 0 : 1), medium: 2, high: 8, label: "mediciones cardiovasculares").level,
                    explanation: "La tensión procede de Apple Salud; LDL procede del informe de laboratorio importado.",
                    limitations: "La tensión depende de técnica, dispositivo y contexto. El riesgo cardiovascular real requiere edad, antecedentes, tabaquismo y valoración profesional."
                ))
            }
            HStack(spacing: 10) {
                cardiovascularValue("Tensión", systolic.flatMap { upper in diastolic.map { "\(Int(upper.rounded()))/\(Int($0.rounded()))" } } ?? "—", "mmHg")
                cardiovascularValue("LDL", ldl.map { $0.value.formatted(.number.precision(.fractionLength(0...1))) } ?? "—", ldl?.unit ?? "")
                cardiovascularValue("VO₂ máx.", health.vo2MaxHistory.last.map { $0.value.formatted(.number.precision(.fractionLength(1))) } ?? "—", "ml/kg/min")
            }
            if systolic == nil || diastolic == nil {
                Text("No hay tensión arterial legible. Puedes registrarla en Apple Salud y Éter incorporará su evolución.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let pressureDate {
                Text("Última tensión: \(pressureDate.formatted(date: .abbreviated, time: .shortened)). Interpreta la tendencia y las mediciones repetidas, no una lectura aislada.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // General lifestyle guidance for a value genuinely outside a
            // broadly-agreed optimal range — never a diagnosis. Only ever
            // appears for metrics with well-established directionality;
            // see WellnessRecommendationEngine's own reasoning.
            ForEach(cardiovascularRecommendations(systolic: systolic, diastolic: diastolic, ldl: ldl), id: \.self) { tip in
                Label(tip, systemImage: "lightbulb.fill").font(.caption2).foregroundStyle(EterTheme.primary).lineSpacing(2)
            }
        }.cardStyle()
    }

    private func cardiovascularRecommendations(systolic: Double?, diastolic: Double?, ldl: LabResult?) -> [String] {
        var tips: [String] = []
        if let systolic, let diastolic, let tip = WellnessRecommendationEngine.bloodPressure(systolic: systolic, diastolic: diastolic) {
            tips.append(tip)
        }
        if let ldl, let tip = WellnessRecommendationEngine.lab(name: ldl.name, status: ldl.status) {
            tips.append(tip)
        }
        if let vo2 = health.vo2MaxHistory.last?.value, let tip = WellnessRecommendationEngine.vo2Max(vo2) {
            tips.append(tip)
        }
        return tips
    }

    private func cardiovascularValue(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit().minimumScaleFactor(0.75)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(unit)")
    }

    // favorableHigh: nil for the two signals with no settled personal-
    // deviation direction (wrist temperature can rise from illness, a
    // hard session, alcohol, room heat, or — for anyone tracking a cycle
    // — the luteal phase; walking heart rate depends on pace, incline and
    // heat as much as fitness) — those stay uncolored on purpose, same
    // "let the person judge" design this card already had. Respiratory
    // rate and oxygen saturation DO have a defensible direction relative
    // to one's own baseline — a rise in overnight breathing rate or a
    // drop in SpO2 versus your own norm is the same early-illness/
    // disrupted-breathing signal wearables already use it for elsewhere
    // — so those two now get the same colored delta-vs-baseline treatment
    // "Tu línea base" and the trend charts above already use, instead of
    // this card being the one place in Salud that never says whether a
    // real personal deviation is favorable or not.
    private struct ExtendedSignal { let name: String; let unit: String; let points: [TrendPoint]; let favorableHigh: Bool? }

    private var extendedHealthSignalsCard: some View {
        let metrics: [ExtendedSignal] = [
            ExtendedSignal(name: "Respiración nocturna", unit: "resp/min", points: health.respiratoryRateHistory, favorableHigh: false),
            ExtendedSignal(name: "Oxígeno periférico", unit: "%", points: health.oxygenSaturationHistory, favorableHigh: true),
            ExtendedSignal(name: "Temperatura de muñeca", unit: "°C", points: health.wristTemperatureHistory, favorableHigh: nil),
            ExtendedSignal(name: "Pulso caminando", unit: "ppm", points: health.walkingHeartRateHistory, favorableHigh: nil)
        ]
        let sampleCount = metrics.reduce(0) { $0 + $1.points.count }
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Señales ampliadas de Apple Salud").font(.headline)
                    Text("Contexto fisiológico adicional cuando tu dispositivo lo registra").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: DataTrust(
                    nature: .measured, source: "Apple Salud",
                    measuredAt: metrics.flatMap(\.points).map(\.date).max(), samples: sampleCount,
                    level: ConfidenceEngine.level(samples: sampleCount, medium: 5, high: 20),
                    explanation: "Éter lee estas series directamente de Apple Salud y conserva su evolución sin rellenar días ausentes.",
                    limitations: "La disponibilidad depende del modelo de reloj, configuración, región y calidad de medición. No son diagnósticos ni sustituyen una medición clínica."
                ))
            }
            ForEach(metrics, id: \.name) { metric in extendedSignalRow(metric) }
            Text("Aquí importa especialmente el cambio respecto a tu propia línea base. Una lectura aislada anómala debe confirmarse en Apple Salud y, si preocupa, con un profesional.")
                .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
        }.cardStyle()
    }

    private func extendedSignalRow(_ metric: ExtendedSignal) -> some View {
        // Same 8-week window and 0.5-personal-SD-equivalent dead zone the
        // trend charts above use for HRV/RHR/VO2max — one shared notion
        // of "habitual" across this whole page, not a second one just
        // for this card. Needs >=14 real days before calling anything a
        // habitual base; below that it falls back to the plain weekly
        // range this card always showed.
        let recentValues = Array(metric.points.suffix(56)).map(\.value)
        let mean = recentValues.count >= 14 ? recentValues.reduce(0, +) / Double(recentValues.count) : nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.name).font(.subheadline.bold())
                    Text(metric.points.isEmpty ? "No disponible" : "\(metric.points.count) días registrados")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(metric.points.last.map { "\($0.value.formatted(.number.precision(.fractionLength(1)))) \(metric.unit)" } ?? "—")
                    .font(.subheadline.bold()).monospacedDigit()
            }
            if let last = metric.points.last?.value, let mean {
                let delta = last - mean
                if let favorableHigh = metric.favorableHigh {
                    let favorability = Favorability.of(delta: delta, favorableHigh: favorableHigh, deadZone: mean * 0.02)
                    HStack(spacing: 6) {
                        Image(systemName: favorability == .neutral ? "equal.circle.fill" : delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(favorability.color).font(.caption2)
                        Text(baselineDeltaText(delta: delta, unit: metric.unit, mean: mean))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    // Deliberately uncolored — see ExtendedSignal's own
                    // comment above: no settled direction for this signal.
                    Text(baselineDeltaText(delta: delta, unit: metric.unit, mean: mean))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if let insight = weeklyRangeInsight(metric.points, unit: metric.unit) {
                Text(insight).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.name)
        .accessibilityValue(metric.points.last.map { "\($0.value.formatted(.number.precision(.fractionLength(1)))) \(metric.unit), \(metric.points.count) días registrados" } ?? "No disponible")
    }

    private func baselineDeltaText(delta: Double, unit: String, mean: Double) -> String {
        "\(abs(delta).formatted(.number.precision(.fractionLength(1)))) \(unit) \(delta >= 0 ? "por encima" : "por debajo") de tu media habitual de \(mean.formatted(.number.precision(.fractionLength(1)))) \(unit)."
    }

    // Still used as the fallback below 14 real days of history — the
    // plain fact Apple Health's own widgets show (the week's range and
    // average) rather than guessing a "habitual base" from too little data.
    private func weeklyRangeInsight(_ points: [TrendPoint], unit: String) -> String? {
        let recent = Array(points.suffix(7)).map(\.value)
        guard recent.count >= 3, let low = recent.min(), let high = recent.max() else { return nil }
        let average = recent.reduce(0, +) / Double(recent.count)
        func fmt(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
        if high - low < 0.05 { return "Estable en \(fmt(average)) \(unit) esta semana." }
        return "Esta semana ha ido de \(fmt(low)) a \(fmt(high)) \(unit) · media \(fmt(average))."
    }


    private var sleepCard: some View {
        let stages = health.sleepStages
        let total = stages.asleepHours
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sueño de anoche").font(.headline)
                    Text("Fases registradas por Apple Salud").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DataTrustBadge(trust: HealthDataTrust.sleep(health))
                Text("\(total, specifier: "%.1f") h").font(.title3.bold())
            }
            if total == 0 {
                Text("No hay fases de sueño sincronizadas.").font(.caption).foregroundStyle(.secondary).frame(height: 55)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        sleepSegment(hours: stages.deepHours, total: total, width: proxy.size.width, color: .indigo)
                        sleepSegment(hours: stages.coreHours, total: total, width: proxy.size.width, color: .blue)
                        sleepSegment(hours: stages.remHours, total: total, width: proxy.size.width, color: .cyan)
                        if stages.unspecifiedHours > 0 { sleepSegment(hours: stages.unspecifiedHours, total: total, width: proxy.size.width, color: .gray) }
                    }.clipShape(Capsule())
                }.frame(height: 13)
                LazyVGrid(columns: columns, spacing: 10) {
                    sleepStage("Profundo", hours: stages.deepHours, total: total, color: .indigo)
                    sleepStage("Esencial", hours: stages.coreHours, total: total, color: .blue)
                    sleepStage("REM", hours: stages.remHours, total: total, color: .cyan)
                    sleepStage("Despierto", hours: stages.awakeHours, total: total + stages.awakeHours, color: .orange)
                }
                // Anoche es una sola noche; esto es sobre las últimas ~14 —
                // cuánto de ese sueño fue realmente profundo y REM, no solo
                // cuánto duró. Antes esto era un número suelto ("X/100") más
                // una frase técnica densa (%s y bandas de referencia en
                // texto corrido) — exactamente lo que el usuario señaló como
                // poco visual. Ahora cada componente tiene su propia barra
                // contra su rango de referencia real (mismo lenguaje visual
                // que "Tu línea base" usa para HRV/pulso/sueño), y la frase
                // final es una conclusión en lenguaje llano, no un volcado
                // de cifras. Ver SleepArchitectureEngine.
                if let architecture = SleepArchitectureEngine.evaluate(health.sleepStagesHistory) {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Arquitectura del sueño").font(.caption.bold())
                            Text("Últimas \(architecture.nights) noches con fases reales").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(architecture.score)").font(.title2.bold().monospacedDigit())
                                .foregroundStyle(architectureScoreColor(architecture.score))
                            Text("/100").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        architectureBandRow("Profundo", value: architecture.averageDeepShare, band: SleepArchitectureEngine.deepShareBand)
                        architectureBandRow("REM", value: architecture.averageRemShare, band: SleepArchitectureEngine.remShareBand)
                        architectureContinuityRow(architecture.averageContinuity)
                    }
                    // The existing caveat at the bottom of this card ("Las
                    // fases son estimaciones...") already covers Apple
                    // Watch/polysomnography honesty for the whole card — no
                    // need for a second, near-identical disclaimer here.
                    Text(architectureTakeaway(architecture))
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }
                Text("Las fases son estimaciones del Apple Watch; sirven para observar tendencias, no para diagnosticar trastornos del sueño.")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
            }
        }.cardStyle()
    }

    private func sleepSegment(hours: Double, total: Double, width: Double, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width * hours / max(total, 0.01)))
    }

    private func sleepStage(_ name: String, hours: Double, total: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(name).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(hours, specifier: "%.1f") h").font(.headline).monospacedDigit()
                Text("\(Int((hours / max(total, 0.01) * 100).rounded()))%").font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func architectureScoreColor(_ score: Int) -> Color {
        score >= 70 ? EterTheme.positive : score >= 45 ? EterTheme.warning : EterTheme.danger
    }

    // Deep and REM are both two-sided: below OR above the published band
    // costs the score (SleepArchitectureEngine.bandScore), so favorable
    // here means strictly "inside the band" — there's no partial-credit
    // dead zone the way a personal-habitual comparison gets one, because
    // this band isn't personal, it's a fixed physiological reference.
    private func architectureBandRow(_ name: String, value: Double, band: (low: Double, high: Double)) -> some View {
        let percentValue = value * 100
        let withinBand = value >= band.low && value <= band.high
        let favorable: Bool? = withinBand ? true : false
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.caption.bold())
                Spacer()
                Text("\(Int(percentValue.rounded()))%")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(Self.color(for: favorable))
                Text("ref. \(Int((band.low * 100).rounded()))–\(Int((band.high * 100).rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            BaselineRangeGauge(low: band.low * 100, high: band.high * 100, expected: nil, current: percentValue, favorable: favorable)
        }
    }

    // Continuity isn't two-sided like deep/REM — it's a one-way ramp from
    // "poor" to "ideal" (SleepArchitectureEngine.ascendingScore), so the
    // shaded zone marks the healthy zone from `ideal` up rather than a
    // habitual band, and a mid-range reading gets the same neutral-gray
    // "not clearly one or the other" treatment the personal-baseline rows
    // use for their own dead zone.
    private func architectureContinuityRow(_ value: Double) -> some View {
        let percentValue = value * 100
        let band = SleepArchitectureEngine.continuityBand
        let favorable: Bool? = value >= band.ideal ? true : value <= band.poor ? false : nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Continuidad").font(.caption.bold())
                Spacer()
                Text("\(Int(percentValue.rounded()))%")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(Self.color(for: favorable))
                Text("ideal ≥\(Int((band.ideal * 100).rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            BaselineRangeGauge(low: band.ideal * 100, high: 100, expected: nil, current: percentValue, favorable: favorable)
        }
    }

    // A plain-language conclusion in place of the old dense evidence
    // sentence ("Profundo 18% (referencia 13–23%) · REM 21% ..."). The
    // numbers now live in the gauges above; this sentence only needs to
    // say what actually matters — which component, if any, is driving the
    // score down, and whether the trend vs. the user's own last month is
    // an improvement or a regression.
    private func architectureTakeaway(_ architecture: SleepArchitectureEngine.Assessment) -> String {
        let deepBand = SleepArchitectureEngine.deepShareBand
        let remBand = SleepArchitectureEngine.remShareBand
        let deepOK = architecture.averageDeepShare >= deepBand.low && architecture.averageDeepShare <= deepBand.high
        let remOK = architecture.averageRemShare >= remBand.low && architecture.averageRemShare <= remBand.high
        let continuityPoor = architecture.averageContinuity <= SleepArchitectureEngine.continuityBand.poor

        var sentence: String
        if deepOK && remOK {
            sentence = "Tu sueño profundo y REM están dentro del rango saludable."
        } else if !deepOK && !remOK {
            sentence = "Tu sueño profundo y tu REM están fuera del rango saludable en este periodo."
        } else if !deepOK {
            let direction = architecture.averageDeepShare < deepBand.low ? "por debajo" : "por encima"
            sentence = "Tu sueño profundo está \(direction) del rango saludable; el REM está bien."
        } else {
            let direction = architecture.averageRemShare < remBand.low ? "por debajo" : "por encima"
            sentence = "Tu REM está \(direction) del rango saludable; el sueño profundo está bien."
        }
        if continuityPoor {
            sentence += " También te despiertas más de lo ideal durante la noche."
        }
        // Uses the engine's own `personalDeviation` number rather than
        // inferring "better/worse than your own trend" from the absolute
        // score — the two questions are different (a 60/100 period can
        // still be an improvement over an even worse prior month).
        if let deviation = architecture.personalDeviation {
            if deviation >= 0.03 {
                sentence += " Mejor que tu propio promedio del último mes."
            } else if deviation <= -0.03 {
                sentence += " Peor que tu propio promedio del último mes."
            }
        }
        return sentence
    }


    private var personalBaselineCard: some View {
        let profile = PersonalBaselineEngine.profile(health: health, imports: imports)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                // Was "Normal para ti, hoy" — read as "today's number" when
                // it's actually the ~8-week median, causing exactly the
                // confusion this fixes: today's real HRV/pulso/sueño and
                // this habitual reference are two different questions.
                EterSectionHeader("Tu media habitual", eyebrow: "Tu línea base")
                Spacer()
                Text("\(profile.confidence)%").font(.title2.monospacedDigit().bold()).foregroundStyle(EterTheme.positive)
            }
            personalBaselineRow(profile.hrv, unit: "ms")
            personalBaselineRow(profile.restingHeartRate, unit: "ppm")
            personalBaselineRow(profile.sleep, unit: "h")
            Divider()
            if profile.muscleRecoveryHours.isEmpty {
                Text("Recuperación muscular todavía provisional: hacen falta más repeticiones del mismo ejercicio con diferentes intervalos de descanso.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                Text("Éter ya ha aprendido tiempos de recuperación de \(profile.muscleRecoveryHours.count) grupos musculares a partir de tu rendimiento posterior.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
            if twinStates.calibratedObservations > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Predicción → resultado", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        Spacer()
                        Text("\(twinStates.calibratedObservations) días · error medio \(twinStates.meanAbsoluteError ?? 0, specifier: "%.1f") pt")
                            .monospacedDigit()
                    }
                    if twinStates.calibration.observations >= 3 {
                        Text("Corrección aprendida: \(twinStates.calibration.scoreAdjustment, format: .number.sign(strategy: .always())) pt · confianza \(twinStates.calibration.confidence)%")
                            .monospacedDigit()
                    }
                }
                .font(.caption2.bold()).foregroundStyle(.secondary)
            } else {
                Text("El estado diario ya se guarda. Mañana podremos comparar la primera predicción con el readiness observado.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("La confianza aumenta con días válidos; los valores atípicos se controlan mediante una mediana robusta.")
                .font(.caption2).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func personalBaselineRow(_ metric: PersonalMetricBaseline, unit: String) -> some View {
        // Today's real reading is the number that actually changes day to
        // day and is worth a glance at — it used to be the smallest,
        // dimmest text on the whole card (caption2) while the ~8-week
        // habitual median, a much less time-critical reference number, was
        // the bold, prominent one. Flipped here: "Hoy" is the large
        // headline value, and — since "a number next to a number" is still
        // not much to look at — a range gauge underneath actually places
        // today's reading against the habitual band spatially, the same
        // "where does this fall in my normal" question a bullet chart
        // answers, instead of asking the reader to do that math from text.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.name).font(.subheadline.bold())
                Spacer()
                if let low = metric.lowerNormal, let high = metric.upperNormal {
                    Text("Habitual \(low.formatted(.number.precision(.fractionLength(0...1))))–\(high.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let expected = metric.expected {
                    Text("Habitual \(expected.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(metric.context).font(.caption2).foregroundStyle(.secondary)
            if let current = metric.current {
                // `metric.deviation` is already direction-corrected for this
                // specific signal (PersonalBaselineEngine's favorableHigh) —
                // positive always means favorable and negative always means
                // adverse, whether the metric itself is "higher is better"
                // (HRV, sleep) or "lower is better" (resting heart rate). A
                // small dead zone around zero stays neutral gray rather than
                // flipping green/red on noise indistinguishable from habitual.
                let favorable = Self.favorability(metric.deviation)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Hoy \(current.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                        .font(.title2.monospacedDigit().bold())
                    if let expected = metric.expected {
                        let delta = current - expected
                        if abs(delta) >= 0.05 {
                            Text("\(delta >= 0 ? "+" : "−")\(abs(delta).formatted(.number.precision(.fractionLength(1)))) vs. habitual")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(Self.color(for: favorable))
                        } else {
                            Text("= habitual").font(.subheadline.bold()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let low = metric.lowerNormal, let high = metric.upperNormal, let expected = metric.expected {
                    BaselineRangeGauge(low: low, high: high, expected: expected, current: current, favorable: favorable)
                        .padding(.top, 2).padding(.bottom, 4)
                }
            } else {
                Text("Sin lectura de hoy todavía.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // Shared so the delta text and the gauge dot always agree on the same
    // read. nil ("basically your habitual") stays neutral on purpose — see
    // personalBaselineRow's comment above.
    private static func favorability(_ deviation: Double?) -> Bool? {
        guard let deviation else { return nil }
        if deviation > 0.15 { return true }
        if deviation < -0.15 { return false }
        return nil
    }
    private static func color(for favorable: Bool?) -> Color {
        switch favorable {
        case true: return EterTheme.positive
        case false: return EterTheme.danger
        case nil: return .secondary
        }
    }

    // A bullet-chart-style range gauge: a soft band marks the habitual
    // [low, high], a thin tick marks the ~8-week median, and a dot marks
    // today's real reading — positioned on a shared scale so "is today
    // typical for me" is a glance, not arithmetic on two printed numbers.
    // The dot's color is the same favorable/adverse read the text above
    // uses (green favorable, red adverse, gray for "basically habitual"),
    // not merely "inside vs. outside the band" — a value can sit outside
    // the habitual band in the *good* direction (e.g. an unusually high
    // HRV) and that is not the same thing as an adverse reading. Domain
    // padding keeps the band from ever touching the track's edges, and
    // stretches to include `current` when today is itself the extreme.
    private struct BaselineRangeGauge: View {
        let low: Double
        let high: Double
        // Optional: personal-baseline rows tick the ~8-week median inside
        // the band, but a published reference band (e.g. sleep architecture's
        // deep/REM/continuity targets) has no personal "expected" point to
        // mark — the tick simply isn't drawn when this is nil.
        let expected: Double?
        let current: Double
        let favorable: Bool?

        private var domain: (min: Double, max: Double) {
            let span = max(high - low, 0.001)
            let pad = span * 0.4
            return (min(low, current) - pad, max(high, current) + pad)
        }

        private func x(_ value: Double, in width: CGFloat) -> CGFloat {
            let d = domain
            let fraction = (value - d.min) / max(d.max - d.min, 0.001)
            return CGFloat(min(1, max(0, fraction))) * width
        }

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 8)
                    Capsule().fill(Color.secondary.opacity(0.22))
                        .frame(width: max(6, x(high, in: width) - x(low, in: width)), height: 8)
                        .offset(x: x(low, in: width))
                    if let expected {
                        Rectangle().fill(Color.secondary.opacity(0.7))
                            .frame(width: 2, height: 14)
                            .offset(x: x(expected, in: width) - 1, y: -3)
                    }
                    Circle()
                        .fill(PhysiologicalHealthView.color(for: favorable))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(EterTheme.surface, lineWidth: 2))
                        .offset(x: x(current, in: width) - 6, y: -2)
                }
            }
            .frame(height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(favorable == true ? "Desviación favorable respecto a tu habitual" : favorable == false ? "Desviación adversa respecto a tu habitual" : "Prácticamente igual a tu habitual")
        }
    }


    private var trendCharts: some View {
        VStack(alignment: .leading, spacing: 16) {
            EterSectionHeader("Evolución fisiológica")
            if health.vo2MaxHistory.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("VO₂ máx. todavía sin registros", systemImage: "lungs.fill").font(.headline)
                    Text("El Apple Watch lo estima durante caminatas, carreras o senderismo al aire libre; el entrenamiento de fuerza no genera esta medida.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                }.cardStyle()
            } else {
                trendCard("VO₂ máx.", unit: "ml/kg/min", points: health.vo2MaxHistory, color: EterTheme.positive, favorableHigh: true)
            }
            trendCard("Variabilidad cardíaca", unit: "ms", points: health.hrvHistory, color: Color(red: 0.42, green: 0.33, blue: 0.72), favorableHigh: true)
            trendCard("Pulso en reposo", unit: "ppm", points: health.restingHeartRateHistory, color: Color(red: 0.78, green: 0.30, blue: 0.25), favorableHigh: false)
        }
    }

    private func trendCard(_ title: String, unit: String, points: [TrendPoint], color: Color, favorableHigh: Bool) -> some View {
        // Same personal-baseline reference every other rendering of these
        // metrics uses (personalBaselineCard's gauge, ContentView's
        // baselineCard) — this chart used to show the raw series with no
        // reference at all, so "is this good" had no answer here even
        // though the exact same question is answered elsewhere on this
        // same page.
        let recentValues = Array(points.suffix(56)).map(\.value)
        let mean = recentValues.isEmpty ? nil : recentValues.reduce(0, +) / Double(recentValues.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                DataTrustBadge(trust: HealthDataTrust.trend(title: title, points: points, health: health))
                if let last = points.last {
                    Text("\(last.value, specifier: "%.1f") \(unit)").font(.subheadline.bold()).foregroundStyle(color)
                }
            }
            if points.isEmpty {
                Text("Aún no hay datos suficientes").font(.caption).foregroundStyle(.secondary).frame(height: 80)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Fecha", point.date), y: .value(title, point.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Fecha", point.date), y: .value(title, point.value))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let mean {
                        RuleMark(y: .value("Tu media", mean))
                            .foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.clear); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.10)); AxisValueLabel() } }
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Evolución de \(title)")
                .accessibilityValue(points.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.value.formatted(.number.precision(.fractionLength(1)))) \(unit)" }.joined(separator: ". "))
                if let last = points.last, let mean {
                    let delta = last.value - mean
                    let favorability = Favorability.of(delta: delta, favorableHigh: favorableHigh, deadZone: mean * 0.02)
                    HStack(spacing: 6) {
                        Image(systemName: favorability == .neutral ? "equal.circle.fill" : delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(favorability.color).font(.caption2)
                        Text("\(abs(delta), specifier: "%.1f") \(unit) \((delta >= 0) == favorableHigh ? "por encima" : "por debajo") de tu media de las últimas 8 semanas (\(mean, specifier: "%.1f") \(unit)).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.cardStyle()
    }


    private func scoreColor(_ score: Int) -> Color {
        score >= 70 ? EterTheme.positive : score >= 45 ? EterTheme.negative : EterTheme.danger
    }
}
