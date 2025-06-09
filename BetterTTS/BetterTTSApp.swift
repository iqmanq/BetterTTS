import SwiftUI // Keep this import

@main
struct BetterTTSApp: App {
    // This line tells SwiftUI to use your AppDelegate class for the application lifecycle.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // For a completely AppKit-driven app where AppDelegate creates the window,
        // you might not need a WindowGroup here, or just a minimal one.
        // Settings is a common minimal scene that doesn't open a default window.
        Settings {
            EmptyView() // Or some minimal settings view if you plan to have one.
        }
    }
}
