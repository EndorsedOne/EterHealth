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

    /// Alta y edición son la misma operación, con el id como identidad — el
    /// mismo criterio que DailyCheckInStore.save aplica con el día.
    func save(_ episode: TravelEpisode) {
        episodes.removeAll { $0.id == episode.id }
        episodes.append(episode)
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
        let live = episodes.filter { $0.phase(at: date).isActive }
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

    /// Los episodios ya terminados, del más reciente al más antiguo — la
    /// entrada del histórico. Excluye los cancelados: no hay nada que medir en
    /// un viaje que no se hizo.
    func completedEpisodes(at date: Date = Date()) -> [TravelEpisode] {
        episodes.filter { $0.phase(at: date) == .recovered }
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
