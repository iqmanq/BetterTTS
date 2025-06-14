import AVFoundation

class AudioPlayer: ObservableObject {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
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
}
