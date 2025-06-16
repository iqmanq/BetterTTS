import SwiftUI
import AVFoundation
import Vision
import ScreenCaptureKit
import VideoToolbox

@MainActor
class TTSManager: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    
    // MARK: - Published Properties for UI
    @Published var selectionRect: NSRect?
    @Published var isAdjustingSelection = false
    @Published var availableVoices: [String] = []
    @Published var selectedVoice: String = ""
    
    @Published private(set) var statusMessage: String = "Ready"
    @Published private(set) var isGenerating: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var canPlay: Bool = false
    @Published var isAutoScrollEnabled: Bool = false {
        didSet {
            if isAutoScrollEnabled {
                print("✅ Auto scroll enabled — calling toggleAutoScroll()")
                toggleAutoScroll()
            }
        }
    }
    // MARK: - Core Components
    private let generator = AudioGenerator()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // MARK: - Streaming Pipeline State
    private var textChunks: [(id: Int, text: String)] = []
    private var nextBufferToPlay: (id: Int, buffer: AVAudioPCMBuffer)?
    private var currentlyPlayingId: Int = -1
    private var isFetchingNextChunk: Bool = false
    private var previouslyReadText: String = ""
    
    // MARK: - Screen Capture state
    private var captureStream: SCStream?
    private var captureContinuation: CheckedContinuation<CGImage?, Error>?
    private var hasCapturedFrame = false
    
    private lazy var selectionWindow: SelectionWindow = {
        // This code runs only once to create our persistent window.
        let window = SelectionWindow(contentRect: .zero)
        let selectionView = SelectionView(frame: .zero)
        window.contentView = selectionView

        // The closure now safely updates the manager, as the window lifecycle is stable.
        selectionView.onSelectionEnded = { [weak self] finalRect in
            self?.selectionRect = finalRect
        }
        return window
    }()

    // MARK: - Initialize Voices and Audio Engine
    
    override init() {
        let voiceNames = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi"]
        self.availableVoices = voiceNames
        self.selectedVoice = voiceNames.first ?? ""

        super.init()
        setupAudioEngine()
        print("[TTSManager] Streaming engine initialized.")
    }
    
    private func setupAudioEngine() {
        engine.attach(player)
        
        let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 24000.0,
                                        channels: 2,
                                        interleaved: false)!

        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        
        player.volume = 0.5
        
        do {
            try engine.start()
        } catch {
            print("❌ Could not start AVAudioEngine: \(error)")
        }
    }
    
    // MARK: - Playback Controls
    
    func play() {
        if !player.isPlaying, canPlay {
            player.play()
            self.isPlaying = true
            self.statusMessage = "Playing..."
        }
    }
    
    func pause() {
        player.pause()
        self.isPlaying = false
        self.statusMessage = "Paused."
    }
    
    func stop() {
        player.stop()
        resetPipeline()
    }
    
    func toggleAutoScroll() {
        // Create a default selection rectangle if one doesn't already exist.
        if selectionRect == nil {
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let defaultWidth: CGFloat = 400
                let defaultHeight: CGFloat = 300
                self.selectionRect = NSRect(
                    x: screenFrame.midX - defaultWidth / 2,
                    y: screenFrame.midY - defaultHeight / 2,
                    width: defaultWidth,
                    height: defaultHeight
                )
                print("🆕 Created default selectionRect: \(self.selectionRect!)")
            } else {
                print("❌ No screen available to create a default selection rectangle.")
                return
            }
        }

        guard var rect = self.selectionRect else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Get a list of on-screen windows, excluding desktop elements.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainScreen = NSScreen.main else {
            print("❌ Failed to get the window list or main screen.")
            return
        }

        var targetWindowBounds: CGRect?

        // The window list is ordered from front-to-back. Find the first valid window that isn't ours.
        for windowInfo in windows {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != selfPID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0, // Standard window layer
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgBounds.height > 50 else { // A basic filter to ignore small or invalid windows
                continue
            }

            // This is the topmost window of another application.
            targetWindowBounds = cgBounds
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "Unknown"
            print("🎯 Found target window: \(ownerName) with bounds \(cgBounds)")
            break
        }

        guard let windowBounds = targetWindowBounds else {
            print("❌ Could not find a suitable target window to snap to.")
            return
        }

        // CGWindowList coordinates are top-left. We need to convert to AppKit's bottom-left system.
        let screenHeight = mainScreen.frame.height
        
        // The Y from CGWindowList is the distance from the top of the screen to the top of the window.
        // The bottom edge of the window (in top-down coordinates) is `windowBounds.origin.y + windowBounds.height`.
        // The bottom edge in AppKit's bottom-up coordinates is therefore:
        let windowBottomY_AppKit = screenHeight - (windowBounds.origin.y + windowBounds.height)

        // Now, we adjust the selection rectangle's bottom edge to match the window's bottom edge.
        let currentTopY = rect.maxY
        let newBottomY = windowBottomY_AppKit
        
        // Calculate the new height, ensuring it has a minimum value.
        let newHeight = max(50, currentTopY - newBottomY)
        
        // Apply the new position and size to our selection rectangle.
        rect.origin.y = newBottomY
        rect.size.height = newHeight
        self.selectionRect = rect

        print("🟢 Adjusted selection rect to: \(rect)")

        // Display the selection window immediately with its new, adjusted frame.
        startAdjustingSelection()
    }
    
    // MARK: - Main Pipeline
    
    func readFromSelectionRectangle() {
        guard !isGenerating && !isPlaying, let rect = selectionRect else { return }
       
        if isAutoScrollEnabled {
            }

        Task {
            self.isGenerating = true
            self.canPlay = false
            self.statusMessage = "Reading screen..."
            await performOcr(on: rect)
            print("🔍 Starting OCR on rect: \(rect)")
        }
    }
    
    private func scrollDown(by pixels: CGFloat) {
        // This function creates a high-precision scroll event.
        // A negative value for wheel1 scrolls down.
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-pixels), wheel2: 0, wheel3: 0)
        scrollEvent?.post(tap: .cgSessionEventTap)
    }

    private func scrollAndReadNextPage() async {
        
        guard let rect = selectionRect else {
           resetPipeline(); return // End sequence
        }
        
        // 1. Scroll down by the rectangle's height precisely.
        scrollDown(by: rect.height)
        
        // 2. Wait for UI to update
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay

        // 3. OCR the new content
        guard let textAfterScroll = await performOcrAndGetText(on: rect) else {
            print("🚫 OCR failed after scroll."); resetPipeline(); return
        }

        // 4. If text is identical, we've reached the end of the page
        if textAfterScroll.trimmingCharacters(in: .whitespacesAndNewlines) == previouslyReadText.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("✅ End of page reached.");
            statusMessage = "Auto-scroll finished."
            resetPipeline()
            return
        }
        
        // 5. Find the new text to speak
        var newTextToRead = textAfterScroll
        let anchor = String(previouslyReadText.suffix(150)) // Use last 150 chars as an anchor
        if !anchor.isEmpty, let range = textAfterScroll.range(of: anchor) {
            newTextToRead = String(textAfterScroll[range.upperBound...])
        }

        if newTextToRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("✅ No new text detected.");
            statusMessage = "Auto-scroll finished."
            resetPipeline()
            return
        }

        // 6. Update history and start the pipeline with new text
        self.previouslyReadText = textAfterScroll
        startStreamingPipeline(with: newTextToRead)
    }
    
    private func performOcrAndGetText(on rect: CGRect) async -> String? {
        do {
            guard let capturedImage = try await captureScreen(rect: rect) else {
                return nil
            }

            let request = VNRecognizeTextRequest()
            
            let handler = VNImageRequestHandler(cgImage: capturedImage, options: [:])
            try await Task(priority: .userInitiated) {
                try handler.perform([request])
            }.value
            
            guard let observations = request.results else {
                return nil
            }

            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")

        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "OCR Error: \(error.localizedDescription)"
            }
            return nil
        }
    }
    
    private func performOcr(on rect: CGRect) async {
        self.previouslyReadText = "" // Reset on a new read
        guard let recognizedText = await performOcrAndGetText(on: rect) else {
            DispatchQueue.main.async {
                self.statusMessage = "OCR failed or no text found."
                self.isGenerating = false
            }
            return
        }
        
        DispatchQueue.main.async {
            if recognizedText.isEmpty {
                self.statusMessage = "No text found."
                self.isGenerating = false
            } else {
                self.previouslyReadText = recognizedText
                self.startStreamingPipeline(with: recognizedText)
            }
        }
    }
    
    private func startStreamingPipeline(with fullText: String) {
        print("▶️ Starting new streaming pipeline.")
        resetPipeline()
        isGenerating = true
        
        let sentenceSeparators = CharacterSet(charactersIn: ".!?,;:•—|")
        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let minWords = 5
        let maxWords = 15

        // Step 1: Split text into sentences based on strong punctuation
        let sentences = trimmedText.components(separatedBy: sentenceSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Step 2: Smartly merge sentences to form chunks within min and max words range
        var chunks: [String] = []
        var currentChunkWords: [String] = []

        func flushCurrentChunk() {
            if !currentChunkWords.isEmpty {
                let chunkText = currentChunkWords.joined(separator: " ")
                chunks.append(chunkText)
                currentChunkWords.removeAll()
            }
        }

        for sentence in sentences {
            let words = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            // If current chunk + this sentence fits maxWords, append it
            if (currentChunkWords.count + words.count) <= maxWords {
                currentChunkWords.append(contentsOf: words)
            } else {
                // If current chunk is big enough, flush it first
                if currentChunkWords.count >= minWords {
                    flushCurrentChunk()
                    currentChunkWords.append(contentsOf: words)
                } else {
                    // Otherwise, try to add sentence anyway (allow some flexibility)
                    currentChunkWords.append(contentsOf: words)
                    if currentChunkWords.count >= maxWords {
                        flushCurrentChunk()
                    }
                }
            }
        }
        // Flush any remaining words as last chunk
        flushCurrentChunk()

        // Step 3: Post-process: if last chunk is too small, merge into previous chunk
        if chunks.count >= 2 {
            let lastChunkWords = chunks.last!.components(separatedBy: .whitespacesAndNewlines)
            if lastChunkWords.count < minWords {
                let secondLastChunk = chunks[chunks.count - 2]
                chunks[chunks.count - 2] = secondLastChunk + " " + chunks.last!
                chunks.removeLast()
            }
        }

        self.textChunks = chunks.enumerated().map { (id: $0.offset, text: $0.element) }

        guard !textChunks.isEmpty else {
            print("No text chunks to process."); resetPipeline(); return
        }

        let firstChunk = textChunks[0]
        self.statusMessage = "Generating first audio chunk..."
        print("📤 Sending chunk to generator: '\(firstChunk.text)'")
        generator.generate(text: firstChunk.text, voice: selectedVoice) { [weak self] result in
            guard let self = self, self.currentlyPlayingId == -1 else { return }
            
            self.isGenerating = false
            
            switch result {
            case .success(let audioURL):
                guard let buffer = self.createBuffer(from: audioURL) else {
                    self.resetPipeline(); return
                }
                self.playBuffer(buffer, withId: firstChunk.id)
                
            case .failure(let error):
                print("❌ Failed to generate the first chunk: \(error)")
                self.resetPipeline()
            }
        }
    }
    
    private func preloadNextChunk() {
        guard !isFetchingNextChunk else { return }
        
        let nextId = currentlyPlayingId + 1
        guard nextId < textChunks.count else { return }
        
        let chunkToFetch = textChunks[nextId]
        isFetchingNextChunk = true
        self.statusMessage = "Generating chunk \(nextId + 1) of \(textChunks.count)..."

        generator.generate(text: chunkToFetch.text, voice: selectedVoice) { [weak self] result in
            guard let self = self, self.isFetchingNextChunk else { return }
            
            self.isFetchingNextChunk = false

            switch result {
            case .success(let audioURL):
                if let buffer = self.createBuffer(from: audioURL) {
                    print("  ✅ Pre-loaded chunk ID \(chunkToFetch.id).")
                    self.nextBufferToPlay = (id: chunkToFetch.id, buffer: buffer)
                    
                    print("   kickstarting stalled player.")
                    self.handleChunkFinished()
                }
            case .failure(let error):
                print("❌ Failed to generate chunk ID \(chunkToFetch.id): \(error)")
            }
        }
    }
    
    private func playBuffer(_ buffer: AVAudioPCMBuffer, withId id: Int) {
        self.currentlyPlayingId = id
        self.statusMessage = "Playing chunk \(id + 1) of \(textChunks.count)..."
        self.canPlay = true
        self.isPlaying = true
        
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                self?.handleChunkFinished()
            }
        }
        
        if !player.isPlaying {
            player.play()
        }
        
        preloadNextChunk()
    }
    
    private func handleChunkFinished() {
        self.isPlaying = false

        if let next = nextBufferToPlay, next.id == currentlyPlayingId + 1 {
            print("  ▶️ Playing pre-loaded chunk ID \(next.id).")
            self.nextBufferToPlay = nil
            playBuffer(next.buffer, withId: next.id)
            return
        }

        if currentlyPlayingId >= textChunks.count - 1 {
            print("▶️ Final chunk now playing. Monitoring for silence before proceeding...")
            Task {
                let mixer = self.engine.mainMixerNode
                let bus = 0
                mixer.removeTap(onBus: bus)

                let silenceThreshold: Float = -40.0 // dB
                let silenceTimeout: TimeInterval = 1.5
                var silentSince: Date?
                var finished = false

                mixer.installTap(onBus: bus, bufferSize: 1024, format: mixer.outputFormat(forBus: bus)) { buffer, _ in
                    guard let channelData = buffer.floatChannelData?[0] else { return }
                    
                    let frameCount = Int(buffer.frameLength)
                    if frameCount == 0 { return }
                    
                    var rms: Float = 0.0
                    for i in 0..<frameCount {
                        rms += channelData[i] * channelData[i]
                    }
                    rms = sqrt(rms / Float(frameCount))
                    let avgPower = 20 * log10(rms + 1e-7)
                                        
                    if avgPower < silenceThreshold {
                        if silentSince == nil {
                            silentSince = Date()
                        } else if Date().timeIntervalSince(silentSince!) > silenceTimeout {
                            if !finished {
                                finished = true
                                mixer.removeTap(onBus: bus)
                                Task {
                                    if self.isAutoScrollEnabled {
                                        print("▶️ Silence detected. Performing one-time scroll and read.")
                                        await self.scrollAndReadNextPage()
                                    } else {
                                        print("⏹️ Silence detected. Stopping...")
                                        self.resetPipeline()
                                    }
                                }
                            }
                        }
                    } else {
                        silentSince = nil
                    }
                }

                while !finished {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            
            return
        }

        print("... Waiting for chunk \(currentlyPlayingId + 2) to generate.")
        self.statusMessage = "Generating chunk \(currentlyPlayingId + 2)..."
    }
    
    private func resetPipeline() {
        player.stop()
        isPlaying = false
        canPlay = false
        isGenerating = false
        isFetchingNextChunk = false
        textChunks = []
        nextBufferToPlay = nil
        currentlyPlayingId = -1
        statusMessage = "Ready"
        print("Ceased all ongoing tasks.")
    }
    
    private func createBuffer(from url: URL) -> AVAudioPCMBuffer? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
                print("❌ Could not create buffer with format: \(audioFile.processingFormat)")
                return nil
            }
            try audioFile.read(into: buffer)
            try? FileManager.default.removeItem(at: url)
            return buffer
        } catch {
            print("❌ Failed to create or read buffer from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
    // MARK: - UI and Screen Capture
    
    func startAdjustingSelection() {
        // Only create a default rect if none exists
        if selectionRect == nil {
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let defaultWidth: CGFloat = 400
                let defaultHeight: CGFloat = 300
                let defaultRect = NSRect(
                    x: screenFrame.midX - defaultWidth / 2,
                    y: screenFrame.midY - defaultHeight / 2,
                    width: defaultWidth,
                    height: defaultHeight
                )
                self.selectionRect = defaultRect
                print("🆕 Created default selectionRect in Adjust Selection: \(defaultRect)")
            } else {
                print("❌ No screen available to create default selectionRect.")
                return
            }
        }

        guard let rect = selectionRect else {
            print("⚠️ No selectionRect available for adjustment after default creation.")
            return
        }

        print("🔷 Showing updated selectionRect: \(rect)")

        // Show the selection overlay window and update its frame
        selectionWindow.setFrame(rect, display: true)
        selectionWindow.makeKeyAndOrderFront(nil)

        isAdjustingSelection = true
    }
    
    func confirmSelection() {
        guard isAdjustingSelection else { return }

        // 1. Finalize the data from the window's current frame.
        self.selectionRect = self.selectionWindow.frame
        isAdjustingSelection = false
        
        // 2. HIDE the window instead of closing it. This prevents the crash.
        self.selectionWindow.orderOut(nil)
    }
    
    private func captureScreen(rect: CGRect) async throws -> CGImage? {
        guard NSScreen.screens.first(where: { $0.frame.intersects(rect) }) != nil else {
            throw NSError(domain: "TTSManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not find screen for rect: \(rect)"])
        }

        let captureRectTopLeft = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: { $0.frame.intersects(captureRectTopLeft) }) else {
            throw NSError(domain: "TTSManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find a display for the selection."])
        }

        let config = SCStreamConfiguration()
        let localX = captureRectTopLeft.origin.x - display.frame.origin.x
        let localY = display.frame.height - (captureRectTopLeft.origin.y - display.frame.origin.y) - captureRectTopLeft.height
        config.sourceRect = CGRect(
            x: localX,
            y: localY,
            width: captureRectTopLeft.width,
            height: captureRectTopLeft.height
        )
        config.width = Int(captureRectTopLeft.width)
        config.height = Int(captureRectTopLeft.height)
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        hasCapturedFrame = false
        try captureStream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        
        return try await withCheckedThrowingContinuation { continuation in
            self.captureContinuation = continuation
            self.captureStream?.startCapture()
        }
    }
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        Task { @MainActor in
            guard sampleBuffer.isValid, let pBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), !self.hasCapturedFrame else { return }
            self.hasCapturedFrame = true
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pBuffer, options: nil, imageOut: &cgImage)
            try? await stream.stopCapture()
            self.captureContinuation?.resume(returning: cgImage)
            self.captureContinuation = nil
        }
    }
}
