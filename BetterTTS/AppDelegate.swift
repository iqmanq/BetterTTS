// File: AppDelegate.swift

import Cocoa

// Note: There is NO @main attribute here. BetterTTSApp.swift is the app's entry point.
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The window is now created and managed by the SwiftUI lifecycle.
        // We no longer need any window creation code here.
        print("✅ Application has finished launching.")
    }

    // This is a helpful function to ensure the app quits when the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
