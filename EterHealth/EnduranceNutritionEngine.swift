import Foundation

struct EnduranceNutritionGuidance {
    let carbsGramsPerHour: ClosedRange<Double>
    let fluidMillilitersPerHour: ClosedRange<Double>
    let sodiumMilligramsPerHour: ClosedRange<Double>
    let note: String
}

// Real ACSM/ISSN endurance-nutrition ranges (Jeukendrup 2014 carbohydrate
// guidelines; ACSM fluid-replacement position stand) — generic sports-
// science guidance, not personalized to this athlete's own sweat rate or
// gut tolerance (éter has no way to measure either), always disclosed as
// such rather than presented as this person's personal number.
enum EnduranceNutritionEngine {
    nonisolated static func guidance(durationMinutes: Double, expectedAirTemperatureCelsius: Double? = nil) -> EnduranceNutritionGuidance? {
        // Under an hour, in-session fueling isn't necessary per ACSM
        // guidance — glycogen stores comfortably cover it; recommending
        // gels for a 40-minute easy run would be noise, not help.
        guard durationMinutes >= 60 else { return nil }
        let hours = durationMinutes / 60
        // Past ~2.5h, glycogen depletion is the real limiter and higher
        // carb intake requires multiple transportable sources (glucose +
        // fructose) to absorb — a single-sugar gel alone caps out lower.
        let carbs: ClosedRange<Double> = hours < 2.5 ? 30...60 : 60...90
        var fluid: ClosedRange<Double> = 400...800
        var sodium: ClosedRange<Double> = 300...700
        var heatNote = ""
        if let temp = expectedAirTemperatureCelsius, temp >= 25 {
            fluid = 600...1_000
            sodium = 500...1_000
            heatNote = " Con calor previsto (\(Int(temp.rounded()))°C), acércate al extremo alto de líquido y sodio."
        }
        let note = "Guía general de nutrición de resistencia (ACSM/ISSN), no personalizada a tu sudoración ni tolerancia digestiva — pruébala en entrenamiento, nunca por primera vez el día de la carrera.\(heatNote)"
        return EnduranceNutritionGuidance(carbsGramsPerHour: carbs, fluidMillilitersPerHour: fluid, sodiumMilligramsPerHour: sodium, note: note)
    }

    nonisolated static func summary(_ guidance: EnduranceNutritionGuidance) -> String {
        "\(Int(guidance.carbsGramsPerHour.lowerBound))–\(Int(guidance.carbsGramsPerHour.upperBound)) g/h de carbohidrato · " +
        "\(Int(guidance.fluidMillilitersPerHour.lowerBound))–\(Int(guidance.fluidMillilitersPerHour.upperBound)) ml/h · " +
        "\(Int(guidance.sodiumMilligramsPerHour.lowerBound))–\(Int(guidance.sodiumMilligramsPerHour.upperBound)) mg/h de sodio"
    }
}
