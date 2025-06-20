import SwiftUI
import AVFoundation
import Vision
import ScreenCaptureKit
import VideoToolbox
import NaturalLanguage

enum AutoNextMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case fixedZone = "Fixed Zone"
    case smartOCR = "Smart OCR"
    var id: Self { self }
}

@MainActor
class TTSManager: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    
    // MARK: - Published Properties for UI
    @Published private(set) var canSkipBackward = false
    @Published private(set) var canSkipForward = false
    @Published var selectionRect: NSRect?
    @Published var isAdjustingSelection = false
    @Published var availableVoices: [String] = []
    @Published var selectedVoice: String = ""
    @Published var volume: Float = 0.5 {
        didSet {
            player.volume = volume
        }
    }
    
    @Published var shouldCloseMenu = false
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
    
    @Published var doNotReadRect: NSRect?
    @Published var isAdjustingDoNotReadZone = false
    @Published var ignoredTextSnippets: [String] = []
    @Published var autoNextMode: AutoNextMode = .off
    @Published var nextButtonClickRect: NSRect?
    @Published var isAdjustingNextButtonClickZone = false

    // MARK: - Playback Speed State
    @Published var currentSpeed: Float = 1.0 {
        didSet {
            timePitch.rate = currentSpeed
        }
    }
    let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2]

    func cycleSpeed() {
        // Find the current speed's index in our array
        guard let currentIndex = speedOptions.firstIndex(of: currentSpeed) else {
            // If the current speed isn't in the array, reset to 1.0x
            currentSpeed = 1.0
            return
        }
        
        // Get the next index, looping back to the start if we're at the end
        let nextIndex = (currentIndex + 1) % speedOptions.count
        currentSpeed = speedOptions[nextIndex]
    }

    // MARK: - Core Components
    private let generator = AudioGenerator()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private static let languageMap: [String: String] = [
        "am": "am", "ar": "ar", "hy": "hy", "bn": "bn", "bg": "bg",
        "my": "my", "ca": "ca", "chr": "chr", "hr": "hr", "cs": "cs",
        "da": "da", "nl": "nl", "en": "en-us", "fi": "fi", "fr": "fr-fr",
        "ka": "ka", "de": "de", "el": "el", "gu": "gu", "he": "he",
        "hi": "hi", "hu": "hu", "is": "is", "id": "id", "it": "it",
        "ja": "ja", "kn": "kn", "km": "km", "ko": "ko", "lo": "lo",
        "ms": "ms", "ml": "ml", "mr": "mr", "nb": "nb", "or": "or",
        "fa": "fa", "pl": "pl", "pt": "pt-br", "pa": "pa", "ro": "ro",
        "ru": "ru", "zh-Hans": "zh", "si": "si", "sk": "sk", "sl": "sl",
        "es": "es", "sv": "sv", "ta": "ta", "te": "te", "th": "th",
        "bo": "bo", "zh-Hant": "yue", "tr": "tr", "uk": "uk", "ur": "ur",
        "vi": "vi", "cy": "cy"
    ]

    // MARK: - Streaming Pipeline State
    private var textChunks: [(id: Int, text: String)] = []
    private var nextBufferToPlay: (id: Int, buffer: AVAudioPCMBuffer)?
    private var currentlyPlayingId: Int = -1
    private var isFetchingNextChunk: Bool = false
    private var previouslyReadText: String = ""
    private var currentLanguage: String = "en-us"
    private var activeSessionID: UUID?
    private let scrollOverlapPercentage: CGFloat = 0.10
    private let interChunkDelay: TimeInterval = 0.5
    private var firstTextOfCurrentPage: String?

    // MARK: - Screen Capture state
    private var captureStream: SCStream?
    private var captureContinuation: CheckedContinuation<CGImage?, Error>?
    private var hasCapturedFrame = false
    
    private lazy var selectionWindow: SelectionWindow = {
        let window = SelectionWindow(contentRect: .zero)
        let selectionView = SelectionView(frame: .zero)
        window.contentView = selectionView

        // Make the callback that runs after resizing context-aware.
        selectionView.onSelectionEnded = { [weak self] finalRect in
            guard let self = self else { return }
            
            // Check which mode is active and update the correct rectangle property.
            if self.isAdjustingSelection {
                self.selectionRect = finalRect
                print("Updated normal selectionRect")
            } else if self.isAdjustingDoNotReadZone {
                self.doNotReadRect = finalRect
                print("Updated doNotReadRect")
            } else if self.isAdjustingNextButtonClickZone {
                self.nextButtonClickRect = finalRect
                print("Updated nextButtonClickRect")
            }
        }
        return window
    }()

    // MARK: - Initialize Voices and Audio Engine
    
    override init() {
        let voiceNames = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"]
        self.availableVoices = voiceNames
        self.selectedVoice = voiceNames.first ?? ""

        super.init()
        setupAudioEngine()
        print("[TTSManager] Streaming engine initialized.")
        self.ignoredTextSnippets = UserDefaults.standard.stringArray(forKey: "ignoredTextSnippets") ?? []
    }
    
    private func setupAudioEngine() {
        
        engine.attach(player)
        engine.attach(timePitch) // Attach the new audio unit

        let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 24000.0,
                                        channels: 2,
                                        interleaved: false)!

        // Connect player -> timePitch -> main output, instead of player -> main output
        engine.connect(player, to: timePitch, format: audioFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: audioFormat)
        
        player.volume = self.volume // Use the state variable for the initial volume
        timePitch.rate = self.currentSpeed

        do {
            try engine.start()
        } catch {
            print("❌ Could not start AVAudioEngine: \(error)")
        }
    }
    
    /// Programmatically performs a left mouse click at a given screen coordinate.
    private func performClick(at point: CGPoint) {
        // The 'point' we receive is in AppKit's global coordinate space (origin at the screen's bottom-left).
        // CGEvent expects coordinates in the CoreGraphics global space (origin at the screen's top-left).
        // We must convert the Y-coordinate just before clicking.

        // Get the height of the primary screen, which is the axis for the flip.
        guard let primaryScreen = NSScreen.screens.first else {
            print("❌ Could not find primary screen to perform click.")
            return
        }
        let screenHeight = primaryScreen.frame.height

        // Convert the point by flipping the Y-axis.
        let flippedPoint = CGPoint(x: point.x, y: screenHeight - point.y)

        // Now, create the mouse events using the correctly flipped point.
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: flippedPoint, mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: flippedPoint, mouseButton: .left)
        
        mouseDownEvent?.post(tap: .cgSessionEventTap)
        mouseUpEvent?.post(tap: .cgSessionEventTap)
        
        print("🖱️ Performed auto-click at AppKit point \(point) (Converted to CG point: \(flippedPoint))")
    }

    /// Puts the app into the mode for adjusting the blue "Click Zone".
    func startAdjustingNextButtonClickZone() {
        let rectToAdjust = nextButtonClickRect ?? selectionRect ?? NSRect(x: 100, y: 100, width: 100, height: 50)
        
        if let selectionView = selectionWindow.contentView as? SelectionView {
            selectionView.borderColor = .systemBlue // New color for the click zone
            selectionView.needsDisplay = true
        }

        selectionWindow.setFrame(rectToAdjust, display: true)
        selectionWindow.makeKeyAndOrderFront(nil)
        isAdjustingNextButtonClickZone = true
    }

    /// Confirms the position of the "Click Zone" and saves it.
    func confirmNextButtonClickZone() {
        guard isAdjustingNextButtonClickZone else { return }

        self.nextButtonClickRect = self.selectionWindow.frame
        isAdjustingNextButtonClickZone = false
        self.selectionWindow.orderOut(nil)
        statusMessage = "Click zone saved."
        print("✅ Click zone saved to: \(self.nextButtonClickRect!)")
    }

    /// The main logic for handling the auto-next action based on the selected mode.
    private func performAutoNextAction() async {
        statusMessage = "Looking for next button..."
        
        switch autoNextMode {
        case .off:
            // If the mode is off, just stop.
            resetPipeline()
            return
            
        case .fixedZone:
            guard let clickRect = self.nextButtonClickRect else {
                statusMessage = "Error: Click Zone not set."
                resetPipeline()
                return
            }
            // Calculate the center of the fixed zone and click it.
            let clickPoint = CGPoint(x: clickRect.midX, y: clickRect.midY)
            performClick(at: clickPoint)
            
        case .smartOCR:
            // For Smart OCR, we use the 'doNotReadRect' as the search area.
            guard let endOfPageRect = self.doNotReadRect else {
                statusMessage = "Error: End of Page Zone not set."
                resetPipeline()
                return
            }
            
            // Perform OCR only on the "End of Page Zone".
            guard let observations = await performOcrAndGetObservations(on: endOfPageRect) else {
                statusMessage = "Auto-Next: No text found in zone."
                resetPipeline()
                return
            }
            
            // Find the first observation containing "next", "continue", or a right arrow.
            let keywords = ["next", "continue", ">", "→"]
            if let targetObservation = observations.first(where: { observation in
                guard let text = observation.topCandidates(1).first?.string.lowercased() else { return false }
                return keywords.contains(where: text.contains)
            }) {
                // Found it! Calculate the center point to click.
                let boundingBox = targetObservation.boundingBox
                
                // Convert normalized coordinates (top-left origin) to AppKit screen coordinates (bottom-left origin)
                let clickPoint = CGPoint(
                    x: endOfPageRect.minX + (boundingBox.midX * endOfPageRect.width),
                    y: endOfPageRect.minY + (boundingBox.midY * endOfPageRect.height)
                )
                performClick(at: clickPoint)
            } else {
                statusMessage = "Auto-Next: 'Next' button not found."
                resetPipeline()
                return
            }
        }
        
        // Give the page a moment to load before starting the next read cycle.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        // After clicking, start reading again from the main selection rect.
        readFromSelectionRectangle()
    }
    

    // MARK: - Playback Controls
    
    func play() {
        // If we are not already in a playing state, resume.
        if !self.isPlaying {
            self.isPlaying = true
            self.statusMessage = "Playing..."
            player.play()
            // Kickstart the preloading process again in case it was cancelled by pausing.
            preloadNextChunk()
        }
    }
    
    func pause() {
        // If we are currently playing, pause everything.
        if self.isPlaying {
            self.isPlaying = false
            self.statusMessage = "Paused."
            player.pause()
            
            // Cancel any pending generation and discard the next buffer.
            self.isFetchingNextChunk = false
            self.nextBufferToPlay = nil
            print("⏸️ Paused by user. Pending generation cancelled.")
        }
    }
    
    func stop() {
        // Invalidate the current session so any in-flight audio is discarded.
        self.activeSessionID = nil
        // The Stop button should always reset everything.
        resetPipeline()
        // Reset duplicate page detection
        self.firstTextOfCurrentPage = nil
    }
    
    private func updateSkipButtonStates() {
        // Can skip backward if we're not on the very first chunk.
        canSkipBackward = currentlyPlayingId > 0
        // Can skip forward if we're not on the very last chunk.
        canSkipForward = !textChunks.isEmpty && currentlyPlayingId < textChunks.count - 1
    }

    /// Force-plays a specific chunk by its index, generating it if needed.
    private func playChunk(at index: Int) {
        // Ensure the requested index is valid
        guard index >= 0 && index < textChunks.count, let currentSessionID = self.activeSessionID else {
            return
        }

        // Stop any current playback
        player.stop()
        isFetchingNextChunk = false
        nextBufferToPlay = nil

        let chunkToPlay = textChunks[index]
        self.statusMessage = "Generating chunk \(index + 1)..."

        // Generate and play the requested chunk
        generator.generate(text: chunkToPlay.text, voice: selectedVoice, lang: currentLanguage, sessionID: currentSessionID.uuidString) { [weak self] result in
            guard let self = self else { return }

            // Validate the session ID upon completion
            switch result {
            case .success(let (audioURL, returnedSessionID)):
                guard let activeID = self.activeSessionID, activeID.uuidString == returnedSessionID else {
                    print("🗑️ Discarding skipped-to chunk from old session.")
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }

                guard let buffer = self.createBuffer(from: audioURL) else {
                    self.resetPipeline(); return
                }

                self.playBuffer(buffer, withId: chunkToPlay.id, forSessionID: activeID)

            case .failure(let error):
                print("❌ Failed to generate chunk \(index): \(error)")
                self.statusMessage = "Error generating audio."
            }
        }
    }

    func skipToNextChunk() {
        playChunk(at: currentlyPlayingId + 1)
    }

    func skipToPreviousChunk() {
        playChunk(at: currentlyPlayingId - 1)
    }

    func toggleAutoScroll() {
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
            } else {
                print("❌ No screen available to create a default selection rectangle.")
                return
            }
        }

        guard var rect = self.selectionRect else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Instead of using NSScreen.main, which can be ambiguous, we get the first screen
        // in the array, which is guaranteed to be the primary display with the (0,0) origin.
        guard let primaryScreen = NSScreen.screens.first else {
            print("❌ Could not get primary screen.")
            return
        }
        let primaryScreenHeight = primaryScreen.frame.height

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            print("❌ Failed to get the window list.")
            return
        }

        for windowInfo in windows {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != selfPID,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgBounds.height > 50 && cgBounds.width > 50 else {
                continue
            }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "Unknown"
            print("✅ Found target window: \(ownerName)")
            print("   - Window bounds (CoreGraphics, top-down): \(cgBounds)")
            print("   - Primary screen height for conversion: \(primaryScreenHeight)")

            let cgBottomY = cgBounds.origin.y + cgBounds.height
            let newBottomY = primaryScreenHeight - cgBottomY
            print("   - Calculated window bottom in AppKit coords: \(newBottomY)")

            let currentTopY = rect.maxY
            let newHeight = max(50, currentTopY - newBottomY)
            
            rect.origin.y = newBottomY
            rect.size.height = newHeight
            self.selectionRect = rect

            print("   - Final adjusted selection rect: \(rect)")

            startAdjustingSelection()
            return
        }

        print("❌ Could not find a suitable target window to snap to.")
    }
    
    // MARK: - Main Pipeline
    
    func readFromSelectionRectangle() {
        guard !isGenerating else { return }
        shouldCloseMenu = true
        let newSessionID = UUID()
        self.activeSessionID = newSessionID

        self.isPlaying = true
        
        if isAutoScrollEnabled {
        }

        Task {
            self.isGenerating = true
            self.canPlay = false
            self.statusMessage = "Reading screen..."
            await performOcr(on: selectionRect!)
            print("🔍 Starting OCR on rect: \(selectionRect!)")
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
        
        // Calculate the scroll amount to leave a small overlap, ensuring words
        // at the bottom of the previous view are visible at the top of the new one.
        let scrollAmount = rect.height * (1.0 - scrollOverlapPercentage)
        
        scrollDown(by: scrollAmount)

        // Wait for UI to update
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay

        // OCR the new content
        guard let textAfterScroll = await performOcrAndGetText(on: rect) else {
            print("🚫 OCR failed after scroll."); resetPipeline(); return
        }

        var newTextToRead = textAfterScroll
        if !previouslyReadText.isEmpty {
            // Use the last ~150 characters as a stable anchor to find where we left off.
            let anchor = String(previouslyReadText.suffix(150))
            if let range = textAfterScroll.range(of: anchor) {
                newTextToRead = String(textAfterScroll[range.upperBound...])
            }
        }

        // If scrolling down revealed no new text...
        if newTextToRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("✅ Reached end of scrollable content.")
            // ...then check if we should perform the "Auto-Next" action.
            if self.autoNextMode != .off {
                await performAutoNextAction()
            } else {
                // Otherwise, the session is truly over.
                statusMessage = "Auto-scroll finished."
                resetPipeline()
            }
            return
        }

        // Re-detect language for the new block of text
        self.currentLanguage = self.detectLanguage(for: newTextToRead)

        self.previouslyReadText.append(" " + newTextToRead)
        startStreamingPipeline(with: newTextToRead)
    }
    
    private func performOcrAndGetObservations(on rect: CGRect) async -> [VNRecognizedTextObservation]? {
        do {
            guard let capturedImage = try await captureScreen(rect: rect) else {
                return nil
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = Array(Self.languageMap.keys)
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: capturedImage, options: [:])
            try await Task(priority: .userInitiated) { try handler.perform([request]) }.value
            return request.results
        } catch {
            DispatchQueue.main.async { self.statusMessage = "OCR Error: \(error.localizedDescription)" }
            return nil
        }
    }

    private func performOcrAndGetText(on rect: CGRect) async -> String? {
        // 1. Get the raw observations.
        guard let observations = await performOcrAndGetObservations(on: rect) else {
            return nil
        }

        // 2. Perform edge filtering.
        let edgeTolerance: CGFloat = 0.01
        let filteredObservations = observations.filter { observation in
            let boundingBox = observation.boundingBox
            let isTouchingAnEdge = boundingBox.minX <= edgeTolerance ||
                                 boundingBox.maxX >= (1.0 - edgeTolerance) ||
                                 boundingBox.minY <= edgeTolerance ||
                                 boundingBox.maxY >= (1.0 - edgeTolerance)
            return !isTouchingAnEdge
        }

        // 3. Join the filtered text into a single string.
        return filteredObservations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
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
        
        // Check if the newly recognized text is the same as the text from the start of the last page.
        if let firstText = self.firstTextOfCurrentPage, textsAreSimilar(recognizedText, firstText) {
            
            print(" Mismatched")
            statusMessage = "Page hasn't changed, waiting..."
            let startTime = Date()
            let timeout: TimeInterval = 15 // seconds
            
            // Loop for up to 15 seconds
            while Date().timeIntervalSince(startTime) < timeout {
                // Wait for a couple of seconds before checking again
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                
                // After waiting, check if the user manually stopped the app
                guard self.activeSessionID != nil else {
                    print("Session stopped while waiting for page change.")
                    return
                }

                // Re-run OCR to see if the page content has changed
                guard let newlyCheckedText = await performOcrAndGetText(on: rect) else { continue }
                
                // If the text has finally changed, process it and exit this waiting loop.
                if !textsAreSimilar(newlyCheckedText, firstText) {
                    print("✅ Page has changed. Resuming reading.")
                    // Process the new text normally
                    self.firstTextOfCurrentPage = newlyCheckedText
                    self.currentLanguage = self.detectLanguage(for: newlyCheckedText)
                    self.previouslyReadText = newlyCheckedText
                    DispatchQueue.main.async {
                        self.startStreamingPipeline(with: newlyCheckedText)
                    }
                    return // Exit the function successfully
                } else {
                    print("... still on the same page, continuing to wait.")
                }
            }
            
            // If the 15-second loop finishes and the page never changed, give up.
            print("❌ Timed out after 15 seconds. Page did not change. Stopping.")
            DispatchQueue.main.async {
                self.statusMessage = "Page did not change. Stopping."
                self.stop()
            }

        } else {
            // This is a new, non-duplicate page. Process it normally.
            DispatchQueue.main.async {
                if recognizedText.isEmpty {
                    self.statusMessage = "No text found."
                    self.isGenerating = false
                } else {
                    // This is a new page, so save its text as the new baseline for our duplicate check.
                    self.firstTextOfCurrentPage = recognizedText
                    
                    self.currentLanguage = self.detectLanguage(for: recognizedText)
                    self.previouslyReadText = recognizedText
                    self.startStreamingPipeline(with: recognizedText)
                }
            }
        }
    }

    private func startStreamingPipeline(with fullText: String) {
        let filteredText = self.filterIgnoredText(from: fullText)

        // Replace any bullet point characters with a period and a space for a natural pause.
        let cleanedText = filteredText.replacingOccurrences(of: "•", with: ". ")

        // If filtering and cleaning removed all the text, stop here.
        if cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "All text was ignored or empty."
            if let activeID = self.activeSessionID {
                Task { await handleChunkFinished(forSessionID: activeID) }
            }
            return
        }

        print("▶️ Starting new streaming pipeline with filtered text.")
        resetPipeline()
        isGenerating = true

        let trimmedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let minWords = 25
        let maxWords = 50

        // Step 1: Use NLTokenizer to split the text into sentences while preserving punctuation
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmedText

        let sentenceRanges = tokenizer.tokens(for: trimmedText.startIndex..<trimmedText.endIndex)

        // Create an array of sentences, each with its punctuation intact.
        let sentences = sentenceRanges.map { String(trimmedText[$0]) }

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
        
        guard let currentSessionID = self.activeSessionID else { return } // Ensure session is active

        self.statusMessage = "Generating first audio chunk..."
        print("📤 Sending chunk to generator: '\(firstChunk.text)'")
        generator.generate(text: firstChunk.text, voice: selectedVoice, lang: currentLanguage, sessionID: currentSessionID.uuidString) { [weak self] result in
            guard let self = self, self.currentlyPlayingId == -1 else { return }
            
            self.isGenerating = false
            
            switch result {
            case .success(let (audioURL, returnedSessionID)):
                guard let activeID = self.activeSessionID, activeID.uuidString == returnedSessionID else {
                    print("🗑️ Discarding buffer from old or stopped session.")
                    try? FileManager.default.removeItem(at: audioURL) // Clean up the temp file
                    return
                }

                guard let buffer = self.createBuffer(from: audioURL) else {
                    self.resetPipeline(); return
                }
                
                self.playBuffer(buffer, withId: firstChunk.id, forSessionID: activeID)

            case .failure(let error):
                print("❌ Failed to generate the first chunk: \(error)")
                self.resetPipeline()
            }
        }
    }
    
    private func preloadNextChunk() {
        // Only fetch the next chunk if we are in a playing state.
        guard !isFetchingNextChunk, isPlaying else { return }
        
        let nextId = currentlyPlayingId + 1
        guard nextId < textChunks.count else { return }
        
        let chunkToFetch = textChunks[nextId]
        
        guard let currentSessionID = self.activeSessionID else { return } // Ensure session is active

        isFetchingNextChunk = true
        self.statusMessage = "Generating chunk \(nextId + 1) of \(textChunks.count)..."

        generator.generate(text: chunkToFetch.text, voice: selectedVoice, lang: currentLanguage, sessionID: currentSessionID.uuidString) { [weak self] result in
            guard let self = self, self.isFetchingNextChunk else {
                // If isFetchingNextChunk became false, it means the user paused/stopped.
                return
            }
            
            self.isFetchingNextChunk = false

            switch result {
            case .success(let (audioURL, returnedSessionID)):
                guard let activeID = self.activeSessionID, activeID.uuidString == returnedSessionID else {
                    print("🗑️ Discarding preloaded buffer from old or stopped session.")
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }

                if let buffer = self.createBuffer(from: audioURL) {
                    print("  ✅ Pre-loaded chunk ID \(chunkToFetch.id).")
                    self.nextBufferToPlay = (id: chunkToFetch.id, buffer: buffer)
                    
                    // Only kickstart the next chunk if the user is still in the playing state.
                    if self.isPlaying {
                        print("   Player is active, kicking off next chunk.")
                        if let activeID = self.activeSessionID {
                            Task {
                                await self.handleChunkFinished(forSessionID: activeID)
                            }
                        }
                    }
                }
                
            case .failure(let error):
                print("❌ Failed to generate chunk ID \(chunkToFetch.id): \(error)")
            }
        }
    }
    
    private func playBuffer(_ buffer: AVAudioPCMBuffer, withId id: Int, forSessionID sessionID: UUID) {
        updateSkipButtonStates()
        self.currentlyPlayingId = id
        self.statusMessage = "Playing chunk \(id + 1) of \(textChunks.count)..."
        self.canPlay = true
        self.isPlaying = true
        
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task {
                await self?.handleChunkFinished(forSessionID: sessionID)
            }
        }
        
        if !player.isPlaying {
            player.play()
        }
        
        preloadNextChunk()
    }
    
    private func handleChunkFinished(forSessionID finishedSessionID: UUID) async {
        guard finishedSessionID == self.activeSessionID else {
            print("🗑️ Ignoring completion event from a stale session.")
            return
        }

        if let next = nextBufferToPlay, next.id == currentlyPlayingId + 1 {
            print("  ▶️ Playing pre-loaded chunk ID \(next.id).")
            self.nextBufferToPlay = nil

            // Pause for a brief moment before playing the next chunk.
            do {
                try await Task.sleep(nanoseconds: UInt64(self.interChunkDelay * 1_000_000_000))
            } catch {
                print("Task was cancelled, not playing next chunk.")
                return
            }

            // Check the session ID again after the delay, in case stop() was pressed during the pause.
            guard finishedSessionID == self.activeSessionID else {
                print("🗑️ Ignoring chunk after delay due to new session or stop.")
                return
            }

            playBuffer(next.buffer, withId: next.id, forSessionID: finishedSessionID)
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
                                    // Priority 1: If auto-scroll is ON, always attempt to scroll.
                                    // The scrollAndReadNextPage() function is responsible for calling auto-next if it hits the bottom.
                                    if self.isAutoScrollEnabled {
                                        print("▶️ End of content detected. Attempting to scroll first...")
                                        await self.scrollAndReadNextPage()
                                    }
                                    // Priority 2: If scroll is OFF, but auto-next is ON, then click.
                                    else if self.autoNextMode != .off {
                                        print("▶️ End of content detected. Auto-scroll is off. Performing auto-next action...")
                                        await self.performAutoNextAction()
                                    }
                                    // Priority 3: If both are off, stop.
                                    else {
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
        canSkipForward = false
        canSkipBackward = false
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
    
    private func detectLanguage(for text: String) -> String {
        
        let recognizer = NLLanguageRecognizer()
        let supportedNLanguages = Self.languageMap.keys.map { NLLanguage(rawValue: $0) }
        recognizer.languageConstraints = supportedNLanguages
        recognizer.processString(text)

        // Check the confidence level of the top guess ---
        // We ask for the most likely language and its confidence score (a value between 0.0 and 1.0).
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        
        let confidenceThreshold = 0.8
        
        if let topGuess = hypotheses.first {
            print("ℹ️ Raw language detection: \(topGuess.key.rawValue) (Confidence: \(String(format: "%.2f", topGuess.value)))")
        }

        if let dominantLanguage = hypotheses.first, dominantLanguage.value >= confidenceThreshold {
            // If confidence is high enough, use the detected language.
            let detectedLangCode = dominantLanguage.key.rawValue
            let espeakCode = Self.languageMap[detectedLangCode] ?? "en-us"
            print("✅ NaturalLanguage detected '\(detectedLangCode)' with high confidence. Mapped to: '\(espeakCode)'")
            return espeakCode
        } else {
            // If confidence is low, or no language was dominant, fall back to English.
            let detectedLangCode = recognizer.dominantLanguage?.rawValue ?? "N/A"
            let confidence = hypotheses.first?.value ?? 0.0
            print("⚠️ Language detection confidence (\(String(format: "%.2f", confidence))) is below threshold. Detected '\(detectedLangCode)'. Defaulting to English.")
            return "en-us"
        }
    }

    private func textsAreSimilar(_ text1: String, _ text2: String) -> Bool {
        let words1 = Set(text1.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let words2 = Set(text2.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })

        guard !words1.isEmpty, !words2.isEmpty else { return false }

        let commonWords = words1.intersection(words2)
        let resemblance = Double(commonWords.count) / Double(words1.count)

        // If the new text is >90% similar to the start of the last page, consider it a duplicate.
        return resemblance > 0.90
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

        if let selectionView = selectionWindow.contentView as? SelectionView {
            selectionView.borderColor = .red
            selectionView.needsDisplay = true
        }

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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
            throw NSError(domain: "TTSManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find a display for the selection."])
        }

        guard let screen = NSScreen.screens.first(where: {
            // Get the screen's unique ID from its device description dictionary
            let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            // Compare it to the display's ID from ScreenCaptureKit
            return screenNumber == display.displayID
        }) else {
            throw NSError(domain: "TTSManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find a matching NSScreen for the selected display."])
        }
        let scaleFactor = screen.backingScaleFactor
        
        var localRect = rect
        localRect.origin.x -= screen.frame.origin.x
        localRect.origin.y -= screen.frame.origin.y
        
        let captureRect = CGRect(
            x: localRect.origin.x * scaleFactor,
            y: (screen.frame.height - localRect.origin.y - localRect.height) * scaleFactor,
            width: localRect.width * scaleFactor,
            height: localRect.height * scaleFactor
        )

        let config = SCStreamConfiguration()
        config.sourceRect = captureRect
        config.width = Int(captureRect.width)
        config.height = Int(captureRect.height)
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        hasCapturedFrame = false
        try captureStream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        
        return try await withCheckedThrowingContinuation { continuation in
            self.captureContinuation = continuation
            self.captureStream?.startCapture()
        }
    }
    
    func startAdjustingDoNotReadZone() {
        let rectToAdjust: NSRect

        // If a "Do Not Read" rect already exists, use it.
        if let existingDNRRect = doNotReadRect {
            rectToAdjust = existingDNRRect
        }
        // Otherwise, create a new, independent default rect.
        // We can intelligently place it near the main selection rect if it exists.
        else if let currentSelectionRect = selectionRect {
            // Create a new, smaller rect centered inside the current selection rect.
            // This provides a good starting point without being identical.
            rectToAdjust = NSRect(
                x: currentSelectionRect.midX - 150,
                y: currentSelectionRect.midY - 75,
                width: 300,
                height: 150
            )
        } else {
            // Absolute fallback if no other rect exists at all.
            rectToAdjust = NSRect(x: 100, y: 100, width: 300, height: 150)
        }
        
        // Set the visual style for the "Do Not Read" zone
        if let selectionView = selectionWindow.contentView as? SelectionView {
            selectionView.borderColor = .systemOrange
            selectionView.needsDisplay = true
        }

        selectionWindow.setFrame(rectToAdjust, display: true)
        selectionWindow.makeKeyAndOrderFront(nil)
        isAdjustingDoNotReadZone = true
    }

    func confirmDoNotReadZone() async {
        guard isAdjustingDoNotReadZone else { return }
        shouldCloseMenu = true

        self.doNotReadRect = self.selectionWindow.frame
        isAdjustingDoNotReadZone = false
        self.selectionWindow.orderOut(nil)

        // Now, perform OCR on this zone to get the text to ignore.
        statusMessage = "Saving text to ignore..."
        if let textToIgnore = await performOcrAndGetText(on: self.doNotReadRect!) {
            if !textToIgnore.isEmpty {
                ignoredTextSnippets.append(textToIgnore)
                // Permanently save the updated list.
                UserDefaults.standard.set(ignoredTextSnippets, forKey: "ignoredTextSnippets")
                statusMessage = "Ignored text saved."
                print("✅ Added to ignore list: \(textToIgnore)")
            } else {
                statusMessage = "No text found in zone."
            }
        }
    }

    private func filterIgnoredText(from text: String) -> String {
        guard !ignoredTextSnippets.isEmpty else { return text }

        // How many words from the start of a snippet to use as its unique "signature".
        let markerLength = 7
        // How similar a sentence has to be to this signature to be considered a match.
        let resemblanceThreshold = 0.8 // e.g., ~5 of 7 words must match

        // 1. Tokenize the incoming text into an array of sentences.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentenceRanges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        let sentences = sentenceRanges.map { String(text[$0]) }
        
        // 2. Create "signatures" for each of your saved ignored snippets.
        // A signature is just the first few words of the snippet.
        let snippetSignatures = ignoredTextSnippets.map {
            Set($0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.prefix(markerLength))
        }
        
        // 3. Find the index of the first sentence that matches a signature.
        var firstIgnoredSentenceIndex: Int? = nil

        for (index, sentence) in sentences.enumerated() {
            let wordsInSentence = Set(sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
            if wordsInSentence.count < 3 { continue }
            
            for signature in snippetSignatures {
                if signature.isEmpty { continue }
                
                let commonWords = wordsInSentence.intersection(signature)
                
                // Does this sentence highly resemble the start of an ignored snippet?
                let resemblance = Double(commonWords.count) / Double(signature.count)
                
                if resemblance >= resemblanceThreshold {
                    print("🗑️ Found stop marker (Resemblance: \(String(format: "%.2f", resemblance))). Ignoring this and all subsequent text.")
                    firstIgnoredSentenceIndex = index
                    break // Found a match, stop checking snippets
                }
            }
            
            if firstIgnoredSentenceIndex != nil {
                break // Found a match, stop checking sentences
            }
        }
        
        // 4. If we found a "stop marker" sentence, return only the text that came before it.
        if let index = firstIgnoredSentenceIndex {
            return sentences.prefix(index).joined(separator: " ")
        } else {
            // Otherwise, return the original text unchanged.
            return text
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
    
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // This function is called by the system if the stream fails to start.
        Task { @MainActor in
            print("❌ Stream failed with error: \(error.localizedDescription)")
            
            // This ensures the app doesn't hang
            self.captureContinuation?.resume(returning: nil)
            self.captureContinuation = nil
        }
    }
}
