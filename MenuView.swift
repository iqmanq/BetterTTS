import SwiftUI

struct MenuView: View {
    @EnvironmentObject var ttsManager: TTSManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            Text(ttsManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if ttsManager.isAdjustingSelection {
                Button("Confirm Selection") { ttsManager.confirmSelection() }
            } else {
                HStack {
                    Button("Adjust Selection") { ttsManager.startAdjustingSelection() }
                    Spacer()
                    Button("Read Area") { ttsManager.readFromSelectionRectangle() }
                        .disabled(ttsManager.selectionRect == nil || ttsManager.isGenerating)
                }
            }
            
            Divider()
            
            HStack {
                Button(action: { ttsManager.play() }) {
                    Image(systemName: "play.fill")
                }
                .disabled(!ttsManager.canPlay || ttsManager.isPlaying)
                
                Button(action: { ttsManager.pause() }) {
                    Image(systemName: "pause.fill")
                }
                .disabled(!ttsManager.isPlaying)

                Button(action: { ttsManager.stop() }) {
                    Image(systemName: "stop.fill")
                }
                .disabled(!ttsManager.canPlay && !ttsManager.isPlaying)
            }
            .frame(maxWidth: .infinity)
            
            Picker("Voice:", selection: $ttsManager.selectedVoice) {
                ForEach(ttsManager.availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            
            Divider()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
