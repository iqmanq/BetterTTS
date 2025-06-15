import Cocoa
import CoreVideo // Import the Core Video framework

class SelectionView: NSView {
    
    var onSelectionEnded: ((NSRect) -> Void)?

    private enum DragHandle {
        case none, body
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private var currentDragHandle: DragHandle = .none
    private let handleSize: CGFloat = 10.0
    
    private var dragOffset: NSPoint?
    
    // Revert to using the CVDisplayLink for robust updates
    private var displayLink: CVDisplayLink?
    private var latestFrame: NSRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.red.withAlphaComponent(0.2).setFill()
        bounds.fill()
        NSColor.red.setStroke()
        let border = NSBezierPath(rect: bounds)
        border.lineWidth = 2.0
        border.stroke()
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = self.convert(event.locationInWindow, from: nil)
        currentDragHandle = getDragHandle(for: locationInView)

        if let windowFrame = self.window?.frame {
            let mouseLocationOnScreen = NSEvent.mouseLocation
            dragOffset = NSPoint(x: mouseLocationOnScreen.x - windowFrame.origin.x,
                                 y: mouseLocationOnScreen.y - windowFrame.origin.y)
        }
        
        // --- KEY CHANGE ---
        // Create and start a CVDisplayLink. It runs on a separate thread,
        // bypassing the main run loop's event tracking mode.
        let displayLinkCallback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            // The callback is on a background thread. Dispatch UI updates to the main thread.
            let view = unsafeBitCast(displayLinkContext, to: SelectionView.self)
            DispatchQueue.main.async {
                view.updateFrame()
            }
            return kCVReturnSuccess
        }
        
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        if let displayLink = displayLink {
            CVDisplayLinkSetOutputCallback(displayLink, displayLinkCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            CVDisplayLinkStart(displayLink)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let mouseLocationOnScreen = NSEvent.mouseLocation
        
        guard var newFrame = self.window?.frame else { return }
        
        switch currentDragHandle {
        case .body:
            guard let dragOffset = dragOffset else { return }
            newFrame.origin = NSPoint(x: mouseLocationOnScreen.x - dragOffset.x,
                                      y: mouseLocationOnScreen.y - dragOffset.y)
        // The resize logic remains the same
        case .right:
            newFrame.size.width = mouseLocationOnScreen.x - newFrame.minX
        case .left:
            let oldMaxX = newFrame.maxX
            newFrame.origin.x = mouseLocationOnScreen.x
            newFrame.size.width = oldMaxX - newFrame.minX
        case .top:
            newFrame.size.height = mouseLocationOnScreen.y - newFrame.minY
        case .bottom:
            let oldMaxY = newFrame.maxY
            newFrame.origin.y = mouseLocationOnScreen.y
            newFrame.size.height = oldMaxY - newFrame.minY
        case .bottomRight:
            let oldMaxY = newFrame.maxY
            newFrame.origin.y = mouseLocationOnScreen.y
            newFrame.size.height = oldMaxY - newFrame.minY
            newFrame.size.width = mouseLocationOnScreen.x - newFrame.minX
        case .bottomLeft:
            let oldMaxX = newFrame.maxX
            let oldMaxY = newFrame.maxY
            newFrame.origin.x = mouseLocationOnScreen.x
            newFrame.origin.y = mouseLocationOnScreen.y
            newFrame.size.width = oldMaxX - newFrame.minX
            newFrame.size.height = oldMaxY - newFrame.minY
        case .topRight:
            newFrame.size.width = mouseLocationOnScreen.x - newFrame.minX
            newFrame.size.height = mouseLocationOnScreen.y - newFrame.minY
        case .topLeft:
            let oldMaxX = newFrame.maxX
            newFrame.origin.x = mouseLocationOnScreen.x
            newFrame.size.width = oldMaxX - newFrame.minX
            newFrame.size.height = mouseLocationOnScreen.y - newFrame.minY
        case .none:
            return
        }

        if newFrame.size.width < 50 { newFrame.size.width = 50 }
        if newFrame.size.height < 50 { newFrame.size.height = 50 }
        
        self.latestFrame = newFrame
    }

    override func mouseUp(with event: NSEvent) {
        // Stop and release the display link
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        
        updateFrame()
        
        if let finalFrame = self.window?.frame {
            onSelectionEnded?(finalFrame)
        }
        
        currentDragHandle = .none
        dragOffset = nil
        latestFrame = nil
    }
    
    // This method is now called from the CVDisplayLink callback on the main thread
    private func updateFrame() {
        guard let newFrame = self.latestFrame, let window = self.window else { return }
        window.setFrame(newFrame, display: true)
    }
    
    private func getDragHandle(for point: NSPoint) -> DragHandle {
        let onLeft = point.x < handleSize; let onRight = point.x > bounds.width - handleSize
        let onTop = point.y < handleSize; let onBottom = point.y > bounds.height - handleSize
        if onTop && onLeft { return .topLeft }; if onTop && onRight { return .topRight }
        if onBottom && onLeft { return .bottomLeft }; if onBottom && onRight { return .bottomRight }
        if onTop { return .top }; if onBottom { return .bottom }
        if onLeft { return .left }; if onRight { return .right }
        return .body
    }
}
