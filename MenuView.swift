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
        "zf_xiaoyi": "Chinese Female: Xiaoyi",
        "zm_yunjian": "Chinese Male: Yunjian",
        "zm_yunxi": "Chinese Male: Yunxi",
        "zm_yunxia": "Chinese Male: Yunxia",
        "zm_yunyang": "Chinese Male: Yunyang"
    ]
    
    @EnvironmentObject var ttsManager: TTSManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            Text(ttsManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if ttsManager.isAdjustingSelection {
                Button("Confirm Selection") { ttsManager.confirmSelection() }
            } else if ttsManager.isAdjustingDoNotReadZone {
                Button("Confirm End of Page Zone") {
                    Task { await ttsManager.confirmDoNotReadZone() }
                }
            } else if ttsManager.isAdjustingNextButtonClickZone {
                Button("Confirm Click Zone") { ttsManager.confirmNextButtonClickZone() }
            } else {
                HStack {
                    Button("Adjust Selection") { ttsManager.startAdjustingSelection() }
                    Spacer()
                    Button("Read Area") { ttsManager.readFromSelectionRectangle() }
                        .disabled(ttsManager.selectionRect == nil || ttsManager.isGenerating)
                }
                Button("Set End of Page Zone") { ttsManager.startAdjustingDoNotReadZone() }
            }
            
            Divider()
            
            HStack {
                Button(action: { ttsManager.skipToPreviousChunk() }) {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(!ttsManager.canSkipBackward)

                Button(action: { ttsManager.pause() }) {
                    Image(systemName: "pause.fill")
                }
                .disabled(!ttsManager.isPlaying)

                Button(action: { ttsManager.play() }) {
                    Image(systemName: "play.fill")
                }
                .disabled(!ttsManager.canPlay || ttsManager.isPlaying)
                
                Button(action: { ttsManager.stop() }) {
                    Image(systemName: "stop.fill")
                }
                .disabled(!ttsManager.canPlay && !ttsManager.isPlaying)

                Button(action: { ttsManager.skipToNextChunk() }) {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(!ttsManager.canSkipForward)
            }
            .frame(maxWidth: .infinity)
            
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                Slider(value: $ttsManager.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
            }

            Picker("Voice:", selection: $ttsManager.selectedVoice) {
                ForEach(ttsManager.availableVoices, id: \.self) { voice in
                    Text(voiceDisplayNames[voice] ?? voice).tag(voice)
                }
            }
            
            Divider()
           
            Button(action: { ttsManager.cycleSpeed() }) {
                Text(String(format: "Speed: %.2fx", ttsManager.currentSpeed))
            }
            .frame(maxWidth: .infinity)
            
            Divider()

            Toggle(isOn: $ttsManager.isAutoScrollEnabled) {
                Text("Auto Scroll & Read")
            }
            .disabled(ttsManager.isAdjustingSelection)
            
            Divider()
            
            Text("Auto-Next Page").font(.caption).foregroundColor(.secondary)

            Picker("Mode:", selection: $ttsManager.autoNextMode) {
                ForEach(AutoNextMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            // Show the appropriate button based on the selected mode
            if ttsManager.autoNextMode == .fixedZone {
                Button("Set Click Zone") { ttsManager.startAdjustingNextButtonClickZone() }
            } else if ttsManager.autoNextMode == .smartOCR {
                Button("Set End of Page Zone") { ttsManager.startAdjustingDoNotReadZone() }
                    .help("Define the area where the app will search for a 'Next' button.")
            }

            Divider()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
        .onChange(of: ttsManager.shouldCloseMenu) {
            if ttsManager.shouldCloseMenu {
                dismiss() // Close the window
                ttsManager.shouldCloseMenu = false // Reset the signal
            }
        }
    }
}
