import Cocoa

class MainViewController: NSViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Example usage
        let exampleText = "hello world"
        if let ids = runTokenizer(for: exampleText) {
            print("✅ Token IDs:", ids)
        } else {
            print("❌ Failed to tokenize")
        }
    }
    
    func runTokenizer(for text: String) -> [Int]? {
        guard let tokenizerURL = Bundle.main.url(forResource: "kokoro_tokenizer", withExtension: nil) else {
            print("❌ Tokenizer binary not found in bundle.")
            return nil
        }
        
        let process = Process()
        process.executableURL = tokenizerURL
        process.currentDirectoryURL = tokenizerURL.deletingLastPathComponent()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        
        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(text.data(using: .utf8)!)
            stdinPipe.fileHandleForWriting.closeFile()
            
            process.waitUntilExit()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            
            guard let outString = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !outString.isEmpty else {
                print("❌ Tokenizer output is not valid UTF-8 or is empty.")
                return nil
            }
            
            let jsonData = outString.data(using: .utf8)!
            let tokenIDs = try JSONDecoder().decode([Int].self, from: jsonData)
            return tokenIDs
            
        } catch {
            print("❌ Tokenization error: \(error)")
            return nil
        }
    }
}
