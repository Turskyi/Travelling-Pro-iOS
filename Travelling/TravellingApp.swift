//
//  TravellingApp.swift
//  Travelling
//
//  Created by Dmytro on 2026-11-16.
//

import SwiftUI
import FirebaseCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct TravellingApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    #else
    init() {
        FirebaseApp.configure()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

