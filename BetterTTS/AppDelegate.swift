import Cocoa
import AVFoundation // For AVAudioPlayer

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var mainViewController: MainViewController!

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Create the main view controller
        mainViewController = MainViewController()

        // Create the window
        let contentRect = NSRect(x: 0, y: 0, width: 320, height: 280)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "BetterTTS"
        window.contentViewController = mainViewController
        window.makeKeyAndOrderFront(nil)

        NSApp.windows.first?.delegate = self
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
