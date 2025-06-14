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
    private var generationTimeoutTask: Task<Void, Never>?
    
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
        guard !isGenerating, let rect = selectionRect else { return }
        
        Task {
            self.isGenerating = true
            self.canPlay = false
            self.statusMessage = "Reading screen..."
            await performOcr(on: rect)
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
        stop()
        isGenerating = true
        
        let words = fullText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        self.textChunks = words.chunked(into: 10).map { $0.joined(separator: " ") }.enumerated().map { (id: $0.offset, text: $0.element) }
        
        guard !textChunks.isEmpty else {
            print("No text chunks to process."); resetPipeline(); return
        }

        let firstChunk = textChunks[0]
        self.statusMessage = "Generating first audio chunk..."
        
        // --- ADDED TIMEOUT ---
        // Failsafe to prevent getting stuck forever.
        generationTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15 seconds
            if !Task.isCancelled {
                print("❌ Generation timed out.")
                resetPipeline()
            }
        }

        generator.generate(text: firstChunk.text, voice: selectedVoice) { [weak self] result in
            guard let self = self else { return }
            
            self.generationTimeoutTask?.cancel() // Cancel the timeout since we got a result.
            
            guard self.isGenerating else { return } // Ensure we are still in a valid state
            
            self.isGenerating = false
            
            switch result {
            case .success(let audioURL):
                guard let buffer = self.createBuffer(from: audioURL) else {
                    print("❌ Failed to create buffer for the first chunk.")
                    self.resetPipeline(); return
                }
                print("  ✅ First chunk (ID 0) is ready to play.")
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
                    // If the player is waiting for this specific chunk, play it now.
                    if self.player.isPlaying && self.currentlyPlayingId == nextId - 1 {
                        self.handleChunkFinished()
                    }
                } else {
                    print("❌ Failed to create buffer for chunk ID \(chunkToFetch.id).")
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
        
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                self?.handleChunkFinished()
            }
        }
        
        if !player.isPlaying {
            player.play()
        }
        self.isPlaying = true
        
        preloadNextChunk()
    }
    
    private func handleChunkFinished() {
        if let next = nextBufferToPlay, next.id == currentlyPlayingId + 1 {
            print("  ▶️ Playing pre-loaded chunk ID \(next.id).")
            self.nextBufferToPlay = nil
            playBuffer(next.buffer, withId: next.id)
        } else if currentlyPlayingId == textChunks.count - 1 {
            print("⏹️ Final chunk finished. Stopping.")
            resetPipeline()
        } else {
             print("... Waiting for chunk \(currentlyPlayingId + 2) to generate.")
             // Start preloading again in case it failed before.
             preloadNextChunk()
        }
    }
    
    private func resetPipeline() {
        generationTimeoutTask?.cancel()
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
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else { return nil }
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
        guard !isGenerating else { return }
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first(where: { $0.frame.contains(rect) }) else {
            throw NSError(domain: "TTSManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find a display for the selection."])
        }

        let sourceRect = CGRect(x: rect.origin.x - display.frame.origin.x, y: rect.origin.y - display.frame.origin.y, width: rect.width, height: rect.height)
        
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(rect.width)
        config.height = Int(rect.height)
        
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
