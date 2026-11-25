import Foundation
import os

/// Log no unified log (`io.github.sjbruno.robusta`) e em `~/Library/Logs/Robusta/robusta.log`.
/// O arquivo gira em 1 MB (fica um `.1`), para não crescer sem limite.
public struct Log: Sendable {
    public let category: String
    public let fileURL: URL?
    private let logger: Logger

    public static let maxFileSize = 1_000_000

    public init(category: String, fileURL: URL? = Robusta.logFile) {
        self.category = category
        self.fileURL = fileURL
        self.logger = Logger(subsystem: Robusta.logSubsystem, category: category)
    }

    public func info(_ message: String) { write("INFO", message) { logger.info("\(message, privacy: .public)") } }
    public func error(_ message: String) { write("ERRO", message) { logger.error("\(message, privacy: .public)") } }

    private func write(_ level: String, _ message: String, unified: () -> Void) {
        unified()
        guard let fileURL else { return }
        let line = "\(Date().formatted(.iso8601)) [\(category)] \(level) \(message)\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > Self.maxFileSize {
            let rotated = fileURL.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: fileURL, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
    }
}
