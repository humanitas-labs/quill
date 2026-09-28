import Foundation

/// Session folder naming shared by live recordings and imported audio:
/// `<root>/yyyy.MM.dd-HHmm`, suffixed `-2`, `-3`, … on collision so an
/// existing session is never reused.
enum SessionFolder {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create and return a fresh session folder for `date` under `root`.
    static func create(in root: URL, date: Date) throws -> URL {
        let base = format.string(from: date)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}
