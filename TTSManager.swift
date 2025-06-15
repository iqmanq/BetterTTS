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
    
    // MARK: - Core Components
    private let generator = AudioGenerator()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // MARK: - Streaming Pipeline State
    private var textChunks: [(id: Int, text: String)] = []
    private var nextBufferToPlay: (id: Int, buffer: AVAudioPCMBuffer)?
    private var currentlyPlayingId: Int = -1
    private var isFetchingNextChunk: Bool = false
    
    // Screen Capture state
    private var selectionWindow: NSWindow?
    private var captureStream: SCStream?
    private var captureContinuation: CheckedContinuation<CGImage?, Error>?

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
        
        player.volume = 0.1
        
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
    
    // MARK: - Main Pipeline
    
    func readFromSelectionRectangle() {
        guard !isGenerating && !isPlaying, let rect = selectionRect else { return }
        
        Task {
            self.isGenerating = true
            self.canPlay = false
            self.statusMessage = "Reading screen..."
            await performOcr(on: rect)
            print("🔍 Starting OCR on rect: \(rect)")
        }
    }
    
    private func performOcr(on rect: CGRect) async {
        do {
            guard let capturedImage = try await captureScreen(rect: rect) else {
                self.statusMessage = "Screen capture failed."; self.isGenerating = false; return
            }
            
            let request = VNRecognizeTextRequest { [weak self] (request, error) in
                DispatchQueue.main.async {
                    guard let self = self, let observations = request.results as? [VNRecognizedTextObservation] else {
                        self?.statusMessage = "Text recognition failed."; self?.isGenerating = false; return
                    }
                    
                    let recognizedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    print("🧠 OCR recognized text: '\(recognizedText)'")
                    if recognizedText.isEmpty {
                        self.statusMessage = "No text found."; self.isGenerating = false
                    } else {
                        self.startStreamingPipeline(with: recognizedText)
                    }
                }
            }
            
            try VNImageRequestHandler(cgImage: capturedImage, options: [:]).perform([request])
            
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "OCR Error: \(error.localizedDescription)"; self.isGenerating = false
            }
        }
    }
    
    private func startStreamingPipeline(with fullText: String) {
        print("▶️ Starting new streaming pipeline.")
        resetPipeline()
        isGenerating = true
        
        let punctuationSet = CharacterSet(charactersIn: ".!?,;:•—")
        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        let chunks: [String]
        if trimmedText.rangeOfCharacter(from: punctuationSet) != nil {
            // Split at punctuation boundaries
            chunks = trimmedText.components(separatedBy: punctuationSet)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            // Fallback: split by words every 10
            let words = trimmedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let wordChunks = words.chunked(into: 10)
            chunks = wordChunks.map { $0.joined(separator: " ") }
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
            print("⏹️ Final chunk finished. Stopping.")
            resetPipeline()
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
    
    // MARK: - UI and Screen Capture (unchanged)
    
    func startAdjustingSelection() {
        guard !isGenerating && !isPlaying else { return }
        let rect = selectionRect ?? NSRect(x: 100, y: 100, width: 400, height: 300)
        let window = SelectionWindow(contentRect: rect)
        self.selectionWindow = window
        let selectionView = SelectionView(frame: .zero)
        self.selectionWindow?.contentView = selectionView
        selectionView.onSelectionEnded = { [weak self] finalRect in self?.selectionRect = finalRect }
        self.selectionWindow?.makeKeyAndOrderFront(nil)
        isAdjustingSelection = true
    }
    
    func confirmSelection() {
        guard isAdjustingSelection, let window = selectionWindow else { return }
        selectionRect = window.frame
        isAdjustingSelection = false
        window.orderOut(nil)
    }
    
    private func captureScreen(rect: CGRect) async throws -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else {
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
        
        try captureStream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        
        return try await withCheckedThrowingContinuation { continuation in
            self.captureContinuation = continuation
            self.captureStream?.startCapture()
        }
    }
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        Task { @MainActor in
            guard sampleBuffer.isValid, let pBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pBuffer, options: nil, imageOut: &cgImage)
            try? await stream.stopCapture()
            self.captureContinuation?.resume(returning: cgImage)
            self.captureContinuation = nil
        }
    }
}
