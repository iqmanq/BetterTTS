import Cocoa

class SelectionWindow: NSWindow {
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.isExcludedFromWindowsMenu = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.sharingType = .none
    }
}
