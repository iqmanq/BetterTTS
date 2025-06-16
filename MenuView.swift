import SwiftUI

struct MenuView: View {
    let voiceDisplayNames: [String: String] = [
        "af_alloy": "American Female: Alloy",
        "af_aoede": "American Female: Aoede",
        "af_bella": "American Female: Bella",
        "af_heart": "American Female: Heart",
        "af_jessica": "American Female: Jessica",
        "af_kore": "American Female: Kore",
        "af_nicole": "American Female: Nicole",
        "af_nova": "American Female: Nova",
        "af_river": "American Female: River",
        "af_sarah": "American Female: Sarah",
        "af_sky": "American Female: Sky",
        "am_adam": "American Male: Adam",
        "am_echo": "American Male: Echo",
        "am_eric": "American Male: Eric",
        "am_fenrir": "American Male: Fenrir",
        "am_liam": "American Male: Liam",
        "am_michael": "American Male: Michael",
        "am_onyx": "American Male: Onyx",
        "am_puck": "American Male: Puck",
        "am_santa": "American Male: Santa",
        "bf_alice": "British Female: Alice",
        "bf_emma": "British Female: Emma",
        "bf_isabella": "British Female: Isabella",
        "bf_lily": "British Female: Lily",
        "bm_daniel": "British Male: Daniel",
        "bm_fable": "British Male: Fable",
        "bm_george": "British Male: George",
        "bm_lewis": "British Male: Lewis",
        "ef_dora": "Spanish Female: Dora",
        "em_alex": "Spanish Male: Alex",
        "em_santa": "Spanish Male: Santa",
        "ff_siwis": "French Female: Siwis",
        "hf_alpha": "Hindi Female: Alpha",
        "hf_beta": "Hindi Female: Beta",
        "hm_omega": "Hindi Male: Omega",
        "hm_psi": "Hindi Male: Psi",
        "if_sara": "Italian Female: Sara",
        "im_nicola": "Italian Male: Nicola",
        "jf_alpha": "Japanese Female: Alpha",
        "jf_gongitsune": "Japanese Female: Gongitsune",
        "jf_nezumi": "Japanese Female: Nezumi",
        "jf_tebukuro": "Japanese Female: Tebukuro",
        "jm_kumo": "Japanese Male: Kumo",
        "pf_dora": "Portuguese Female: Dora",
        "pm_alex": "Portuguese Male: Alex",
        "pm_santa": "Portuguese Male: Santa",
        "zf_xiaobei": "Chinese Female: Xiaobei",
        "zf_xiaoni": "Chinese Female: Xiaoni",
        "zf_xiaoxiao": "Chinese Female: Xiaoxiao",
        "zf_xiaoyi": "Chinese Female: Xiaoyi"
    ]
    
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
                    Text(voiceDisplayNames[voice] ?? voice).tag(voice)
                }
            }
            
            Divider()
            
            Toggle(isOn: $ttsManager.isAutoScrollEnabled) {
                Text("Auto Scroll & Read")
            }
            .disabled(ttsManager.isAdjustingSelection)
            
            Divider()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
