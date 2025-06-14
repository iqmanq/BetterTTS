import Foundation
import AVFoundation

class AudioGenerator {
    init() {}

    /// Runs the Python script and converts its Int16 PCM output to a normalized, stereo Float32 WAV file.
    func generate(text: String, voice: String, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let generateAudioPath = Bundle.main.path(forResource: "generate_audio", ofType: nil, inDirectory: "with_quant") else {
                let error = NSError(domain: "AudioGenerator", code: 404, userInfo: [NSLocalizedDescriptionKey: "'generate_audio' executable not found."])
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let command = "'\(generateAudioPath)' '\(text)' '\(voice)' en-us"
            process.arguments = ["-c", command]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                
                let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
                    print("--- generate_audio Subprocess Log ---\n\(errorString)\n-------------------------------------")
                }
                
                if process.terminationStatus == 0 {
                    let int16PcmData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    if int16PcmData.isEmpty {
                        let error = NSError(domain: "AudioGenerator", code: 501, userInfo: [NSLocalizedDescriptionKey: "Process produced no audio data."])
                        DispatchQueue.main.async { completion(.failure(error)) }
                        return
                    }
                    
                    let float32StereoData = self.convertInt16MonoToFloat32Stereo(int16PcmData)
                    
                    let sampleRate: UInt32 = 24000
                    let bitDepth: UInt16 = 32
                    let channels: UInt16 = 2
                    let audioFormat: UInt16 = 3 // IEEE Float
                    
                    let wavHeader = self.createWavHeader(
                        audioData: float32StereoData,
                        sampleRate: sampleRate,
                        bitDepth: bitDepth,
                        channels: channels,
                        audioFormat: audioFormat
                    )
                    
                    let finalWavData = wavHeader + float32StereoData
                    
                    let tempDir = FileManager.default.temporaryDirectory
                    let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
                    
                    try finalWavData.write(to: outputURL)
                    
                    DispatchQueue.main.async {
                        completion(.success(outputURL))
                    }
                    
                } else {
                    let error = NSError(domain: "AudioGenerator", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Audio generation process failed with exit code \(process.terminationStatus)."])
                    DispatchQueue.main.async { completion(.failure(error)) }
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Converts raw 16-bit mono PCM data into 32-bit float stereo PCM data by normalizing.
    private func convertInt16MonoToFloat32Stereo(_ int16Data: Data) -> Data {
        let frameCount = int16Data.count / MemoryLayout<Int16>.size
        var float32Data = Data(capacity: frameCount * MemoryLayout<Float32>.size * 2)

        int16Data.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress!
            
            for i in 0..<frameCount {
                let intSample = int16Pointer[i]
                var floatSample = Float(intSample) / 32767.0
                
                withUnsafeBytes(of: &floatSample) { floatBytes in
                    float32Data.append(contentsOf: floatBytes) // Left Channel
                    float32Data.append(contentsOf: floatBytes) // Right Channel
                }
            }
        }
        return float32Data
    }

    private func createWavHeader(audioData: Data, sampleRate: UInt32, bitDepth: UInt16, channels: UInt16, audioFormat: UInt16) -> Data {
        var header = Data()
        let audioDataSize = UInt32(audioData.count)
        let chunkSize = 36 + audioDataSize
        
        header.append("RIFF".data(using: .ascii)!)
        header.append(Data(from: chunkSize))
        header.append("WAVE".data(using: .ascii)!)
        
        header.append("fmt ".data(using: .ascii)!)
        header.append(Data(from: UInt32(16)))
        header.append(Data(from: audioFormat))
        header.append(Data(from: channels))
        header.append(Data(from: sampleRate))
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitDepth) / 8
        header.append(Data(from: byteRate))
        let blockAlign = channels * bitDepth / 8
        header.append(Data(from: blockAlign))
        header.append(Data(from: bitDepth))
        
        header.append("data".data(using: .ascii)!)
        header.append(Data(from: audioDataSize))
        
        return header
    }
}

fileprivate extension Data {
    init<T>(from value: T) {
        var value = value
        self = withUnsafePointer(to: &value) {
            Data(buffer: UnsafeBufferPointer(start: $0, count: 1))
        }
    }
    
    mutating func append<T>(from value: T) {
        var value = value
        withUnsafePointer(to: &value) {
            self.append(UnsafeBufferPointer(start: $0, count: 1))
        }
    }
}
