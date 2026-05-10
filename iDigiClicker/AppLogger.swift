import Foundation
import Combine

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: Level
    let message: String

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR", action = "ACT" }

    var formatted: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "[\(f.string(from: date))] [\(level.rawValue)] \(message)"
    }
}

@MainActor
final class AppLogger: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 2000
    private let fileURL: URL?

    init() {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("iDigiClicker", isDirectory: true)
        if let base {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            self.fileURL = base.appendingPathComponent("session-\(stamp).log")
        } else {
            self.fileURL = nil
        }
        log(.info, "Logger started. File: \(fileURL?.path ?? "—")")
    }

    func log(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        appendToFile(entry)
    }

    func clear() {
        entries.removeAll()
    }

    private func appendToFile(_ entry: LogEntry) {
        guard let fileURL else { return }
        let line = entry.formatted + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}
