import Foundation

/// Roda um executável com array de argumentos. Nunca shell, nunca `sh -c` (regra 6).
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ executable: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Lê antes de esperar, para a saída grande não travar o pipe.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }
}
