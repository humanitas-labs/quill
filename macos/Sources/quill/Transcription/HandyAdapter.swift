import Foundation

/// Reuses an installed Handy runtime and its local models, with no additional
/// inference dependency or automatic downloads.
struct HandyAdapter: TranscriptionCommandAdapter {
    static let defaultModel = "handy-computer/parakeet-unified-en-0.6b-gguf/parakeet-unified-en-0.6b-Q8_0.gguf"
    let name = "handy"
    let model: String
    let executable: URL
    let timeout: TimeInterval = 600
    let chunkDuration: TimeInterval = 300

    init(model: String = Self.defaultModel, executablePath: String? = nil) throws {
        self.model = model
        if let executablePath {
            executable = try CommandProcess.executable(at: executablePath)
        } else {
            let candidates = [
                "/Applications/Handy.app/Contents/MacOS/handy",
                "/Applications/Handy.app/Contents/MacOS/Handy",
                "~/Applications/Handy.app/Contents/MacOS/handy",
                "~/Applications/Handy.app/Contents/MacOS/Handy",
                "/opt/homebrew/bin/handy",
                "/usr/local/bin/handy",
            ]
            guard
                let found = candidates.compactMap({ try? CommandProcess.executable(at: $0) })
                    .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            else {
                throw TranscriptionCommandError("Handy executable not found; install Handy or set transcription.handy_executable")
            }
            executable = found
        }
    }

    func prepare() throws {
        let help = try CommandProcess.run(executable: executable, arguments: ["--help"], timeout: 30)
        let usage = String(decoding: help, as: UTF8.self)
        guard ["--transcribe-file", "--list-models", "--json"].allSatisfy(usage.contains) else {
            throw TranscriptionCommandError("this Handy build lacks the headless JSON CLI; install a build with --transcribe-file and --list-models")
        }
        let output = try CommandProcess.run(executable: executable, arguments: ["--list-models", "--json"], timeout: 30)
        struct Model: Decodable {
            let id: String
            let is_downloaded: Bool
        }
        let models: [Model]
        do {
            models = try JSONDecoder().decode([Model].self, from: output)
        } catch {
            throw TranscriptionCommandError("Handy --list-models returned invalid JSON: \(error)")
        }
        guard let selected = models.first(where: { $0.id == model }) else {
            throw TranscriptionCommandError("Handy model \"\(model)\" is unknown; select an id from handy --list-models")
        }
        guard selected.is_downloaded else {
            throw TranscriptionCommandError("Handy model \"\(model)\" is not downloaded; download it in Handy first")
        }
    }

    func arguments(for audio: URL) -> [String] {
        ["--transcribe-file", audio.path, "--model", model, "--json"]
    }
}
