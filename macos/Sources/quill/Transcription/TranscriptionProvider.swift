import FluidAudio
import Foundation

/// The selection facade shared by the coordinator and doctor. Native engines
/// implement TranscriptionEngine; command adapters share one process/audio host.
enum TranscriptionProvider {
    case parakeet
    case command(any TranscriptionCommandAdapter)

    init(configuration: [String: Any]? = nil) throws {
        let configuration = try configuration ?? Config.transcription() ?? [:]
        let engine = configuration["engine"] ?? "parakeet"
        switch engine as? String {
        case "parakeet":
            self = .parakeet
        case "handy":
            let model = try Self.string(configuration, key: "handy_model") ?? HandyAdapter.defaultModel
            let path = try Self.string(configuration, key: "handy_executable")
            self = .command(try HandyAdapter(model: model, executablePath: path))
        case "command":
            guard let command = configuration["command"] as? [String: Any] else {
                throw TranscriptionCommandError("transcription.command must configure an executable, arguments, and model")
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: command)
                self = .command(try JSONDecoder().decode(ConfiguredCommandAdapter.self, from: data).validated())
            } catch let error as TranscriptionCommandError {
                throw error
            } catch {
                throw TranscriptionCommandError("invalid transcription.command configuration: \(error)")
            }
        default:
            throw TranscriptionCommandError("unknown transcription engine \"\(engine)\"; choose parakeet, handy, or command")
        }
    }

    func makeEngine() -> any TranscriptionEngine {
        switch self {
        case .parakeet: return ParakeetEngine()
        case .command(let adapter): return CommandEngine(adapter: adapter)
        }
    }

    func checkReadiness() -> Check {
        switch self {
        case .parakeet:
            let cache = AsrModels.defaultCacheDirectory(for: .v2)
            if AsrModels.modelsExist(at: cache, version: .v2) {
                return Check(name: "transcription", status: .ok, remediation: nil)
            }
            return Check(
                name: "transcription",
                status: .warn("parakeet models not downloaded (~600 MB)"),
                remediation: "downloads automatically on first transcription — record a short test session while online"
            )
        case .command(let adapter):
            do {
                try adapter.prepare()
                return Check(
                    name: "transcription", status: .ok,
                    remediation: adapter is ConfiguredCommandAdapter
                        ? "command executable found; record a short test session to verify its model and JSON output" : nil
                )
            } catch {
                return Check(name: "transcription", status: .fail(String(describing: error)), remediation: nil)
            }
        }
    }

    private static func string(_ configuration: [String: Any], key: String) throws -> String? {
        guard let value = configuration[key] else { return nil }
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionCommandError("transcription.\(key) must be a nonempty string")
        }
        return string
    }
}

/// Configuration, runtime and protocol failures must leave the session pending.
/// Unreadable individual audio files remain skippable by the coordinator.
struct TranscriptionCommandError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
