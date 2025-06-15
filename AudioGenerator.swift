import Foundation
import AVFoundation

class AudioGenerator {
    init() {}

    /// Runs the Python script and converts its Int16 PCM output to interleaved stereo 16-bit PCM WAV file.
    func generate(text: String, voice: String, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let generateAudioPath = Bundle.main.path(forResource: "generate_audio", ofType: nil, inDirectory: "with_quant") else {
                let error = NSError(domain: "AudioGenerator", code: 404, userInfo: [NSLocalizedDescriptionKey: "'generate_audio' executable not found."])
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: generateAudioPath)
            process.arguments = [text, voice, "en-us"]
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var outputData = Data()
            var errorData = Data()

            outPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.count > 0 {
                    outputData.append(data)
                } else {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                }
            }

            errPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.count > 0 {
                    errorData.append(data)
                } else {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                }
            }

            do {
                print("🧪 Launching generate_audio with args: \(process.arguments ?? [])")
                try process.run()
                process.waitUntilExit()
                
                // After process exits, readabilityHandler has collected data
                if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
                    print("--- generate_audio Subprocess Log ---\n\(errorString)\n-------------------------------------")
                }
                
                if process.terminationStatus == 0 {
                    if outputData.isEmpty {
                        let error = NSError(domain: "AudioGenerator", code: 501, userInfo: [NSLocalizedDescriptionKey: "Process produced no audio data."])
                        DispatchQueue.main.async { completion(.failure(error)) }
                        return
                    }
                    
                    let trimmedOutputData: Data
                    let trimBytes = 2400 * MemoryLayout<Int16>.size
                    if outputData.count > trimBytes {
                        trimmedOutputData = outputData.prefix(outputData.count - trimBytes)
                    } else {
                        trimmedOutputData = outputData
                    }
                    let stereoData = self.convertInt16MonoToStereo(trimmedOutputData)
                    
                    let sampleRate: UInt32 = 24000
                    let bitDepth: UInt16 = 16
                    let channels: UInt16 = 2
                    let audioFormat: UInt16 = 1 // PCM
                    
                    let wavHeader = self.createWavHeader(
                        audioData: stereoData,
                        sampleRate: sampleRate,
                        bitDepth: bitDepth,
                        channels: channels,
                        audioFormat: audioFormat
                    )
                    
                    let finalWavData = wavHeader + stereoData
                    
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
    
    /// Converts raw 16-bit mono PCM data into interleaved 16-bit stereo PCM data.
    private func convertInt16MonoToStereo(_ int16Data: Data) -> Data {
        let frameCount = int16Data.count / MemoryLayout<Int16>.size
        var stereoData = Data(capacity: frameCount * MemoryLayout<Int16>.size * 2)

        int16Data.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self).baseAddress!

            for i in 0..<frameCount {
                let sample = int16Pointer[i]
                var left = sample
                var right = sample

                withUnsafeBytes(of: &left) { stereoData.append(contentsOf: $0) }
                withUnsafeBytes(of: &right) { stereoData.append(contentsOf: $0) }
            }
        }

        return stereoData
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
