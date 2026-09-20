import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let openTravelFromNotification = Notification.Name("eter.openTravelFromNotification")
}

/// Único puente entre las notificaciones de viaje y SwiftUI. El flag
/// persistente cubre el caso en que iOS entrega el toque antes de que
/// ContentView haya instalado su `onReceive` durante un arranque en frío.
enum TravelNotificationRouting {
    private static let pendingKey = "eter.notifications.pendingTravelRoute"

    static func markPendingAndPublish() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: .openTravelFromNotification, object: nil)
    }

    static func consumePending() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return true
    }
}

final class EterNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["route"] as? String == "travel" {
            DispatchQueue.main.async { TravelNotificationRouting.markPendingAndPublish() }
        }
        completionHandler()
    }
}

enum TravelAdaptationNotifier {
    private static let notifiedPrefix = "eter.notifications.adaptationConfirmed."

    /// La estabilidad pertenece a una parada, no al viaje completo. Una
    /// parada posterior (o la vuelta a casa) puede volver a introducir
    /// desajuste circadiano o fatiga de tránsito, así que este texto nunca
    /// debe afirmar que ha desaparecido el techo global de intensidad.
    nonisolated static func confirmedBody(destination: String) -> String {
        "Tus señales ya son estables en \(destination). Éter actualizará el entrenamiento según la parada actual del itinerario."
    }

    /// Se solicita al entrar en Viajes: nunca durante el arranque general ni
    /// como efecto secundario de una lectura de HealthKit.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Una confirmación fisiológica produce como máximo un aviso por parada.
    /// Si el usuario no concedió permiso, la tarjeta sigue siendo la fuente de
    /// verdad y no marcamos el aviso como enviado.
    static func notifyConfirmed(episode: TravelEpisode, stop: TravelStop) async {
        let key = notifiedPrefix + stop.id.uuidString
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional ||
              settings.authorizationStatus == .ephemeral else { return }

        let destination = stop.destinationTimeZoneID.map(TravelFormat.zoneName) ?? episode.title
        let content = UNMutableNotificationContent()
        content.title = "Éter · Adaptación confirmada"
        content.body = confirmedBody(destination: destination)
        content.sound = .default
        content.userInfo = ["route": "travel", "episodeID": episode.id.uuidString, "stopID": stop.id.uuidString]

        do {
            try await center.add(UNNotificationRequest(
                identifier: "travel-adapted-\(stop.id.uuidString)", content: content, trigger: nil
            ))
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            // La tarjeta se actualiza igualmente; un fallo del canal de aviso
            // nunca debe bloquear ni deshacer el aprendizaje fisiológico.
        }
    }
}
