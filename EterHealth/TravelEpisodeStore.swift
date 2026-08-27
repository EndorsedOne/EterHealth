import Foundation

// PR14. La persistencia de los episodios de viaje, FUERA de TwinCore — igual
// que GoalStore, InjuryStore o DailyCheckInStore. TwinCore recibe episodios
// como valores y nunca lee esto.
//
// Sin `static let shared`: el brief del proyecto prohíbe singletons nuevos, y
// ya existe el precedente de la forma correcta (HealthStore, ImportStore,
// DailyCheckInStore se crean en EterHealthApp como @StateObject y viajan por
// @EnvironmentObject). Los `.shared` que quedan en el repo son de antes de esa
// regla, no el patrón a copiar.
@MainActor
final class TravelEpisodeStore: ObservableObject {
    @Published private(set) var episodes: [TravelEpisode] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("travel-episodes.json")
    }

    init() { load() }

    /// Las tasas aprendidas de los propios episodios que este store ya tiene.
    ///
    /// Existe porque decidir "cuál es el viaje actual" con el PRIOR mientras
    /// el gemelo evalúa con las tasas aprendidas era un desacuerdo real: si la
    /// tasa aprendida es más LENTA que el prior, la readaptación aprendida
    /// dura más, el prior da el episodio por `.recovered` antes de tiempo y el
    /// store deja de pasárselo al motor — que se queda sin episodio mientras
    /// todavía quedaba desajuste que contar.
    ///
    /// Se resuelve aquí y no como parámetro porque TravelLearningEngine.profile
    /// es una función pura de `episodes`, que es justo lo que este store posee.
    /// Así todos los call sites lo heredan sin cambiar.
    private var learnedRates: ReentrainmentRates {
        TravelLearningEngine.profile(episodes: episodes).rates
    }

    /// Alta y edición son la misma operación, con el id como identidad — el
    /// mismo criterio que DailyCheckInStore.save aplica con el día.
    ///
    /// Guardarraíl: una medición ya guardada NUNCA se pierde por un save que
    /// no la traiga. El editor la arrastra explícitamente, pero eso depende de
    /// que cada call site se acuerde, y olvidarlo una vez ya costó borrar
    /// aprendizaje histórico al editar una nota. Aquí la pérdida es imposible
    /// por construcción: para borrar una medición hay que borrar el episodio.
    func save(_ episode: TravelEpisode) {
        var incoming = episode
        if incoming.measuredOutcome == nil,
           let existing = episodes.first(where: { $0.id == episode.id })?.measuredOutcome {
            incoming.measuredOutcome = existing
        }
        episodes.removeAll { $0.id == episode.id }
        episodes.append(incoming)
        sortAndPersist()
    }

    func delete(id: UUID) {
        episodes.removeAll { $0.id == id }
        sortAndPersist()
    }

    /// Cancelar no es borrar: un viaje que no ocurrió sigue siendo
    /// información (había una preparación, y puede haber señales alteradas por
    /// ella) y sobre todo NO debe contarse como episodio del que aprender. Por
    /// eso `isCancelled` es estado real y la fase terminal es `.cancelled`.
    func cancel(id: UUID) {
        guard var episode = episodes.first(where: { $0.id == id }) else { return }
        episode.isCancelled = true
        save(episode)
    }

    /// El viaje ACTUAL: el que sigue vivo en esta fecha. Cuando hay varios
    /// —dos viajes seguidos, o uno futuro dado de alta mientras se readapta
    /// del anterior— gana el que ya ha empezado; entre dos empezados, el más
    /// reciente. Nunca devuelve uno cancelado ni uno ya recuperado.
    ///
    /// Un solo sitio decide esto para que la tarjeta de "Viaje actual", la
    /// línea temporal y (en PR15) lo que llega al gemelo no puedan elegir
    /// episodios distintos.
    func currentEpisode(at date: Date = Date()) -> TravelEpisode? {
        let live = episodes.filter { $0.phase(at: date, rates: learnedRates).isActive }
        let started = live.filter { episode in
            guard let departure = episode.outboundDeparture else { return false }
            return departure <= date
        }
        if let mostRecentStarted = started.max(by: { ($0.outboundDeparture ?? .distantPast) < ($1.outboundDeparture ?? .distantPast) }) {
            return mostRecentStarted
        }
        // Ninguno empezado: el próximo por salir, que es el que la fase
        // `.preDeparture` describe.
        return live.min { ($0.outboundDeparture ?? .distantFuture) < ($1.outboundDeparture ?? .distantFuture) }
    }

    /// El episodio que el GEMELO debe evaluar. No es lo mismo que
    /// `currentEpisode`, y confundirlos dejaba muerta la medición tardía:
    ///
    /// `currentEpisode` responde "cuál es mi viaje ahora" y excluye los
    /// recuperados, que es lo correcto para la tarjeta — un viaje terminado no
    /// es el viaje actual. Pero TravelImpactEngine sí sigue buscando la
    /// estabilidad de la vuelta dentro de la ventana de gracia aunque la fase
    /// ya haya cerrado (ver TravelEpisode.stabilityMeasurableUntil), y si el
    /// dashboard sólo inyecta `currentEpisode`, ese episodio nunca llega al
    /// motor y la medición tardía NO OCURRE EN USO REAL. El código estaba
    /// escrito y era inalcanzable.
    ///
    /// Prioridad: primero el activo, porque es el único que tiene impacto de
    /// verdad. Con un viaje activo y otro recuperado-pendiente a la vez se
    /// pierde la medición tardía del segundo — una esquina rara (dos viajes
    /// solapados) en la que preferir el impacto real es lo correcto.
    func episodeForEvaluation(at date: Date = Date()) -> TravelEpisode? {
        if let active = currentEpisode(at: date) { return active }
        return episodes
            .filter { episode in
                guard episode.phase(at: date, rates: learnedRates) == .recovered,
                      let window = episode.stabilityMeasurableUntil(leg: .homeReturn, rates: learnedRates)
                else { return false }
                return date <= window
            }
            .max { ($0.homeArrival ?? .distantPast) < ($1.homeArrival ?? .distantPast) }
    }

    /// Guarda la estabilidad que el motor acaba de confirmar, si la hay.
    ///
    /// Vive aquí y no en la vista a propósito: cuando esta decisión estaba
    /// dentro de ContentView no había forma de testear el recorrido completo
    /// (store → contexto → gemelo → persistencia), y el test que la cubría
    /// ejercía el motor en aislamiento — que es exactamente por lo que el
    /// camino muerto de la medición tardía pasó la revisión anterior.
    func recordStabilityIfConfirmed(_ impact: TravelImpact, at date: Date = Date()) {
        guard let stabilizedAt = impact.stabilizedAt,
              let episode = episodeForEvaluation(at: date) else { return }
        // `.recovered` cuenta como tramo de vuelta: es la fase en la que la
        // ventana de gracia sigue abierta.
        let leg: TravelLeg = [.homeReadaptation, .recovered].contains(impact.phase) ? .homeReturn : .outbound
        guard let anchor = leg == .homeReturn ? episode.homeArrival : episode.destinationArrival,
              stabilizedAt >= anchor else { return }
        recordStability(episodeID: episode.id, leg: leg,
                        days: stabilizedAt.timeIntervalSince(anchor) / 86_400,
                        confounders: impact.confounders, at: date)
    }

    /// Los episodios ya terminados, del más reciente al más antiguo — la
    /// entrada del histórico. Excluye los cancelados: no hay nada que medir en
    /// un viaje que no se hizo.
    func completedEpisodes(at date: Date = Date()) -> [TravelEpisode] {
        episodes.filter { $0.phase(at: date, rates: learnedRates) == .recovered }
            .sorted { ($0.homeArrival ?? .distantPast) > ($1.homeArrival ?? .distantPast) }
    }

    /// PR16: guarda los días reales hasta estabilidad de un tramo.
    ///
    /// La PRIMERA confirmación gana y las siguientes se ignoran. No es
    /// prudencia: "tres días seguidos dentro de banda" es un evento con fecha,
    /// y sobrescribirlo días después mediría otra cosa (cuántos días llevas
    /// estable, no cuántos tardaste). Los confusores se congelan aquí mismo
    /// porque dentro de seis meses el check-in de aquel día ya no estará en
    /// ninguna ventana que nadie consulte.
    func recordStability(episodeID: UUID, leg: TravelLeg, days: Double,
                         confounders: TravelConfounders, at date: Date = Date()) {
        guard days >= 0, var episode = episodes.first(where: { $0.id == episodeID }) else { return }
        var outcome = episode.measuredOutcome
            ?? TravelMeasuredOutcome(destinationStabilityDays: nil, homeStabilityDays: nil,
                                     confoundersRawValue: 0, lastMeasuredAt: date)
        switch leg {
        case .outbound:
            guard outcome.destinationStabilityDays == nil else { return }
            outcome.destinationStabilityDays = days
        case .homeReturn:
            guard outcome.homeStabilityDays == nil else { return }
            outcome.homeStabilityDays = days
        }
        // Unión y no reemplazo: si la ida estuvo confundida por alcohol y la
        // vuelta por enfermedad, el episodio arrastra las dos cosas.
        outcome.confoundersRawValue = TravelConfounders(rawValue: outcome.confoundersRawValue)
            .union(confounders).rawValue
        outcome.lastMeasuredAt = date
        episode.measuredOutcome = outcome
        save(episode)
    }

    func restore(_ restored: [TravelEpisode]) {
        for episode in restored { episodes.removeAll { $0.id == episode.id } }
        episodes.append(contentsOf: restored)
        sortAndPersist()
    }

    private func sortAndPersist() {
        // Más reciente primero, por salida de ida. Un episodio sin vuelos
        // todavía (sólo husos y título) va al final en vez de romper el orden.
        episodes.sort { ($0.outboundDeparture ?? .distantPast) > ($1.outboundDeparture ?? .distantPast) }
        try? JSONEncoder().encode(episodes).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TravelEpisode].self, from: data) else { return }
        episodes = decoded
    }
}
