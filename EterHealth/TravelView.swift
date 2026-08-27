import SwiftUI

// PR14. La UI de "Viajes": viaje actual con su fase, línea temporal, alta
// manual e historial. Deliberadamente sin API de aeropuertos: el atleta tiene
// el billete delante y teclearlo son cuatro campos, mientras una integración
// externa añadiría una dependencia de red, credenciales y un modo de fallo
// nuevo para resolver un problema que no tenemos.
//
// Este PR NO conecta el viaje con la fisiología ni con la decisión de
// entrenamiento: eso es TravelImpactEngine (PR15). Aquí se puede dar de alta
// un viaje y ver su fase, y nada más — a propósito, para que el PR que sí
// mueve los números del gemelo llegue solo y con sus propios tests.

private let phaseOrder: [TravelPhase] = [
    .preDeparture, .outboundTransit, .destinationAdaptation,
    .destinationStable, .returnTransit, .homeReadaptation, .recovered
]

struct TravelView: View {
    /// Un solo `item:` para las dos hojas de esta pantalla. DOS modificadores
    /// `.sheet` sobre la misma vista no es un patrón soportado de forma
    /// fiable en SwiftUI —el segundo puede impedir que se presente el
    /// primero— y es el mismo enum que ContentView ya usa para lo mismo.
    private enum Editor: Identifiable {
        case new
        case existing(TravelEpisode)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let episode): return episode.id.uuidString
            }
        }
        var episode: TravelEpisode? {
            switch self {
            case .new: return nil
            case .existing(let episode): return episode
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var travel: TravelEpisodeStore
    @State private var editor: Editor?
    @State private var episodePendingDeletion: UUID?

    /// `@State` y no un `Date()` calculado en el body. Un `Date()` dentro del
    /// body devuelve un valor distinto en cada evaluación, así que la vista
    /// deja de ser idempotente y SwiftUI puede quedarse invalidándose sola —
    /// que es exactamente lo que impedía a esta hoja presentarse en cuanto
    /// había un episodio que renderizar (con la lista vacía no se llegaba a
    /// usar). Las fases cambian en escala de horas y días: fijar el instante
    /// al abrir la pantalla es correcto, no una aproximación.
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                if let current = travel.currentEpisode(at: now) {
                    Section("Viaje actual") {
                        CurrentTravelCard(episode: current, now: now)
                        TravelTimelineStrip(episode: current, now: now)
                        Button("Editar") { editor = .existing(current) }
                        Button("Cancelar este viaje", role: .destructive) { travel.cancel(id: current.id) }
                    }
                } else {
                    Section {
                        Text("No hay ningún viaje en curso. Da de alta uno cuando tengas los vuelos: el gemelo separa el impacto del vuelo del desajuste horario, y trata la vuelta como su propia fase.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                let history = travel.completedEpisodes(at: now)
                if !history.isEmpty {
                    Section("Historial") {
                        ForEach(history) { episode in
                            // Mismo motivo que en TimeZonePickerView: dentro de
                            // un List, el área tappable se declara, no se
                            // hereda del estilo del botón.
                            CompletedTravelRow(episode: episode)
                                .contentShape(Rectangle())
                                .onTapGesture { editor = .existing(episode) }
                                .swipeActions {
                                    Button("Eliminar", role: .destructive) { episodePendingDeletion = episode.id }
                                }
                        }
                    }
                }

                let cancelled = travel.episodes.filter(\.isCancelled)
                if !cancelled.isEmpty {
                    Section {
                        ForEach(cancelled) { episode in
                            HStack {
                                Text(episode.title).foregroundStyle(.secondary)
                                Spacer()
                                Text("Cancelado").font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Eliminar", role: .destructive) { episodePendingDeletion = episode.id }
                            }
                        }
                    } header: {
                        Text("Cancelados")
                    } footer: {
                        Text("Un viaje cancelado no entra en el histórico del que el gemelo aprende: no hay nada que medir en un viaje que no se hizo.")
                    }
                }
            }
            .navigationTitle("Viajes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = .new } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editor) { editor in
                TravelEpisodeEditorView(episode: editor.episode).environmentObject(travel)
            }
            .onAppear { now = Date() }
            .alert("Eliminar viaje", isPresented: Binding(
                get: { episodePendingDeletion != nil },
                set: { if !$0 { episodePendingDeletion = nil } }
            )) {
                Button("Eliminar", role: .destructive) {
                    if let id = episodePendingDeletion { travel.delete(id: id) }
                    episodePendingDeletion = nil
                }
                Button("Cancelar", role: .cancel) { episodePendingDeletion = nil }
            } message: {
                Text("Se elimina el episodio y deja de contar para el histórico de viajes. No afecta a tus datos de sueño ni de entrenamiento.")
            }
        }
    }
}

// MARK: - Viaje actual

private struct CurrentTravelCard: View {
    let episode: TravelEpisode
    let now: Date

    private var phase: TravelPhase { episode.phase(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title).font(.title3).fontDesign(.serif)
                    Text(routeDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(phase.rawValue).font(.subheadline.bold())
                    if let remaining = remainingDescription {
                        Text(remaining).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            // Los dos números que el brief pide separados explícitamente. La
            // magnitud fisiológica (fatiga de viaje y desajuste circadiano
            // como estado que decae) llega en PR15; aquí se muestran los
            // hechos estructurales de los que saldrán, que ya son útiles y no
            // afirman ninguna recuperación.
            HStack(alignment: .top, spacing: 18) {
                metric("Desajuste horario", value: shiftDescription, detail: directionDescription)
                metric("Tránsito", value: transitDescription, detail: transitDetail)
            }
            if episode.resolvedStayPolicy == .keepHomeSchedule {
                Label("Estancia corta: se mantiene el horario de origen, así que no se estima adaptación en destino ni readaptación al volver.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !episode.declaredZonesMatchFlights {
                Label("Los husos declarados no coinciden con los de los vuelos dados de alta. Revisa el viaje: el desajuste se calcula con los vuelos.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(EterTheme.danger)
            }
            Text("Fase y duraciones estimadas con las tasas de re-sincronización de la literatura (≈1 h/día hacia el este, ≈1.5 h/día hacia el oeste). Es un punto de partida, no una medición tuya.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            Text(value).font(.headline)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var routeDescription: String {
        [TravelFormat.zoneName(episode.homeTimeZoneID), TravelFormat.zoneName(episode.destinationTimeZoneID)]
            .joined(separator: " → ")
    }

    private var shiftDescription: String {
        let hours = episode.outboundShiftHours
        guard hours != 0 else { return "Sin cambio" }
        return String(format: "%+.0f h", hours)
    }

    private var directionDescription: String? {
        let hours = episode.outboundShiftHours
        guard hours != 0 else { return nil }
        return hours > 0
            ? "Hacia el este · hay que adelantar el reloj, la dirección que más cuesta"
            : "Hacia el oeste · hay que retrasarlo, la dirección más llevadera"
    }

    private var transitDescription: String {
        guard let duration = relevantTransit else { return "—" }
        return TravelFormat.duration(duration)
    }

    private var transitDetail: String? {
        var parts: [String] = []
        let layovers = phase == .returnTransit || phase == .homeReadaptation
            ? episode.returnLayovers : episode.outboundLayovers
        if layovers > 0 { parts.append("\(layovers) escala\(layovers == 1 ? "" : "s")") }
        let overnight = phase == .returnTransit || phase == .homeReadaptation
            ? episode.hasOvernightReturn : episode.hasOvernightOutbound
        if overnight { parts.append("vuelo nocturno") }
        return parts.isEmpty ? "Sin escalas, vuelo diurno" : parts.joined(separator: " · ")
    }

    /// El tránsito que importa según dónde estemos: la ida hasta que se
    /// vuelve, la vuelta a partir de ahí.
    private var relevantTransit: TimeInterval? {
        switch phase {
        case .returnTransit, .homeReadaptation, .recovered:
            return episode.returnTransitDuration ?? episode.outboundTransitDuration
        default:
            return episode.outboundTransitDuration
        }
    }

    private var remainingDescription: String? {
        guard let end = episode.currentPhaseEnd(at: now), end > now else { return nil }
        return "hasta " + end.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Línea temporal

private struct TravelTimelineStrip: View {
    let episode: TravelEpisode
    let now: Date

    var body: some View {
        let current = episode.phase(at: now)
        VStack(alignment: .leading, spacing: 8) {
            Text("LÍNEA TEMPORAL").font(.caption2.bold()).tracking(EterTheme.eyebrowTracking).foregroundStyle(.secondary)
            if current == .cancelled {
                Text("Viaje cancelado.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(phaseOrder) { phase in
                        let reached = (current.timelineIndex ?? 0) >= (phase.timelineIndex ?? 0)
                        let isCurrent = phase == current
                        VStack(spacing: 4) {
                            Capsule()
                                .fill(reached ? Color.accentColor : Color.primary.opacity(0.12))
                                .frame(height: isCurrent ? 6 : 3)
                            Text(phase.rawValue)
                                .font(.system(size: 9, weight: isCurrent ? .bold : .regular))
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
                if let detail = phaseDetail(current) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func phaseDetail(_ phase: TravelPhase) -> String? {
        switch phase {
        case .destinationAdaptation:
            return "Adaptación estimada: \(TravelFormat.days(episode.destinationAdaptationDays)) desde la llegada."
        case .homeReadaptation:
            return "Readaptación estimada: \(TravelFormat.days(episode.homeReadaptationDays)) desde la vuelta — su propia fase, con la tasa de la dirección contraria a la ida."
        case .destinationStable:
            return episode.resolvedStayPolicy == .keepHomeSchedule
                ? "Sin adaptación en destino: se mantiene el horario de origen."
                : "Estable en hora local del destino."
        default:
            return nil
        }
    }
}

// MARK: - Fila de historial

private struct CompletedTravelRow: View {
    let episode: TravelEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(episode.title).font(.subheadline.bold())
                Spacer()
                if let arrival = episode.homeArrival {
                    Text(arrival.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts = [String(format: "%+.0f h ida", episode.outboundShiftHours)]
        if let stay = episode.stayDuration {
            parts.append("\(Int((stay / 86_400).rounded())) días de estancia")
        }
        if episode.resolvedStayPolicy == .keepHomeSchedule { parts.append("horario de origen") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Alta y edición

struct TravelEpisodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var travel: TravelEpisodeStore

    @State private var draft: TravelEpisode
    @State private var declaresStayEnd: Bool
    @State private var stayEndDate: Date
    @State private var automaticPolicy: Bool

    private let isNew: Bool

    init(episode: TravelEpisode?) {
        let resolved = episode ?? TravelEpisode(
            title: "",
            homeTimeZoneID: TimeZone.current.identifier,
            destinationTimeZoneID: TimeZone.current.identifier
        )
        _draft = State(initialValue: resolved)
        _declaresStayEnd = State(initialValue: resolved.expectedStayEndDate != nil)
        _stayEndDate = State(initialValue: resolved.expectedStayEndDate ?? Date())
        _automaticPolicy = State(initialValue: resolved.declaredStayPolicy == nil)
        isNew = episode == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Viaje") {
                    TextField("Destino (p. ej. Tokio)", text: $draft.title)
                    NavigationLink {
                        TimeZonePickerView(selection: $draft.homeTimeZoneID, title: "Huso de casa")
                    } label: {
                        LabeledContent("Casa", value: TravelFormat.zoneName(draft.homeTimeZoneID))
                    }
                    NavigationLink {
                        TimeZonePickerView(selection: $draft.destinationTimeZoneID, title: "Huso del destino")
                    } label: {
                        LabeledContent("Destino", value: TravelFormat.zoneName(draft.destinationTimeZoneID))
                    }
                }

                FlightListSection(title: "Ida", flights: $draft.outboundFlights,
                                  defaultOrigin: draft.homeTimeZoneID, defaultDestination: draft.destinationTimeZoneID)

                FlightListSection(title: "Vuelta", flights: $draft.returnFlights,
                                  defaultOrigin: draft.destinationTimeZoneID, defaultDestination: draft.homeTimeZoneID)

                if draft.returnFlights.isEmpty {
                    Section {
                        Toggle("Sé cuándo termina la estancia", isOn: $declaresStayEnd)
                        if declaresStayEnd {
                            DatePicker("Fin previsto", selection: $stayEndDate)
                                .environment(\.timeZone, TimeZone(identifier: draft.destinationTimeZoneID) ?? .current)
                        }
                    } footer: {
                        Text("Sólo hace falta mientras no haya vuelos de vuelta. Cuando los des de alta, el fin de la estancia es su primera salida.")
                    }
                }

                Section {
                    Toggle("Política de horario automática", isOn: $automaticPolicy)
                    if !automaticPolicy {
                        Picker("En destino", selection: Binding(
                            get: { draft.declaredStayPolicy ?? draft.resolvedStayPolicy },
                            set: { draft.declaredStayPolicy = $0 }
                        )) {
                            ForEach(TravelStayPolicy.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.inline)
                    } else {
                        LabeledContent("Resuelta como", value: draft.resolvedStayPolicy.rawValue)
                    }
                } header: {
                    Text("Horario en destino")
                } footer: {
                    Text("Automática: se mantiene el horario de origen cuando la estancia es más corta que 48 h o que la mitad de lo que costaría re-sincronizarse. Con 12 h de diferencia, cuatro días no llegan ni a medio camino, y empezar a adaptarse sólo garantiza llegar desincronizado a los dos sitios.")
                }

                Section("Notas") {
                    TextField("Opcional", text: $draft.note, axis: .vertical)
                }

                if !draft.declaredZonesMatchFlights {
                    Section {
                        Label("Los husos declarados arriba no coinciden con los de los vuelos. Puedes guardar igual: el desajuste horario se calcula siempre con los vuelos reales.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(EterTheme.danger)
                    }
                }
            }
            .navigationTitle(isNew ? "Nuevo viaje" : "Editar viaje")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.outboundFlights.allSatisfy(\.isValid)
            && draft.returnFlights.allSatisfy(\.isValid)
    }

    private func save() {
        var episode = draft
        episode.title = episode.title.trimmingCharacters(in: .whitespaces)
        episode.expectedStayEndDate = (declaresStayEnd && draft.returnFlights.isEmpty) ? stayEndDate : nil
        if automaticPolicy { episode.declaredStayPolicy = nil }
        // Reconstruido por el init para que los tramos queden ordenados: la
        // UI permite darlos de alta en cualquier orden.
        travel.save(TravelEpisode(
            id: episode.id, title: episode.title,
            homeTimeZoneID: episode.homeTimeZoneID, destinationTimeZoneID: episode.destinationTimeZoneID,
            outboundFlights: episode.outboundFlights, returnFlights: episode.returnFlights,
            expectedStayEndDate: episode.expectedStayEndDate, declaredStayPolicy: episode.declaredStayPolicy,
            isCancelled: episode.isCancelled, note: episode.note
        ))
        dismiss()
    }
}

private struct FlightListSection: View {
    let title: String
    @Binding var flights: [FlightSegment]
    let defaultOrigin: String
    let defaultDestination: String

    var body: some View {
        Section {
            ForEach($flights) { $flight in
                FlightSegmentEditor(flight: $flight)
            }
            .onDelete { flights.remove(atOffsets: $0) }
            Button {
                // El nuevo tramo arranca del último destino conocido, que es
                // lo que hace usable una escala: Madrid→Doha, y el siguiente
                // ya propone Doha como origen.
                let origin = flights.last?.destinationTimeZoneID ?? defaultOrigin
                let departure = flights.last?.arrival.addingTimeInterval(2 * 3_600) ?? Date()
                flights.append(FlightSegment(
                    departure: departure, arrival: departure.addingTimeInterval(3 * 3_600),
                    originTimeZoneID: origin,
                    destinationTimeZoneID: flights.isEmpty ? defaultDestination : defaultDestination
                ))
            } label: {
                Label(flights.isEmpty ? "Añadir vuelo" : "Añadir escala", systemImage: "plus.circle")
            }
        } header: {
            Text(title)
        } footer: {
            if flights.isEmpty {
                Text(title == "Ida" ? "Sin la ida no hay episodio que seguir." : "Puedes dejarla vacía y añadirla cuando la tengas: la vuelta genera su propia fase de readaptación.")
            } else {
                Text(summary)
            }
        }
    }

    private var summary: String {
        let shift = flights.reduce(0.0) { $0 + $1.offsetShiftHours }
        var parts = [String(format: "Desplazamiento %+.0f h", shift)]
        if flights.count > 1 { parts.append("\(flights.count - 1) escala\(flights.count == 2 ? "" : "s")") }
        if flights.contains(where: \.isOvernight) { parts.append("nocturno") }
        if let first = flights.first, let last = flights.last, last.arrival > first.departure {
            parts.append("puerta a puerta " + TravelFormat.duration(last.arrival.timeIntervalSince(first.departure)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct FlightSegmentEditor: View {
    @Binding var flight: FlightSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                TimeZonePickerView(selection: $flight.originTimeZoneID, title: "Origen")
            } label: {
                LabeledContent("Origen", value: TravelFormat.zoneName(flight.originTimeZoneID))
            }
            // La hora se introduce y se muestra en el huso del tramo, no en el
            // del dispositivo: es la hora que el atleta lee en el billete.
            DatePicker("Salida", selection: $flight.departure)
                .environment(\.timeZone, flight.originTimeZone ?? .current)
            NavigationLink {
                TimeZonePickerView(selection: $flight.destinationTimeZoneID, title: "Destino")
            } label: {
                LabeledContent("Destino", value: TravelFormat.zoneName(flight.destinationTimeZoneID))
            }
            DatePicker("Llegada", selection: $flight.arrival)
                .environment(\.timeZone, flight.destinationTimeZone ?? .current)
            if flight.isValid {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("La llegada tiene que ser posterior a la salida.")
                    .font(.caption2).foregroundStyle(EterTheme.danger)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = [TravelFormat.duration(flight.duration), String(format: "%+.0f h", flight.offsetShiftHours)]
        if flight.isOvernight {
            parts.append(String(format: "nocturno · %.0f h de tu ventana de sueño", flight.sleepWindowOverlapHours))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Selector de huso

struct TimeZonePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let title: String
    @State private var query = ""

    /// Los identificadores IANA que el sistema conoce. Se filtran por texto
    /// en vez de agruparlos por continente: son ~600 y buscar "tok" es más
    /// rápido que navegar dos niveles.
    private var identifiers: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !query.isEmpty else { return all }
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return all.filter {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
        }
    }

    var body: some View {
        // `contentShape` + `onTapGesture` y no un Button con
        // `.buttonStyle(.plain)`: probado en el simulador, con `.plain` dentro
        // de un List `searchable` la fila deja de responder al tap (sólo
        // responde el texto, y a veces ni eso). El contentShape declara el
        // área tappable explícitamente en vez de dejarla a merced del estilo.
        List(identifiers, id: \.self) { identifier in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TravelFormat.zoneName(identifier))
                    Text(identifier).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(TravelFormat.currentOffset(identifier)).font(.caption).foregroundStyle(.secondary)
                if identifier == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = identifier
                dismiss()
            }
        }
        .searchable(text: $query, prompt: "Buscar huso")
        .navigationTitle(title)
    }
}

// MARK: - Formato

enum TravelFormat {
    /// "Asia/Tokyo" → "Tokyo". El identificador completo se muestra debajo en
    /// el selector, así que aquí gana la legibilidad.
    static func zoneName(_ identifier: String) -> String {
        identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
    }

    static func currentOffset(_ identifier: String, at date: Date = Date()) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "—" }
        let hours = Double(zone.secondsFromGMT(for: date)) / 3_600
        return hours == hours.rounded() ? String(format: "GMT%+.0f", hours) : String(format: "GMT%+.1f", hours)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    static func days(_ value: Double) -> String {
        value < 1.5 ? String(format: "%.1f días", value) : "\(Int(value.rounded())) días"
    }
}
