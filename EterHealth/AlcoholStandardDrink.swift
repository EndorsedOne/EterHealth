import Foundation

// The gap this closes: LifestyleEvent/HabitAssociationEngine's alcohol
// tracking has only ever been a bare drink COUNT — 2 light beers and 2
// double martinis have always read as identically "2 drinks" to the
// twin, even though the second has roughly 3x the real ethanol. The
// standard-drink equivalents below are the actual NIAAA/CDC reference
// values (a US standard drink ≈ 14g pure ethanol: 12oz ~5% beer, 5oz
// ~12% wine, 1.5oz ~40% spirit) — not something invented for this app.
// A classic martini is ~2.5oz of ~40% spirit plus vermouth, which is why
// it lands at ~2 standard drinks rather than 1.
enum DrinkType: String, CaseIterable, Identifiable {
    case beer = "Cerveza"
    case wine = "Copa de vino"
    case spirit = "Copa de licor sola"
    case martini = "Martini / cóctel fuerte"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .beer: return "mug.fill"
        case .wine: return "wineglass"
        case .spirit, .martini: return "flame.fill"
        }
    }

    // Real NIAAA standard-drink equivalents — how many "standard drinks"
    // (14g ethanol each) one serving of this type actually represents.
    var standardDrinks: Double {
        switch self {
        case .beer: return 1.0
        case .wine: return 1.0
        case .spirit: return 1.0
        // ~2.5oz of 40% spirit in a real martini pour — roughly double a
        // single spirit shot, not a separate invented multiplier.
        case .martini: return 2.0
        }
    }
}

struct DrinkSelection: Identifiable, Equatable {
    let type: DrinkType
    var count: Int
    var id: DrinkType { type }
}

enum StandardDrinkCalculator {
    static let ethanolGramsPerStandardDrink = 14.0

    nonisolated static func totalStandardDrinks(_ selections: [DrinkSelection]) -> Double {
        selections.reduce(0) { $0 + $1.type.standardDrinks * Double(max(0, $1.count)) }
    }

    nonisolated static func totalEthanolGrams(_ selections: [DrinkSelection]) -> Double {
        totalStandardDrinks(selections) * ethanolGramsPerStandardDrink
    }
}
