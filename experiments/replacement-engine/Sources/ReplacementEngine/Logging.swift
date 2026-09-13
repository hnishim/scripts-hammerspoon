import Foundation

final class StructuredLogger {
    private let path: String
    init(path: String) { self.path = NSString(string: path).expandingTildeInPath }

    func append(_ record: RunLog) throws {
        let url = URL(fileURLWithPath: path)
        let encoded = try JSONEncoder().encode(record)
        let line = encoded + Data([0x0A])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            let existing = try Data(contentsOf: url)
            try (existing + line).write(to: url, options: .atomic)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }
}
