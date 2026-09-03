import Foundation

/// LEGADO. Sustituido por TravelEpisode (PR14–PR16), que modela el viaje como
/// episodio con fases en vez de como una diferencia horaria declarada por día.
/// Se conserva únicamente para que los LifestyleEvent ya guardados y las copias
/// de seguridad antiguas sigan decodificando; ninguna UI lo escribe y ningún
/// motor lo lee.
// Sin @available(deprecated) a propósito: el propio archivo tiene que seguir
// declarando el campo, inicializarlo y decodificarlo, así que la anotación
// generaba tres warnings PERMANENTES sobre código que es correcto — y unos
// warnings que nadie puede quitar son unos warnings que se aprende a ignorar.
// Lo que de verdad impide que esto vuelva a la vida es un test: ver
// TravelLearningTests.testTheLegacyDailyTravelFieldIsInertEverywhere.
enum TravelDirection: String, Codable, CaseIterable, Identifiable {
    case east = "Hacia el este"
    case west = "Hacia el oeste"
    var id: String { rawValue }
}

enum FoodQuality: String, Codable, CaseIterable, Identifiable {
    case notRecorded = "Sin registrar"
    case healthy = "Saludable"
    case normal = "Normal"
    case indulgent = "Desfase / comida libre"
    var id: String { rawValue }
}

enum HydrationLevel: String, Codable, CaseIterable, Identifiable {
    case notRecorded = "Sin registrar"
    case low = "Baja"
    case normal = "Normal"
    case high = "Alta"
    var id: String { rawValue }
}

// Deliberately no acute score formula attached to any of these — unlike
// caffeine (a real, well-characterized half-life) their acute effect on
// this specific person is genuinely uncertain. The honest model is the
// same one sauna/agua fría already use: log the exposure, let
// HabitAssociationEngine learn its own correlation with this person's
// real HRV/pulso/sueño over time, and only then let it move the score —
// never a guessed number applied from day one.
enum SupplementKind: String, Codable, CaseIterable, Identifiable {
    case magnesiumGlycinate = "Bisglicinato de magnesio"
    case melatonin = "Melatonina"
    // Not in the user's own list — added because the evidence base is
    // strong enough to be worth tracking against real outcomes:
    // ashwagandha has RCT support for cortisol/sleep and some strength
    // outcomes in trained males, and L-theanine is commonly paired with
    // caffeine (matcha itself contains it) for calm alertness and sleep
    // quality. Both still only affect the twin through the same learned
    // mechanism as the other two, no different treatment.
    //
    // Creatine was here too and got removed: its real, replicated
    // evidence (strength/power/lean-mass gains via phosphocreatine
    // resynthesis) has no plausible mechanistic path to HRV, resting
    // heart rate, or sleep — the exact three signals this whole learned-
    // association mechanism observes. Tracking it here would only ever
    // report "no effect," correctly but uselessly, since it isn't
    // supposed to move any of these dials in the first place. If it's
    // ever tracked again, it should be correlated against strength/
    // volume progression instead — a different mechanism than this one.
    case ashwagandha = "Ashwagandha"
    case lTheanine = "L-teanina"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .magnesiumGlycinate: return "pills.fill"
        case .melatonin: return "moon.fill"
        case .ashwagandha: return "leaf.fill"
        case .lTheanine: return "cup.and.saucer.fill"
        }
    }
}

struct LifestyleEvent: Codable, Identifiable {
    let id: UUID
    var date: Date
    var alcoholDrinks: Int
    var saunaMinutes: Int
    var saunaTemperatureC: Int
    var coldMinutes: Int
    var coldTemperatureC: Int
    // LEGADO, sólo lectura de datos antiguos — ver TravelDirection arriba.
    // Ninguna UI los escribe (PR14 quitó la sección del cuestionario) y ningún
    // motor los lee (PR15 borró las dos penalizaciones, PR16 migró la
    // asociación de hábitos a los episodios). Se quedan para no romper la
    // decodificación de lo ya guardado.
    var timeZoneDifference: Int
    var travelDirection: TravelDirection
    var caffeineMg: Int
    var caffeineDate: Date?
    var foodQuality: FoodQuality
    var fastingHours: Int
    var trainedFasted: Bool
    var lateDinner: Bool
    var heavyDinner: Bool
    var hydration: HydrationLevel
    var electrolytes: Bool
    var digestiveSymptoms: [String]
    var supplements: Set<SupplementKind>
    // Distinct from `date` the same way `caffeineDate` already is distinct
    // from it — magnesium/melatonin/ashwagandha taken right before bed vs.
    // first thing in the morning are physiologically different exposures
    // with very different plausible windows of effect on that night's
    // sleep/HRV. nil means "use the event's own date/time", exactly like
    // caffeineDate's own fallback, so existing entries logged before this
    // field existed keep behaving the same way they always did.
    var supplementsDate: Date?
    var note: String

    init(id: UUID, date: Date, alcoholDrinks: Int, saunaMinutes: Int, saunaTemperatureC: Int,
         coldMinutes: Int, coldTemperatureC: Int, timeZoneDifference: Int,
         travelDirection: TravelDirection, caffeineMg: Int, caffeineDate: Date?,
         foodQuality: FoodQuality, fastingHours: Int, trainedFasted: Bool,
         lateDinner: Bool, heavyDinner: Bool, hydration: HydrationLevel,
         electrolytes: Bool, digestiveSymptoms: [String], supplements: Set<SupplementKind> = [],
         supplementsDate: Date? = nil, note: String) {
        self.id = id; self.date = date; self.alcoholDrinks = alcoholDrinks
        self.saunaMinutes = saunaMinutes; self.saunaTemperatureC = saunaTemperatureC
        self.coldMinutes = coldMinutes; self.coldTemperatureC = coldTemperatureC
        self.timeZoneDifference = timeZoneDifference; self.travelDirection = travelDirection
        self.caffeineMg = caffeineMg; self.caffeineDate = caffeineDate; self.foodQuality = foodQuality
        self.fastingHours = fastingHours; self.trainedFasted = trainedFasted
        self.lateDinner = lateDinner; self.heavyDinner = heavyDinner; self.hydration = hydration
        self.electrolytes = electrolytes; self.digestiveSymptoms = digestiveSymptoms
        self.supplements = supplements; self.supplementsDate = supplementsDate; self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, alcoholDrinks, saunaMinutes, saunaTemperatureC, coldMinutes,
             coldTemperatureC, timeZoneDifference, travelDirection, caffeineMg, caffeineDate,
             foodQuality, fastingHours, trainedFasted, lateDinner, heavyDinner, hydration,
             electrolytes, digestiveSymptoms, supplements, supplementsDate, note
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        alcoholDrinks = try values.decode(Int.self, forKey: .alcoholDrinks)
        saunaMinutes = try values.decode(Int.self, forKey: .saunaMinutes)
        saunaTemperatureC = try values.decodeIfPresent(Int.self, forKey: .saunaTemperatureC) ?? 80
        coldMinutes = try values.decode(Int.self, forKey: .coldMinutes)
        coldTemperatureC = try values.decodeIfPresent(Int.self, forKey: .coldTemperatureC) ?? 12
        timeZoneDifference = try values.decode(Int.self, forKey: .timeZoneDifference)
        travelDirection = try values.decode(TravelDirection.self, forKey: .travelDirection)
        caffeineMg = try values.decodeIfPresent(Int.self, forKey: .caffeineMg) ?? 0
        caffeineDate = try values.decodeIfPresent(Date.self, forKey: .caffeineDate)
        foodQuality = try values.decodeIfPresent(FoodQuality.self, forKey: .foodQuality) ?? .notRecorded
        fastingHours = try values.decodeIfPresent(Int.self, forKey: .fastingHours) ?? 0
        trainedFasted = try values.decodeIfPresent(Bool.self, forKey: .trainedFasted) ?? false
        lateDinner = try values.decodeIfPresent(Bool.self, forKey: .lateDinner) ?? false
        heavyDinner = try values.decodeIfPresent(Bool.self, forKey: .heavyDinner) ?? false
        hydration = try values.decodeIfPresent(HydrationLevel.self, forKey: .hydration) ?? .notRecorded
        electrolytes = try values.decodeIfPresent(Bool.self, forKey: .electrolytes) ?? false
        digestiveSymptoms = try values.decodeIfPresent([String].self, forKey: .digestiveSymptoms) ?? []
        // Decoded via the raw strings, not Set<SupplementKind> directly —
        // that would throw (and silently drop the WHOLE saved events
        // array, not just this one field) the day a case is ever renamed
        // or removed (as .creatine was) while an old entry on disk still
        // has its raw value saved. Unrecognized values are just dropped.
        let rawSupplements = try values.decodeIfPresent(Set<String>.self, forKey: .supplements) ?? []
        supplements = Set(rawSupplements.compactMap(SupplementKind.init(rawValue:)))
        supplementsDate = try values.decodeIfPresent(Date.self, forKey: .supplementsDate)
        note = try values.decode(String.self, forKey: .note)
    }

    static var empty: LifestyleEvent {
        LifestyleEvent(id: UUID(), date: Date(), alcoholDrinks: 0, saunaMinutes: 0, saunaTemperatureC: 80,
                       coldMinutes: 0, coldTemperatureC: 12, timeZoneDifference: 0, travelDirection: .east,
                       caffeineMg: 0, caffeineDate: nil, foodQuality: .notRecorded, fastingHours: 0,
                       trainedFasted: false, lateDinner: false, heavyDinner: false,
                       hydration: .notRecorded, electrolytes: false, digestiveSymptoms: [], supplements: [],
                       supplementsDate: nil, note: "")
    }

    var summary: String {
        var parts: [String] = []
        if alcoholDrinks > 0 { parts.append("\(alcoholDrinks) bebida\(alcoholDrinks == 1 ? "" : "s")") }
        if saunaMinutes > 0 { parts.append("sauna \(saunaMinutes) min · \(saunaTemperatureC) °C") }
        if coldMinutes > 0 { parts.append("frío \(coldMinutes) min · \(coldTemperatureC) °C") }
        // El viaje ya no se resume aquí: vive en su propio episodio, con su
        // propia pantalla y su propia línea temporal (Datos → Viajes).
        if caffeineMg > 0 { parts.append("cafeína \(caffeineMg) mg") }
        if foodQuality != .notRecorded { parts.append(foodQuality.rawValue.lowercased()) }
        if fastingHours > 0 { parts.append("ayuno \(fastingHours) h") }
        if trainedFasted { parts.append("entrenamiento en ayunas") }
        if hydration != .notRecorded { parts.append("hidratación \(hydration.rawValue.lowercased())") }
        if !digestiveSymptoms.isEmpty { parts.append("digestión: \(digestiveSymptoms.joined(separator: ", ").lowercased())") }
        if !supplements.isEmpty { parts.append(supplements.map(\.rawValue).sorted().joined(separator: ", ").lowercased()) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class LifestyleFactorStore: ObservableObject {
    static let shared = LifestyleFactorStore()
    @Published private(set) var events: [LifestyleEvent] = []

    private var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lifestyle-factors.json")
    }

    private init() { load() }

    func save(_ event: LifestyleEvent) {
        guard event.alcoholDrinks > 0 || event.saunaMinutes > 0 || event.coldMinutes > 0 ||
              // timeZoneDifference fuera: un evento no puede volverse
              // "significativo" por un campo legado que nada escribe.
              event.caffeineMg > 0 || event.foodQuality != .notRecorded ||
              event.fastingHours > 0 || event.trainedFasted || event.lateDinner || event.heavyDinner ||
              event.hydration != .notRecorded || event.electrolytes || !event.digestiveSymptoms.isEmpty ||
              !event.supplements.isEmpty else { return }
        events.removeAll { $0.id == event.id }
        events.append(event)
        events.sort { $0.date > $1.date }
        persist()
    }

    func delete(_ event: LifestyleEvent) {
        events.removeAll { $0.id == event.id }
        persist()
    }

    func restore(_ restored: [LifestyleEvent]) {
        let ids = Set(restored.map(\.id)); events.removeAll { ids.contains($0.id) }; events.append(contentsOf: restored)
        events.sort { $0.date > $1.date }; persist()
    }

    func recent(before now: Date = Date(), hours: Double = 36) -> [LifestyleEvent] {
        events.filter { $0.date <= now && now.timeIntervalSince($0.date) <= hours * 3600 }
    }

    private func persist() { try? JSONEncoder().encode(events).write(to: storageURL, options: .atomic) }
    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([LifestyleEvent].self, from: data) else { return }
        events = decoded.sorted { $0.date > $1.date }
    }
}
