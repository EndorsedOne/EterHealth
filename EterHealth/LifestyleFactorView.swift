import SwiftUI

// Real caffeine content varies by brew and shot count, so these are
// standard reference servings, not a lab measurement of what any one
// person actually drank — a single espresso shot, a normal latte/flat
// white pour (flat white traditionally double-shot, hence the higher
// number than latte), decaf's residual trace, and a typical 350–450 ml
// cold brew serving. People know what they ordered, not its mg — this
// gives them the number instead of asking them to guess it.
private enum CaffeineDrink: String, CaseIterable, Identifiable {
    case espresso = "Espresso"
    case latte = "Latte"
    case flatWhite = "Flat white"
    case decaf = "Descafeinado"
    case coldBrew = "Cold brew"
    // Matcha (a whisked ~2g ceremonial-grade bowl) sits close to a latte —
    // commonly cited around 60-80mg for a real prepared cup. Hojicha is
    // roasted green tea, typically from stems/twigs, and roasting itself
    // degrades caffeine — genuinely low, often marketed specifically as
    // the low-caffeine option, closer to 10-20mg per cup.
    case matcha = "Matcha"
    case hojicha = "Hojicha"
    var id: String { rawValue }
    var defaultMg: Int {
        switch self {
        case .espresso: return 63
        case .latte: return 77
        case .flatWhite: return 130
        case .decaf: return 3
        case .coldBrew: return 200
        case .matcha: return 70
        case .hojicha: return 15
        }
    }
}

struct LifestyleFactorView: View {
    @EnvironmentObject private var store: LifestyleFactorStore
    @EnvironmentObject private var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    @State private var event: LifestyleEvent
    private let existing: LifestyleEvent?
    private let digestiveOptions = ["Digestión pesada", "Hinchazón", "Reflujo", "Malestar intestinal"]

    init(existing: LifestyleEvent? = nil) { self.existing = existing; _event = State(initialValue: existing ?? .empty) }

    var body: some View {
        NavigationStack {
            Form {
                // Moved to the top, ahead of every factor: it used to sit
                // at the very bottom under "Contexto", so backdating an
                // entry meant scrolling all the way down AFTER already
                // logging things above — and a factor's own time picker
                // (e.g. cafeína's "Hora de consumo", set first while this
                // was still "ahora") looked like it "didn't sync" once
                // this was finally changed, since it only overrides that
                // one factor's timing and was never the field that moves
                // the whole entry. Setting the day/hour here FIRST means
                // every factor's own time picker below already starts
                // from the right day by default.
                Section("Cuándo") {
                    DatePicker("Fecha y hora", selection: $event.date)
                    TextField("Nota opcional", text: $event.note, axis: .vertical)
                }
                Section("Alcohol") {
                    Stepper("Bebidas estándar: \(event.alcoholDrinks)", value: $event.alcoholDrinks, in: 0...15)
                    Text("Se guardará también en Apple Salud.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Cafeína") {
                    Text("Toca lo que has tomado — nadie sabe cuántos mg tiene su café, así que parte de una referencia típica y ajústala si la conoces mejor.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                        ForEach(CaffeineDrink.allCases) { drink in
                            Button {
                                // Deliberately does NOT also stamp
                                // caffeineDate here. It used to default to
                                // `event.date` at the moment of this tap —
                                // but "Cuándo" lives further down this same
                                // form, so tapping a drink before scrolling
                                // down to backdate the entry (the natural
                                // top-to-bottom order) locked caffeineDate
                                // to "now" even when the whole entry was
                                // being logged for yesterday. Leaving it nil
                                // means the "Hora de consumo" picker below
                                // keeps tracking `event.date` live until the
                                // person explicitly overrides it themselves.
                                event.caffeineMg = drink.defaultMg
                            } label: {
                                VStack(spacing: 2) {
                                    Text(drink.rawValue).font(.caption.bold())
                                    Text("\(drink.defaultMg) mg").font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                        }
                    }
                    Stepper("Cafeína: \(event.caffeineMg) mg", value: $event.caffeineMg, in: 0...600, step: 5)
                    if event.caffeineMg > 0 {
                        DatePicker("Hora de consumo", selection: Binding(
                            get: { event.caffeineDate ?? event.date },
                            set: { event.caffeineDate = $0 }
                        ))
                        Text("Por defecto, la fecha y hora de arriba. Cámbiala aquí solo si la cafeína fue a otra hora distinta.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Sin efecto asumido de antemano — cada uno se registra por separado y el gemelo aprende su propia relación con tu HRV, pulso y sueño, igual que ya hace con la sauna o el agua fría.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                        ForEach(SupplementKind.allCases) { supplement in
                            let isOn = event.supplements.contains(supplement)
                            Button {
                                if isOn { event.supplements.remove(supplement) } else { event.supplements.insert(supplement) }
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: supplement.icon).font(.caption)
                                    Text(supplement.rawValue).font(.caption2.bold()).multilineTextAlignment(.center)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).tint(isOn ? EterTheme.positive : nil)
                        }
                    }
                    // A magnesium/melatonin dose taken right before bed and
                    // the same dose taken after breakfast are different
                    // exposures for a next-morning HRV/sleep read — this
                    // stays nil (tracking "Cuándo" below live) until
                    // explicitly changed, same reasoning as caffeine's own
                    // "Hora de consumo" above.
                    if !event.supplements.isEmpty {
                        DatePicker("Hora de toma", selection: Binding(
                            get: { event.supplementsDate ?? event.date },
                            set: { event.supplementsDate = $0 }
                        ))
                        Text("Por defecto, la fecha y hora de arriba. Cámbiala aquí solo si la tomaste a otra hora distinta.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Suplementos")
                }
                Section("Alimentación") {
                    Picker("Calidad general", selection: $event.foodQuality) {
                        ForEach(FoodQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Ayuno: \(event.fastingHours == 0 ? "No" : "\(event.fastingHours) h")", value: $event.fastingHours, in: 0...36, step: 2)
                    Toggle("Entrenamiento en ayunas", isOn: $event.trainedFasted)
                    Toggle("Cena tardía", isOn: $event.lateDinner)
                    Toggle("Cena o comida copiosa", isOn: $event.heavyDinner)
                }
                Section("Hidratación") {
                    Picker("Nivel", selection: $event.hydration) {
                        ForEach(HydrationLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("He tomado electrolitos", isOn: $event.electrolytes)
                }
                Section("Digestión") {
                    ForEach(digestiveOptions, id: \.self) { symptom in
                        Toggle(symptom, isOn: Binding(
                            get: { event.digestiveSymptoms.contains(symptom) },
                            set: { enabled in
                                if enabled { if !event.digestiveSymptoms.contains(symptom) { event.digestiveSymptoms.append(symptom) } }
                                else { event.digestiveSymptoms.removeAll { $0 == symptom } }
                            }
                        ))
                    }
                }
                Section("Recuperación") {
                    Stepper("Sauna: \(event.saunaMinutes) min", value: $event.saunaMinutes, in: 0...90, step: 5)
                    if event.saunaMinutes > 0 {
                        Stepper("Temperatura sauna: \(event.saunaTemperatureC) °C", value: $event.saunaTemperatureC, in: 40...110, step: 5)
                    }
                    Stepper("Agua fría: \(event.coldMinutes) min", value: $event.coldMinutes, in: 0...30)
                    if event.coldMinutes > 0 {
                        Stepper("Temperatura agua: \(event.coldTemperatureC) °C", value: $event.coldTemperatureC, in: 0...25)
                    }
                }
            }
            .navigationTitle("Editar factores")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        store.save(event)
                        if let existing,
                           existing.alcoholDrinks != event.alcoholDrinks || existing.date != event.date {
                            Task { await health.replaceAlcohol(near: existing.date, drinks: event.alcoholDrinks, date: event.date) }
                        } else if existing == nil && event.alcoholDrinks > 0 {
                            Task { await health.saveAlcohol(drinks: event.alcoholDrinks, date: event.date) }
                        }
                        dismiss()
                    }.bold()
                }
            }
        }
    }
}
