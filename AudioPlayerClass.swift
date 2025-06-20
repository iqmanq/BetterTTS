import AVFoundation

class AudioPlayer: ObservableObject {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()  // Add this node
    private var audioFile: AVAudioFile?

    init() {
        engine.attach(player)
        engine.attach(timePitch)                          // Attach timePitch node
        engine.connect(player, to: timePitch, format: nil)  // Connect player -> timePitch
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)  // Connect timePitch -> mixer

        try? engine.start()
    }

    func load(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        self.audioFile = file
    }

    func play() {
        guard let audioFile = audioFile else { return }
        
        player.scheduleFile(audioFile, at: nil)
        player.play()
    }

    func pause() {
        player.pause()
    }
    
    func stop() {
        player.stop()
    }
    
    // New function to set playback rate
    func setPlaybackRate(_ rate: Float) {
        timePitch.rate = rate
    }
}
