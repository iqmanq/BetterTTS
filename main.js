// This code goes into your WebContent/main.js

// STEP 1: Import the @huggingface/transformers library
import { env as hfEnv } from '@huggingface/transformers';
// You might need other specific imports depending on how KokoroTTS directly uses the library,
// e.g., specific model classes or pipeline functions if KokoroTTS doesn't abstract them completely.

// STEP 2: Import your minified KokoroTTS class from kokoro.web.js
// This path assumes kokoro.web.js is in the same directory as main.js
// in your WebContent source structure, or adjust as needed (e.g., './src/kokoro.web.js').
// Vite will bundle this into index-BOPVmeCY.js.
import { KokoroTTS } from './kokoro.web.js'; // Ensure this path is correct for your WebContent structure

// STEP 3: Define sendToSwift function
function sendToSwift(messagePayload) {
    if (window.webkit?.messageHandlers?.ttsHandler) {
        window.webkit.messageHandlers.ttsHandler.postMessage(messagePayload);
    } else {
        const level = messagePayload.level || "info";
        let msgContent = messagePayload.message || "";
        if (messagePayload.type === "audioData") {
            msgContent = "Audio Data (ttsHandler not found, data not sent to Swift)";
            console.log("Fallback audio data (base64):", messagePayload.data ? String(messagePayload.data).substring(0,100) + "..." : "null");
        }
        if (level === "error" || level === "exception") {
            console.error("JS Log (Fallback):", msgContent, messagePayload.error_name || "", messagePayload.stack || "");
        } else {
            console.log("JS Log (Fallback):", msgContent);
        }
    }
}
window.sendToSwift = sendToSwift;
sendToSwift({ type: "js_log", level: "info", message: "JS (Vite Bundle - main.js): Execution started. sendToSwift defined." });

// STEP 4: Global TTS State
let CurrentKokoroTTSClass = KokoroTTS; // The class imported from kokoro.web.js
let tts_pipeline_global = null;
let js_available_voices_global = ["Loading..."]; // Default

// STEP 5: Configure ONNX Runtime WASM paths for @huggingface/transformers
// The library will look for WASM files relative to this bundled JS file (index-BOPVmeCY.js).
// Your Vite build places index-BOPVmeCY.js and the WASM file(s)
// (e.g., ort-wasm-simd-threaded.jsep-B0T3yYHD.wasm) in the same 'dist/assets/' directory.
// Setting paths to './' tells it to look in the current directory (dist/assets/).
// Check @huggingface/transformers documentation for the most current or specific way to set this.
//hfEnv.backends.onnx.wasm.wasmPaths = './';
// If the library expects specific non-hashed names, you might need a mapping:
// hfEnv.backends.onnx.wasm.wasmPaths = {
//   'ort-wasm.wasm': './ort-wasm-XXXX.wasm', // Replace XXXX with actual hash
//   'ort-wasm-simd.wasm': './ort-wasm-simd-XXXX.wasm',
//   'ort-wasm-simd-threaded.wasm': './ort-wasm-simd-threaded.jsep-B0T3yYHD.wasm' // From your build log
//   // Add other wasm variants if your build produces them and the library might request them
// };
sendToSwift({ type: "js_log", level: "info", message: `JS: Configured WASM paths for @huggingface/transformers. Using: ${JSON.stringify(hfEnv.backends.onnx.wasm.wasmPaths)}` });


// STEP 6: Define window.triggerTTSInitialization (called by Swift)
window.triggerTTSInitialization = async function() {
    sendToSwift({ type: "js_log", level: "info", message: "JS: Swift called window.triggerTTSInitialization(). Now using @huggingface/transformers." });

    if (typeof CurrentKokoroTTSClass !== 'function') {
        sendToSwift({ type: "js_log", level: "error", message: "JS: KokoroTTS class is not available or not a function." });
        sendToSwift({ type: "status", message: "TTS Engine Init Failed: KokoroTTS class missing." });
        return;
    }

    const modelId = "onnx-community/Kokoro-82M-v1.0-ONNX";
    sendToSwift({ type: "js_log", level: "info", message: `JS: Initializing KokoroTTS.from_pretrained with Hub model ID: '${modelId}'` });

    try {
        // This assumes CurrentKokoroTTSClass.from_pretrained is implemented
        // to correctly use @huggingface/transformers for model loading.
        tts_pipeline_global = await CurrentKokoroTTSClass.from_pretrained(modelId, {
            dtype: "q8", // Or your desired dtype
            progress_callback: (progress) => {
                sendToSwift({ type: "js_log", level: "info", message: `JS Model Loading (Hub): ${JSON.stringify(progress)}` });
            }
        });

        sendToSwift({ type: "js_log", level: "info", message: "JS: KokoroTTS Pipeline (model from Hub) initialized successfully!" });
        // This voice list is a placeholder.
        js_available_voices_global = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore"];
        sendToSwift({ type: "voicesList", data: js_available_voices_global });
        sendToSwift({ type: "status", message: "TTS Engine Ready (Hub)." });

    } catch (error) {
        let errorMessage = "JS: EXCEPTION during KokoroTTS.from_pretrained (Hub): " + error.toString();
        let errorName = error.name || "UnknownError";
        let errorStack = error.stack || "No stack available";
        if (error.cause) { errorMessage += " | Cause: " + String(error.cause); if (error.cause.stack) errorStack += "\nCaused by Stack: " + error.cause.stack; }
        sendToSwift({ type: "js_log", level: "exception", message: errorMessage, error_name: errorName, stack: errorStack });
        sendToSwift({ type: "status", message: "TTS Engine Model Init Failed (Hub)." });
    }
};
sendToSwift({ type: "js_log", level: "info", message: "JS: window.triggerTTSInitialization is defined." });

// STEP 7: Define window.pcmToWavBase64
window.pcmToWavBase64 = function(samples, sampleRate) {
    sendToSwift({ type: "js_log", level: "debug", message: `JS: pcmToWavBase64 START. Sample count: ${samples ? samples.length : 0}, Rate: ${sampleRate}`});
    if (!samples || samples.length === 0) {
        sendToSwift({ type: "js_log", level: "warning", message: `JS: pcmToWavBase64 received empty samples. Returning silent WAV.`});
        return "UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA="; // Standard empty WAV
    }
    try {
        const numChannels = 1;
        const bitsPerSample = 16;
        const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
        const blockAlign = numChannels * (bitsPerSample / 8);
        const dataSize = samples.length * numChannels * (bitsPerSample / 8);
        const chunkSize = 36 + dataSize;
        const buffer = new ArrayBuffer(44 + dataSize);
        const view = new DataView(buffer);
        function writeString(view, offset, string) { for (let i = 0; i < string.length; i++) { view.setUint8(offset + i, string.charCodeAt(i)); } }
        writeString(view, 0, 'RIFF'); view.setUint32(4, chunkSize, true); writeString(view, 8, 'WAVE'); writeString(view, 12, 'fmt ');
        view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, numChannels, true); view.setUint32(24, sampleRate, true);
        view.setUint32(28, byteRate, true); view.setUint16(32, blockAlign, true); view.setUint16(34, bitsPerSample, true);
        writeString(view, 36, 'data'); view.setUint32(40, dataSize, true);
        let offset = 44;
        for (let i = 0; i < samples.length; i++, offset += 2) { const s = Math.max(-1, Math.min(1, samples[i])); view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true); }
        const base64Wav = btoa(String.fromCharCode.apply(null, new Uint8Array(buffer)));
        sendToSwift({ type: "js_log", level: "debug", message: "JS: pcmToWavBase64 END. Conversion successful." });
        return base64Wav;
    } catch (e) {
        sendToSwift({ type: "js_log", level: "exception", message: "JS: EXCEPTION in pcmToWavBase64: " + e.toString(), error_name: e.name, stack: e.stack });
        return "UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA="; // Fallback
    }
};
sendToSwift({ type: "js_log", level: "info", message: "JS: pcmToWavBase64 function defined." });

// STEP 8: Define window.synthesizeSpeech
window.synthesizeSpeech = async function(text, voiceName) {
    sendToSwift({ type: "js_log", level: "info", message: `JS_TRACE: Entered synthesizeSpeech. Text: "${text}", Voice: "${voiceName}"` });
    if (!tts_pipeline_global) {
        sendToSwift({ type: "js_log", level: "error", message: "JS: TTS Pipeline not initialized for synthesis."});
        sendToSwift({ type: "ttsError", message: "TTS Pipeline not initialized. Please wait or check logs."});
        return null;
    }
    try {
        sendToSwift({ type: "js_log", level: "debug", message: `JS: Checking if voice "${voiceName}" is available. Available voices: ${JSON.stringify(js_available_voices_global)}` });
        if (!js_available_voices_global.includes(voiceName)) {
            sendToSwift({ type: "js_log", level: "error", message: `JS: Unsupported voice "${voiceName}".` });
            sendToSwift({ type: "ttsError", message: `Voice not supported: ${voiceName}` });
            return null;
        }

             sendToSwift({ type: "js_log", level: "debug", message: "JS_TRACE: Attempting tts_pipeline_global.generate" });
            let output;
            try {
                output = await tts_pipeline_global.generate(text, { voice: voiceName });
                sendToSwift({ type: "js_log", level: "debug", message: "JS_TRACE: tts_pipeline_global.generate() completed successfully." });
            } catch (generateError) {
                let geMsg = "JS_TRACE: ERROR during tts_pipeline_global.generate(): " + generateError.toString();
                let geName = generateError.name || "UnknownError";
                let geStack = generateError.stack || "No stack available";
                if (generateError.cause) { geMsg += " | Cause: " + String(generateError.cause); if (generateError.cause.stack) geStack += "\nCaused by Stack: " + generateError.cause.stack; }
                
                console.error("🚨 JS_TRACE: ERROR during tts_pipeline_global.generate():", generateError); // For Safari Web Inspector
                sendToSwift({ type: "js_log", level: "exception", message: geMsg, error_name: geName, stack: geStack });
                throw generateError; // Re-throw to be caught by the outer try-catch
            }
        
        sendToSwift({ type: "js_log", level: "debug", message: `JS_TRACE: Output from generate received. output is null/undefined? ${output == null}. Has audio? ${output && output.audio != null}` });
        
        if (!output || !output.audio || typeof output.sampling_rate !== 'number') {
            sendToSwift({ type: "js_log", level: "error", message: "JS_TRACE: Synthesis did not return expected audio format. Output: " + JSON.stringify(output) });
            sendToSwift({ type: "ttsError", message: "Synthesis returned invalid audio format."});
            return null;
        }
        sendToSwift({ type: "js_log", level: "info", message: `JS_TRACE: Synthesis generation complete. Rate: ${output.sampling_rate}, Samples: ${output.audio ? output.audio.length : 'N/A'}. Preparing WAV.` });
        
        const wavData = window.pcmToWavBase64(output.audio, output.sampling_rate);
        sendToSwift({ type: "js_log", level: "debug", message: "JS_TRACE: pcmToWavBase64 completed. wavData is null/empty? " + (wavData == null || wavData === "") });
        
        const audioMessagePayload = {
            type: "audioData",
            data: wavData,
            samplingRate: output.sampling_rate
        };
        sendToSwift({ type: "js_log", level: "debug", message: "JS_TRACE: About to send audioData message. Payload type: " + audioMessagePayload.type + ", Data first 10 chars: " + (wavData ? String(wavData).substring(0,10) : "null") });
        
        sendToSwift(audioMessagePayload); // This uses the corrected sendToSwift that routes all to ttsHandler

        sendToSwift({ type: "js_log", level: "debug", message: "JS_TRACE: audioData message has been passed to sendToSwift (via ttsHandler)." });
        return true;

    } catch (error) { // This is the outer catch block
        let errorMessage = "JS: EXCEPTION during synthesis processing: " + error.toString();
        sendToSwift({ type: "js_log", level: "exception", message: "JS_TRACE: EXCEPTION in synthesizeSpeech: " + errorMessage, error_name: error.name, stack: error.stack });
        console.error("❌ Caught error during synthesis:", error); // Keep for JS console
        sendToSwift({ type: "ttsError", message: "Synthesis processing failed: " + error.message });
        return false;
    }
};
sendToSwift({ type: "js_log", level: "info", message: "JS: window.synthesizeSpeech is defined." });

// STEP 9: Initial signal to Swift that this bundle has loaded and set up window functions.
// Swift's webView(_:didFinish:) can then call window.triggerTTSInitialization().
// Global unhandled promise rejection handler
window.addEventListener("unhandledrejection", function (event) {
    const reason = event.reason;
    const msg = (typeof reason === 'object' && reason !== null && 'message' in reason)
        ? reason.message
        : JSON.stringify(reason);
    const stack = (typeof reason === 'object' && reason !== null && 'stack' in reason)
        ? reason.stack
        : '(no stack)';
    sendToSwift({
        type: "js_log",
        level: "exception",
        message: `UNHANDLED PROMISE REJECTION: ${msg}`,
        stack: stack
    });
    console.error("🚨 UNHANDLED PROMISE REJECTION:", reason);
});

sendToSwift({ type: "status", message: "transformers_js_ready" });
sendToSwift({ type: "js_log", level: "info", message: "JS (Vite Bundle - main.js): All functions defined. Ready for Swift to call triggerTTSInitialization." });
