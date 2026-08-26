//
//  EterHealthWatchApp.swift
//  EterHealthWatch Watch App
//
//  Created by Ángel Martínez on 12/8/26.
//

import SwiftUI
import WatchKit
import HealthKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in await WatchWorkoutManager.shared.start(configuration: workoutConfiguration) }
    }
}

@main
struct EterHealthWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var workout = WatchWorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workout)
        }
    }
}
