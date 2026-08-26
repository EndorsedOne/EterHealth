import SwiftUI

struct GoalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var goals: GoalStore
    @State private var draft: AthletePlanProfile
    @State private var editingGoal: TrainingGoal?

    init(profile: AthletePlanProfile) { _draft = State(initialValue: profile) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Disponibilidad") {
                    Stepper("\(draft.trainingDaysPerWeek) días para entrenar", value: $draft.trainingDaysPerWeek, in: 1...7)
                    Toggle("Tengo gimnasio disponible", isOn: $draft.gymAvailable)
                    Picker("Día de tirada larga", selection: $draft.preferredLongRunWeekday) {
                        ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                            Text(name.capitalized).tag(index + 1)
                        }
                    }
                }
                Section {
                    Picker("Ritmo de progresión", selection: Binding(
                        get: { draft.effectiveProgressionPace },
                        set: { draft.progressionPace = $0 }
                    )) {
                        ForEach(ProgressionPace.allCases) { pace in Text(pace.rawValue).tag(pace) }
                    }.pickerStyle(.segmented)
                    Text(draft.effectiveProgressionPace.explanation).font(.caption).foregroundStyle(.secondary)
                    // "Guardar" is the real confirmation step here (unlike
                    // the card's own picker, which commits immediately) —
                    // this warning just makes sure it's seen before that tap.
                    if draft.effectiveProgressionPace == .aggressive {
                        Label("Zona de riesgo elevado de lesión (carga por encima de 1.55, Gabbett et al.) — el plan te avisará cada vez que use ese margen extra.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold()).foregroundStyle(EterTheme.danger)
                    }
                } header: {
                    Text("Progresión")
                } footer: {
                    Text("También puedes cambiarlo directamente desde la tarjeta \"Tres futuros, 8 semanas\" en Rendimiento. Decide cuánto margen dejas bajo tu propio límite de sobrecarga antes de que el plan te pida descansar hoy.")
                }
                Section {
                    TextField("FC máxima", value: $draft.maximumHeartRate, format: .number)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Calibración cardíaca")
                } footer: {
                    Text("Introduce una FC máxima medida en una prueba o sesión fiable. Si se deja vacía, se estima con tu edad y se muestra con menor confianza.")
                }
                Section {
                    Toggle("Tengo zonas de una prueba de lactato", isOn: Binding(
                        get: { draft.manualHeartRateZones != nil },
                        set: { enabled in
                            draft.manualHeartRateZones = enabled
                                ? (draft.manualHeartRateZones ?? HeartRateZoneBoundaries(z1z2: 120, z2z3: 140, z3z4: 155, z4z5: 168))
                                : nil
                        }
                    ))
                    if draft.manualHeartRateZones != nil {
                        let zones = Binding<HeartRateZoneBoundaries>(
                            get: { draft.manualHeartRateZones ?? HeartRateZoneBoundaries(z1z2: 120, z2z3: 140, z3z4: 155, z4z5: 168) },
                            set: { draft.manualHeartRateZones = $0 }
                        )
                        heartRateZoneField("Z1 / Z2", value: zones.z1z2)
                        heartRateZoneField("Z2 / Z3", value: zones.z2z3)
                        heartRateZoneField("Z3 / Z4", value: zones.z3z4)
                        heartRateZoneField("Z4 / Z5", value: zones.z4z5)
                    }
                } header: {
                    Text("Zonas por prueba de lactato")
                } footer: {
                    Text("Una prueba de lactato en laboratorio mide directamente dónde cambian tus zonas de esfuerzo a partir de tu curva real de lactato en sangre — es más precisa que cualquier estimación por edad o FC máxima, y te la recomendamos si entrenas la intensidad con regularidad. Pide al laboratorio las pulsaciones de corte entre zonas e introdúcelas aquí; en cuanto las guardes, sustituyen a la estimación en todo éter.")
                }
                Section {
                    DatePicker("Fecha de nacimiento",
                               selection: Binding(get: { draft.birthDate ?? Date() }, set: { draft.birthDate = $0 }),
                               displayedComponents: .date)
                } header: {
                    Text("Datos personales")
                } footer: {
                    Text("Solo se usa para calcular tu edad estimada por biomarcadores (PhenoAge) en la pestaña Salud.")
                }
                Section {
                    ForEach(draft.goals) { goal in
                        Button { editingGoal = goal } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(goal.title).foregroundStyle(.primary)
                                    Text(goalSubtitle(goal)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(goal.priority.rawValue).font(.caption2.bold())
                                    .foregroundStyle(goal.priority == .primary ? .orange : .teal)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { draft.goals.remove(atOffsets: $0) }
                    Button { editingGoal = newGoal() } label: { Label("Añadir objetivo", systemImage: "plus") }
                } header: { Text("Retos y marcas") }
                  footer: { Text("Los objetivos principales gobiernan el bloque. Los secundarios orientan el estímulo y los de mantenimiento evitan perder capacidades importantes.") }
            }
            .navigationTitle("Plan del gemelo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { goals.save(draft); dismiss() }.bold() }
            }
            .sheet(item: $editingGoal) { goal in
                GoalDetailEditor(goal: goal) { updated in
                    if let index = draft.goals.firstIndex(where: { $0.id == updated.id }) { draft.goals[index] = updated }
                    else { draft.goals.append(updated) }
                }
            }
        }
    }

    private func heartRateZoneField(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("ppm", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
            Text("ppm").foregroundStyle(.secondary)
        }
    }

    private func goalSubtitle(_ goal: TrainingGoal) -> String {
        [goal.date?.formatted(date: .abbreviated, time: .omitted), goal.displayTarget, goal.isActive ? nil : "Pausado"]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private func newGoal() -> TrainingGoal {
        TrainingGoal(id: UUID(), kind: .custom, title: "Nuevo reto", date: Calendar.current.date(byAdding: .month, value: 2, to: Date()), targetValue: nil, unit: "", priority: .secondary, isActive: true)
    }
}

private struct GoalDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var goal: TrainingGoal
    let onSave: (TrainingGoal) -> Void

    var body: some View {
        NavigationStack {
            Form {
                // Flat list, each tracked lift as its own entry — grouping
                // them under a "Powerlifting" style with a second picker
                // underneath added a layer of indirection nobody asked
                // for; picking "Press banca" directly is simpler.
                Picker("Tipo", selection: $goal.kind) {
                    ForEach(TrainingGoalKind.allCases) { Text($0.rawValue).tag($0) }
                }.onChange(of: goal.kind) { _, kind in
                    if goal.title == "Nuevo reto" || TrainingGoalKind.allCases.map(\.rawValue).contains(goal.title) { goal.title = kind.rawValue }
                    goal.unit = kind.defaultUnit
                    if kind.usesDate && goal.date == nil { goal.date = Calendar.current.date(byAdding: .month, value: 2, to: Date()) }
                    // usesDate only ever added a date when switching TO a
                    // dated kind — switching AWAY from one (e.g. "Otro
                    // reto" → "Peso muerto") left the old date attached,
                    // just hidden from this form. TrainingPlanEngine
                    // doesn't know the field is hidden — it still reads
                    // goal.date directly and periodizes toward it, which is
                    // exactly how a strength goal ended up treated like a
                    // race with its own taper block.
                    if !kind.usesDate { goal.date = nil }
                }
                TextField("Nombre", text: $goal.title)
                Toggle("Objetivo activo", isOn: $goal.isActive)
                Picker("Prioridad", selection: $goal.priority) {
                    ForEach(GoalPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                if goal.kind.usesDate {
                    DatePicker("Fecha", selection: Binding(get: { goal.date ?? Date() }, set: { goal.date = $0 }), displayedComponents: .date)
                }
                if goal.kind == .triathlon {
                    Picker("Distancia", selection: Binding(
                        get: { goal.triathlonDistance ?? .olympic },
                        set: { goal.triathlonDistance = $0 }
                    )) {
                        ForEach(TriathlonDistance.allCases) { Text($0.rawValue).tag($0) }
                    }
                } else if goal.kind == .ironman {
                    LabeledContent("Distancia", value: TriathlonDistance.full.rawValue)
                }
                if goal.kind == .hyrox {
                    Picker("División", selection: Binding(
                        get: { goal.hyroxDivision ?? .open },
                        set: { goal.hyroxDivision = $0 }
                    )) {
                        ForEach(HyroxDivision.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                if goal.kind == .triathlon || goal.kind == .ironman {
                    let course = Binding<EventCourseDetails>(
                        get: { goal.courseDetails ?? EventCourseDetails() },
                        set: { goal.courseDetails = $0 }
                    )
                    Section {
                        TextField("Desnivel del recorrido (m)", value: course.courseElevationMeters, format: .number)
                            .keyboardType(.numberPad)
                        Picker("Tipo de agua", selection: course.waterType) {
                            Text("Sin especificar").tag(WaterType?.none)
                            ForEach(WaterType.allCases) { Text($0.rawValue).tag(Optional($0)) }
                        }
                        TextField("Temperatura del agua prevista (°C)", value: course.expectedWaterTemperatureCelsius, format: .number)
                            .keyboardType(.decimalPad)
                        TextField("Temperatura del aire prevista (°C)", value: course.expectedAirTemperatureCelsius, format: .number)
                            .keyboardType(.decimalPad)
                        TextField("Notas de transición (kit, orden, nutrición)", text: course.transitionNotes, axis: .vertical)
                            .lineLimit(2...4)
                    } header: {
                        Text("Detalles del recorrido")
                    } footer: {
                        Text("Opcional. Con esto, el forecast avisa de desnivel relevante y de si el neopreno es probablemente legal por temperatura del agua, y tus notas de transición aparecen directamente en las sesiones de brick.")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        TextField("Marca objetivo", value: $goal.targetValue, format: .number).keyboardType(.decimalPad)
                        TextField("Unidad", text: $goal.unit).frame(minWidth: 70)
                    }
                    VStack {
                        TextField("Marca objetivo", value: $goal.targetValue, format: .number).keyboardType(.decimalPad)
                        TextField("Unidad", text: $goal.unit)
                    }
                }
            }
            .navigationTitle("Editar objetivo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { onSave(goal); dismiss() }.bold().disabled(goal.title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }
}
