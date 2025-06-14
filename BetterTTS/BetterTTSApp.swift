import SwiftUI

@main
struct BetterTTSApp: App {
    @StateObject private var ttsManager = TTSManager()

    var body: some Scene {
        MenuBarExtra("BetterTTS", systemImage: "waveform.circle") {
            MenuView()
                .environmentObject(ttsManager)
        }
        .menuBarExtraStyle(.window)
    }
}
