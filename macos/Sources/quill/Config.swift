import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        (try? transcription())?["enabled"] as? Bool ?? true
    }

    /// Read once when selecting a provider, so its engine and options agree.
    static func transcription() throws -> [String: Any]? {
        try transcription(from: path)
    }

    static func transcription(from url: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let readError = error as NSError
            if readError.domain == NSCocoaErrorDomain && readError.code == NSFileReadNoSuchFileError { return nil }
            throw TranscriptionCommandError("cannot read transcription config at \(url.path): \(error)")
        }

        let config: [String: Any]
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let object = json as? [String: Any] else {
                throw TranscriptionCommandError("config at \(url.path) must contain a JSON object")
            }
            config = object
        } catch let error as TranscriptionCommandError {
            throw error
        } catch {
            throw TranscriptionCommandError("invalid JSON in config at \(url.path): \(error)")
        }
        return try transcription(in: config)
    }

    static func transcription(in config: [String: Any]?) throws -> [String: Any]? {
        guard let config, let value = config["transcription"] else { return nil }
        guard let transcription = value as? [String: Any] else {
            throw TranscriptionCommandError("transcription settings must be an object")
        }
        return transcription
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(
                Data(
                    "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
                ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
