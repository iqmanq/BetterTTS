import Cocoa

class SelectionView: NSView {
    
    var onSelectionEnded: ((NSRect) -> Void)?

    private enum DragHandle {
        case none, body
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    private var currentDragHandle: DragHandle = .none
    private var mouseDownLocation: NSPoint?
    private let handleSize: CGFloat = 10.0

    private var resizeTimer: Timer?
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
        self.mouseDownLocation = self.convert(event.locationInWindow, from: nil)
        self.currentDragHandle = getDragHandle(for: mouseDownLocation!)
        
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0/165, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = self.mouseDownLocation else { return }
        
        let currentLocation = self.convert(event.locationInWindow, from: nil)
        let deltaX = currentLocation.x - startLocation.x
        let deltaY = currentLocation.y - startLocation.y
        
        var newFrame = self.window?.frame ?? .zero
        
        switch currentDragHandle {
        case .body:
            newFrame.origin.x += deltaX
            newFrame.origin.y -= deltaY
        case .topLeft:
            newFrame.origin.x += deltaX; newFrame.size.width -= deltaX
            newFrame.origin.y -= deltaY; newFrame.size.height += deltaY
        case .top:
            newFrame.origin.y -= deltaY; newFrame.size.height += deltaY
        case .topRight:
            newFrame.size.width += deltaX
            newFrame.origin.y -= deltaY; newFrame.size.height += deltaY
        case .left:
            newFrame.origin.x += deltaX; newFrame.size.width -= deltaX
        case .right:
            newFrame.size.width += deltaX
        case .bottomLeft:
            newFrame.origin.x += deltaX; newFrame.size.width -= deltaX
            newFrame.size.height -= deltaY
        case .bottom:
            newFrame.size.height -= deltaY
        case .bottomRight:
            newFrame.size.width += deltaX; newFrame.size.height -= deltaY
        case .none:
            return
        }

        if newFrame.size.width < 50 { newFrame.size.width = 50 }
        if newFrame.size.height < 50 { newFrame.size.height = 50 }

        self.latestFrame = newFrame
    }

    override func mouseUp(with event: NSEvent) {
        resizeTimer?.invalidate()
        resizeTimer = nil
        
        updateFrame()
        
        if let finalFrame = self.window?.frame {
            onSelectionEnded?(finalFrame)
        }
        
        currentDragHandle = .none
        mouseDownLocation = nil
    }
    
    private func updateFrame() {
        guard let newFrame = self.latestFrame, let window = self.window else { return }
        window.setFrame(newFrame, display: true)
        self.latestFrame = nil 
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
