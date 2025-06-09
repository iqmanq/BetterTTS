// File: MainViewController.swift

import Cocoa
import AVFoundation

// Helper struct to parse the tokenizer's JSON configuration
struct TokenizerConfig: Codable {
    struct ModelConfig: Codable {
        let vocab: [String: Int]
    }
    let model: ModelConfig
}

// Helper struct to parse the voices.json file
typealias VoicesConfig = [String: [[[Float]]]]

class MainViewController: NSViewController {

    // --- UI Elements (created in code, NOT @IBOutlets) ---
    private let inputTextView = NSTextView()
    private let playButton = NSButton(title: "▶️ Play", target: nil, action: nil)
    private let pauseButton = NSButton(title: "⏸ Pause", target: nil, action: nil)

    // --- C-API and Audio Properties ---
    private var ortApi: UnsafePointer<OrtApi>?
    private var ortEnv: OpaquePointer?
    private var ortSession: OpaquePointer?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let sampleRate: Double = 22050.0
    
    // --- Loaded Data Properties ---
    private var vocabulary: [String: Int]?
    private var voices: VoicesConfig?
    
    // --- Tokenizer Constants ---
    private let bosTokenID = 2 // Begin of Sentence
    private let eosTokenID = 3 // End of Sentence
    private let unkTokenID = 1 // Unknown Character

    // MARK: - View Lifecycle

    override func loadView() {
        // This is the designated method for creating a UI programmatically.
        // It runs before viewDidLoad.
        
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        // Configure and add the UI elements to the view
        configureTextView()
        configureButtons()
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = inputTextView
        scrollView.hasVerticalScroller = true
        
        let buttonStack = NSStackView(views: [playButton, pauseButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        
        view.addSubview(scrollView)
        view.addSubview(buttonStack)

        // Set up Auto Layout constraints to position the elements
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            buttonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            scrollView.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        
        // Finally, set this newly constructed view as the controller's view.
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // These can now be called safely because the view and its subviews were created in loadView().
        setupAudioEngine()
        loadModelData()
        loadOnnxModel()
        inputTextView.string = "This is the final test, which I am confident will work."
    }
    
    // Helper methods to configure the UI elements
    private func configureTextView() {
        inputTextView.isEditable = true
        inputTextView.isSelectable = true
        inputTextView.font = NSFont.systemFont(ofSize: 16)
        inputTextView.isRichText = false
        inputTextView.allowsUndo = true
        inputTextView.autoresizingMask = .width
    }
    
    private func configureButtons() {
        playButton.target = self
        playButton.action = #selector(playButtonPressed)
        
        pauseButton.target = self
        pauseButton.action = #selector(pauseButtonPressed)
    }

    deinit {
        if let session = ortSession { ortApi?.pointee.ReleaseSession?(session) }
        if let env = ortEnv { ortApi?.pointee.ReleaseEnv?(env) }
    }

    // MARK: - Actions
    
    @objc func playButtonPressed(_ sender: Any) {
        guard let button = sender as? NSButton else { return }
        
        guard let firstVoiceEmbedding = voices?.first?.value.first?.first else {
            print("❌ No valid voice embedding found in voices.json.")
            return
        }
        
        button.isEnabled = false
        print("▶️ Play pressed...")

        let textToSynthesize = self.inputTextView.string

        DispatchQueue.global(qos: .userInitiated).async {
            guard let tokenIDs = self.runTokenizer(for: textToSynthesize) else {
                DispatchQueue.main.async { print("❌ Failed to tokenize text."); button.isEnabled = true }
                return
            }
            
            guard let buffer = self.generateAudio(from: tokenIDs, styleEmbedding: firstVoiceEmbedding) else {
                DispatchQueue.main.async { print("❌ Failed to generate audio."); button.isEnabled = true }
                return
            }
            
            DispatchQueue.main.async {
                self.play(buffer: buffer) { button.isEnabled = true }
            }
        }
    }

    @objc func pauseButtonPressed() {
        playerNode?.pause()
        print("⏸ Paused")
    }
    
    func play(buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        playerNode?.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            DispatchQueue.main.async {
                print("🔊 Playback completed.")
                completion()
            }
        }
        if let engine = self.audioEngine, !engine.isRunning {
            do { try engine.start() } catch { print("❌ Audio engine start error: \(error)"); completion(); return }
        }
        playerNode?.play()
    }

    // MARK: - Setup & Data Loading
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = audioEngine, let player = playerNode else { return }
        engine.attach(player)
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: monoFormat)
        print("✅ Audio engine ready.")
    }
    
    private func loadModelData() {
        if let url = Bundle.main.url(forResource: "tokenizer", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                self.vocabulary = try JSONDecoder().decode(TokenizerConfig.self, from: data).model.vocab
                print("✅ Tokenizer vocabulary loaded.")
            } catch { print("❌ Failed to load tokenizer.json: \(error)") }
        } else { print("❌ tokenizer.json not found.") }

        if let url = Bundle.main.url(forResource: "voices", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                self.voices = try JSONDecoder().decode(VoicesConfig.self, from: data)
                print("✅ Speaker embeddings loaded for \(self.voices?.count ?? 0) voices.")
            } catch { print("❌ Failed to load voices.json: \(error)") }
        } else { print("❌ voices.json not found.") }
    }

    private func loadOnnxModel() {
        guard let modelPath = Bundle.main.path(forResource: "model_quantized", ofType: "onnx") else {
            print("❌ model_quantized.onnx not found."); return
        }
        ortApi = GetOrtApi()
        guard let api = ortApi else { print("❌ Failed to get OrtApi."); return }
        guard api.pointee.CreateEnv?(ORT_LOGGING_LEVEL_WARNING, "BetterTTS", &ortEnv) == nil else {
            print("❌ Failed to create ONNX environment."); return
        }
        var sessionOptions: OpaquePointer?
        guard api.pointee.CreateSessionOptions?(&sessionOptions) == nil else { return }
        defer { api.pointee.ReleaseSessionOptions?(sessionOptions) }
        guard api.pointee.CreateSession?(ortEnv, modelPath, sessionOptions, &ortSession) == nil else {
            print("❌ Failed to create ONNX session."); return
        }
        print("✅ ONNX model loaded.")
    }
    
    // MARK: - Swift Tokenizer and C-Wrapper Inference
    private func runTokenizer(for text: String) -> [Int64]? {
        guard let vocab = self.vocabulary else { print("❌ Vocabulary not loaded."); return nil }
        var tokenIDs = text.lowercased().map { Int64(vocab[String($0)] ?? self.unkTokenID) }
        tokenIDs.insert(Int64(self.bosTokenID), at: 0)
        tokenIDs.append(Int64(self.eosTokenID))
        return tokenIDs
    }

    private func generateAudio(from tokenIDs: [Int64], styleEmbedding: [Float]) -> AVAudioPCMBuffer? {
        guard let api = ortApi, let session = ortSession else { return nil }
        
        var audioOutput: UnsafeMutablePointer<Float>? = nil
        var audioSize: Int64 = 0
        
        let status = RunInference(api, session, tokenIDs, Int64(tokenIDs.count), styleEmbedding, &audioOutput, &audioSize)
        
        if let st = status {
            if let errPtr = api.pointee.GetErrorMessage(st) { print("❌ Inference failed: \(String(cString: errPtr))") }
            api.pointee.ReleaseStatus?(st)
            return nil
        }
        
        guard let audioData = audioOutput else { return nil }
        defer { FreeOrtMemory(audioData) }
        
        let sampleCount = Int(audioSize)
        guard sampleCount > 0 else { print("❌ Inference resulted in zero audio samples."); return nil }
        
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 1)!
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        
        if let channelData = pcmBuffer.floatChannelData?[0] {
            memcpy(channelData, audioData, sampleCount * MemoryLayout<Float>.stride)
        }
        
        print("✅ Audio generated successfully. Sample count: \(sampleCount)")
        return pcmBuffer
    }
}
