// File: BetterTTSApp.swift

import SwiftUI

@main
struct BetterTTSApp: App {
    // We still use the AppDelegate for application-level events.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            // This tells SwiftUI to create a window and place our AppKit
            // view controller (via the representable bridge) inside it.
            MainViewControllerRepresentable()
                // Set the window's default size here.
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
