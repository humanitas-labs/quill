import AVFoundation
import XCTest

@testable import quill

private struct InjectedRuntimeFailure: Error {}

private actor InjectedTranscriptionEngine: TranscriptionEngine {
    enum Failure: Sendable {
        case runtime(String)
        case unreadable(String)
    }

    nonisolated let name = "injected"
    nonisolated let model = "test-model"
    private let failure: Failure
    private var files = [String]()

    init(failure: Failure) {
        self.failure = failure
    }

    func prepare() async throws {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let file = audio.lastPathComponent
        files.append(file)
        switch failure {
        case .runtime(let failingFile) where file == failingFile:
            throw InjectedRuntimeFailure()
        case .unreadable(let failingFile) where file == failingFile:
            throw UnreadableTranscriptionInput(audio: audio, underlyingError: nil)
        default:
            return [TranscriptSegment(start: 0, end: 0.5, text: "recognized \(file)")]
        }
    }

    func release() async {}

    func transcribedFiles() -> [String] { files }
}

@MainActor
final class TranscriptionAdapterTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-adapter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func script(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("provider \(UUID().uuidString)")
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func adapter(executable: URL, extra: [String: Any] = [:]) throws -> any TranscriptionCommandAdapter {
        var command: [String: Any] = [
            "name": "test-provider", "model": "test model", "executable": executable.path,
            "arguments": ["{audio}", "{model}"], "chunk_seconds": 1,
        ]
        command.merge(extra) { _, value in value }
        let provider = try TranscriptionProvider(configuration: ["engine": "command", "command": command])
        guard case .command(let adapter) = provider else { throw XCTSkip("expected command provider") }
        return adapter
    }

    private func audio(duration: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 2, compressed: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("input with spaces.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        var settings: [String: Any] =
            compressed
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
            : format.settings
        if !compressed { settings[AVLinearPCMIsNonInterleaved] = false }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(duration * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames)))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            // Only the last channel has audio: mono conversion must downmix it.
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = channel == Int(channels) - 1 ? 0.25 : 0
            }
        }
        if frames > 0 { try file.write(from: buffer) }
        return url
    }

    func testDefaultAndUnknownProviderSelection() throws {
        XCTAssertTrue(try TranscriptionProvider(configuration: [:]).makeEngine() is ParakeetEngine)
        for configuration: [String: Any] in [
            ["engine": "typo"], ["engine": 1], ["engine": "command"], ["engine": "handy", "handy_model": ""],
        ] {
            XCTAssertThrowsError(try TranscriptionProvider(configuration: configuration))
        }
    }

    func testMalformedTranscriptionSectionIsNotTreatedAsMissing() throws {
        XCTAssertNil(try Config.transcription(in: [:]))
        XCTAssertEqual(try Config.transcription(in: ["transcription": ["enabled": false]])?["enabled"] as? Bool, false)
        XCTAssertThrowsError(try Config.transcription(in: ["transcription": "handy"]))
    }

    func testProviderConfigFileDistinguishesMissingFromInvalidAndReadFailures() throws {
        let missing = root.appendingPathComponent("absent.json")
        XCTAssertNil(try Config.transcription(from: missing))
        XCTAssertTrue(try TranscriptionProvider(configuration: Config.transcription(from: missing)).makeEngine() is ParakeetEngine)

        let malformed = root.appendingPathComponent("malformed.json")
        try Data("{\"transcription\":".utf8).write(to: malformed)
        XCTAssertThrowsError(try Config.transcription(from: malformed))
        XCTAssertThrowsError(try TranscriptionProvider(configuration: Config.transcription(from: malformed)))

        let nonObject = root.appendingPathComponent("array.json")
        try Data("[]".utf8).write(to: nonObject)
        XCTAssertThrowsError(try Config.transcription(from: nonObject))

        let directory = root.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try Config.transcription(from: directory))

        let handy = root.appendingPathComponent("handy.json")
        try JSONSerialization.data(withJSONObject: ["transcription": ["engine": "handy", "handy_model": "installed"]])
            .write(to: handy)
        let configuration = try XCTUnwrap(Config.transcription(from: handy))
        XCTAssertEqual(configuration["engine"] as? String, "handy")
        XCTAssertEqual(configuration["handy_model"] as? String, "installed")
    }

    func testInvalidCommandConfigurationFailsBeforeTranscribing() throws {
        let executable = try script("exit 0")
        for extra: [String: Any] in [
            ["executable": "relative/path"], ["arguments": ["--no-audio"]], ["model": ""],
            ["timeout_seconds": 0], ["chunk_seconds": 301], ["arguments": "{audio}"],
        ] {
            XCTAssertThrowsError(try adapter(executable: executable, extra: extra))
        }
        let missing = try adapter(executable: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try missing.prepare())
    }

    func testArgumentsStayLiteralWithoutShellExpansionOrRecursiveSubstitution() throws {
        let executable = try script("printf '%s\\n' \"$1\" \"$2\" \"$3\"")
        let model = "model {audio} $(touch unwanted) 'quoted'"
        let adapter = try adapter(
            executable: executable,
            extra: [
                "model": model, "arguments": ["--input={audio}", "{model}", "literal;echo nope"],
            ])
        let source = root.appendingPathComponent("audio {model} with spaces.wav")
        let output = try CommandProcess.run(executable: executable, arguments: adapter.arguments(for: source), timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "--input=\(source.path)\n\(model)\nliteral;echo nope\n")
    }

    func testNULInLiteralArgumentOrExpandedModelIsRejectedBeforeSpawn() throws {
        let source = root.appendingPathComponent("input.wav")
        for (suffix, model, arguments): (String, String, [String]) in [
            ("literal", "ordinary model", ["{audio}", "literal\0tail"]),
            ("model", "model\0tail", ["{audio}", "{model}"]),
        ] {
            let marker = root.appendingPathComponent("\(suffix)-launched")
            let executable = try script("touch '\(marker.path)'; echo '{\"text\":\"launched\"}'")
            let adapter = try adapter(
                executable: executable,
                extra: ["model": model, "arguments": arguments]
            )
            XCTAssertThrowsError(
                try CommandProcess.run(executable: executable, arguments: adapter.arguments(for: source), timeout: 5)
            ) { error in
                XCTAssertTrue(String(describing: error).contains("NUL"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testLargeStdoutAndStderrCannotFillAPipeAndDeadlock() throws {
        let executable = try script(
            """
            /usr/bin/awk 'BEGIN { printf "{\\"text\\":\\""; for(i=0;i<200000;i++) printf "a"; print "\\"}" }' &
            /usr/bin/awk 'BEGIN { for(i=0;i<200000;i++) printf "e" }' >&2 &
            wait
            """)
        let adapter = try adapter(executable: executable)
        let output = try CommandProcess.run(executable: executable, arguments: [], timeout: 5)
        XCTAssertEqual(try adapter.decode(output, duration: 1).first?.text.count, 200_000)
    }

    func testFailureIncludesStderrAndTimeoutKillsUnresponsiveProcess() throws {
        let failing = try script("echo 'model unavailable' >&2; exit 7")
        XCTAssertThrowsError(try CommandProcess.run(executable: failing, arguments: [], timeout: 5)) { error in
            XCTAssertTrue(String(describing: error).contains("status 7"))
            XCTAssertTrue(String(describing: error).contains("model unavailable"))
        }
        let hanging = try script("trap '' TERM; while :; do :; done")
        let start = Date()
        XCTAssertThrowsError(try CommandProcess.run(executable: hanging, arguments: [], timeout: 0.1)) { error in
            XCTAssertTrue(String(describing: error).contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testStdoutAndStderrLimitsStopCommandAndDescendants() throws {
        for stream in ["stdout", "stderr"] {
            let wrapperPIDFile = root.appendingPathComponent("\(stream)-wrapper.pid")
            let childPIDFile = root.appendingPathComponent("\(stream)-child.pid")
            let redirection = stream == "stderr" ? " >&2" : ""
            let producer = try script(
                "echo $$ > '\(wrapperPIDFile.path)'\n" + "/bin/sh -c 'trap \"\" TERM; while :; do :; done' &\n" + "echo $! > '\(childPIDFile.path)'\n"
                    + "exec /usr/bin/head -c 67108864 /dev/zero\(redirection)"
            )
            let start = Date()
            XCTAssertThrowsError(try CommandProcess.run(executable: producer, arguments: [], timeout: 30)) { error in
                XCTAssertTrue(String(describing: error).contains("\(stream) exceeds"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
            let wrapperPID = try XCTUnwrap(Int32(String(contentsOf: wrapperPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertFalse(processIsRunning(wrapperPID))
            XCTAssertFalse(processIsRunning(childPID))
        }
    }

    func testTimeoutKillsWrapperAndChildProcess() throws {
        let childPIDFile = root.appendingPathComponent("child.pid")
        let wrapperPIDFile = root.appendingPathComponent("wrapper.pid")
        let hanging = try script(
            "echo $$ > '\(wrapperPIDFile.path)'\n" + "/bin/sh -c 'trap \"\" TERM; while :; do :; done' &\n" + "echo $! > '\(childPIDFile.path)'\n"
                + "trap '' TERM\nwhile :; do :; done"
        )
        XCTAssertThrowsError(try CommandProcess.run(executable: hanging, arguments: [], timeout: 1))
        let wrapperPID = try XCTUnwrap(Int32(String(contentsOf: wrapperPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(processIsRunning(wrapperPID))
        XCTAssertFalse(processIsRunning(childPID))
    }

    func testDeadlineCoversChildHoldingPipesAfterWrapperExit() throws {
        let wrapperPIDFile = root.appendingPathComponent("exit-wrapper.pid")
        let childPIDFile = root.appendingPathComponent("pipe-child.pid")
        let wrapper = try script(
            "echo $$ > '\(wrapperPIDFile.path)'\n" + "/bin/sh -c 'trap \"\" TERM; while :; do :; done' &\n" + "echo $! > '\(childPIDFile.path)'\nexit 0"
        )
        let start = Date()
        // Allow the fixture to start on a busy host before testing the inherited-pipe deadline.
        XCTAssertThrowsError(try CommandProcess.run(executable: wrapper, arguments: [], timeout: 2)) { error in
            XCTAssertTrue(String(describing: error).contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let wrapperPID = try XCTUnwrap(Int32(String(contentsOf: wrapperPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(processIsRunning(wrapperPID))
        XCTAssertFalse(processIsRunning(childPID))
    }

    func testSuccessfulAndFailingWrappersCleanUpRedirectedChildren() throws {
        for exitStatus in [0, 7] {
            let childPIDFile = root.appendingPathComponent("redirected-child-\(exitStatus).pid")
            let wrapper = try script(
                "/bin/sh -c 'trap \"\" TERM; while :; do :; done' </dev/null >/dev/null 2>&1 &\n"
                    + "echo $! > '\(childPIDFile.path)'\n"
                    + "printf '{\"text\":\"preserved\"}'\n"
                    + "exit \(exitStatus)"
            )
            if exitStatus == 0 {
                XCTAssertEqual(
                    try CommandProcess.run(executable: wrapper, arguments: [], timeout: 5),
                    Data(#"{"text":"preserved"}"#.utf8)
                )
            } else {
                XCTAssertThrowsError(try CommandProcess.run(executable: wrapper, arguments: [], timeout: 5)) { error in
                    XCTAssertTrue(String(describing: error).contains("status 7"))
                }
            }
            let childPID = try XCTUnwrap(
                Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            )
            XCTAssertFalse(processIsRunning(childPID))
        }
    }

    func testSegmentJustPastChunkBoundaryRemainsOrderedAndBounded() throws {
        let adapter = try adapter(executable: script("exit 0"))
        let decoded = try adapter.decode(
            Data(#"{"segments":[{"start":1.04,"end":1.05,"text":"edge"}]}"#.utf8), duration: 1
        )
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].start, 1)
        XCTAssertEqual(decoded[0].end, 1)
        XCTAssertLessThanOrEqual(decoded[0].start, decoded[0].end)
    }

    private func processIsRunning(_ processID: Int32) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(processID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let state = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !state.isEmpty && !state.hasPrefix("Z")
        } catch {
            return false
        }
    }

    func testJSONContractValidatesTimingsAndSupportsSilence() throws {
        let adapter = try adapter(executable: script("exit 0"))
        let decoded = try adapter.decode(Data(#"{"segments":[{"start":0.5,"end":0.9,"text":" hi "}]}"#.utf8), duration: 1)
        XCTAssertEqual(decoded.first?.start, 0.5)
        XCTAssertEqual(decoded.first?.end, 0.9)
        XCTAssertEqual(decoded.first?.text, "hi")
        for json in [#"{"text":" "}"#, #"{"segments":[]}"#] {
            XCTAssertTrue(try adapter.decode(Data(json.utf8), duration: 1).isEmpty)
        }
        let text = try adapter.decode(Data(#"{"text":" hi ","audio_secs":9999}"#.utf8), duration: 0.75)
        XCTAssertEqual(text.first?.end, 0.75)  // Actual WAV duration is authoritative.
        for json in [
            "not json", "{}", #"{"text":42}"#,
            #"{"segments":[{"start":-1,"end":0.5,"text":"bad"}]}"#,
            #"{"segments":[{"start":0.7,"end":0.5,"text":"bad"}]}"#,
            #"{"segments":[{"start":0,"end":5,"text":"bad"}]}"#,
        ] {
            XCTAssertThrowsError(try adapter.decode(Data(json.utf8), duration: 1), json)
        }
    }

    func testResamplingDownmixAndFinalChunkPreserveFrames() throws {
        let source = try audio(duration: 2.25)
        try CommandProcess.withTemporaryDirectory { directory in
            let chunks = try CommandAudio.chunks(from: source, in: directory, maxDuration: 1)
            XCTAssertEqual(chunks.count, 3)
            XCTAssertEqual(chunks.map(\.start), [0, 1, 2])
            XCTAssertEqual(chunks.last!.duration, 0.25, accuracy: 0.001)
            var frameCount: Int64 = 0
            for chunk in chunks {
                let file = try AVAudioFile(forReading: chunk.url)
                XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
                XCTAssertEqual(file.fileFormat.channelCount, 1)
                XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
                try file.read(into: buffer)
                XCTAssertGreaterThan(abs(buffer.floatChannelData![0][100]), 0.01)
                frameCount += file.length
            }
            XCTAssertEqual(frameCount, 36_000)
        }
    }

    func testExactBoundaryAndUnreadableAudio() throws {
        let source = try audio(duration: 2, rate: 16_000, channels: 1)
        try CommandProcess.withTemporaryDirectory { directory in
            let chunks = try CommandAudio.chunks(from: source, in: directory, maxDuration: 1)
            XCTAssertEqual(chunks.count, 2)
            XCTAssertEqual(chunks.map(\.duration), [1, 1])
            XCTAssertThrowsError(try CommandAudio.chunks(from: root.appendingPathComponent("missing"), in: directory, maxDuration: 1)) {
                XCTAssertFalse($0 is UnreadableTranscriptionInput)
            }
        }
        let empty = try audio(duration: 0)
        try CommandProcess.withTemporaryDirectory { directory in
            XCTAssertThrowsError(try CommandAudio.chunks(from: empty, in: directory, maxDuration: 1)) {
                XCTAssertTrue($0 is UnreadableTranscriptionInput)
            }
        }
    }

    func testMalformedAudioIsSkippableButInfrastructureOpenErrorsAreFatal() throws {
        let malformed = root.appendingPathComponent("malformed.caf")
        try Data("not an audio file".utf8).write(to: malformed)
        try CommandProcess.withTemporaryDirectory { directory in
            XCTAssertThrowsError(try CommandAudio.chunks(from: malformed, in: directory, maxDuration: 1)) {
                let error = $0 as NSError
                XCTAssertTrue($0 is UnreadableTranscriptionInput, "domain=\(error.domain) code=\(error.code) error=\(error)")
            }
        }

        let permissionError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFilePermissionsError))
        let classifiedPermissionError = UnreadableTranscriptionInput.classify(permissionError, audio: malformed)
        XCTAssertFalse(classifiedPermissionError is UnreadableTranscriptionInput)
        XCTAssertEqual((classifiedPermissionError as NSError).domain, NSOSStatusErrorDomain)

        let resourceError = NSError(domain: AVFoundationErrorDomain, code: AVError.outOfMemory.rawValue)
        XCTAssertFalse(UnreadableTranscriptionInput.classify(resourceError, audio: malformed) is UnreadableTranscriptionInput)

        let decodeError = NSError(domain: AVFoundationErrorDomain, code: AVError.decodeFailed.rawValue)
        XCTAssertTrue(UnreadableTranscriptionInput.classify(decodeError, audio: malformed) is UnreadableTranscriptionInput)
    }

    func testChunkFileCreationFailureIsNotClassifiedAsBadInputAudio() throws {
        let source = try audio(duration: 0.5)
        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockedDirectory)
        XCTAssertThrowsError(
            try CommandAudio.chunks(from: source, in: blockedDirectory, maxDuration: 1)
        ) { error in
            XCTAssertFalse(error is UnreadableTranscriptionInput)
        }
    }

    func testRecordedAACConvertsToPCMChunks() throws {
        let source = try audio(duration: 2.25, compressed: true)
        try CommandProcess.withTemporaryDirectory { directory in
            let chunks = try CommandAudio.chunks(from: source, in: directory, maxDuration: 1)
            XCTAssertEqual(chunks.count, 3)
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.duration }, 2.25, accuracy: 0.03)
            XCTAssertEqual(chunks.map(\.start), [0, 1, 2])
        }
    }

    func testCommandEngineOffsetsAndCleansUpTemporaryAudio() async throws {
        let log = root.appendingPathComponent("paths")
        let executable = try script(
            """
            test -f "$1"
            printf '%s\\n' "$1" >> '\(log.path)'
            case "$1" in
                *chunk-1.wav) echo '{"segments":[]}' ;;
                *) echo '{"segments":[{"start":0.1,"end":0.2,"text":"hello"}]}' ;;
            esac
            """)
        let engine = CommandEngine(adapter: try adapter(executable: executable))
        try await engine.prepare()
        let segments = try await engine.transcribe(audio(duration: 2.25))
        XCTAssertEqual(segments.map(\.start), [0.1, 2.1])  // Silence never collapses the clock.
        XCTAssertEqual(segments.map(\.end), [0.2, 2.2])
        let paths = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(paths.count, 3)
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: String(path))) }
        await engine.release()
    }

    func testCommandEngineFailureCleansUpAndThrowsProviderError() async throws {
        let log = root.appendingPathComponent("path")
        let executable = try script("printf '%s' \"$1\" > '\(log.path)'; echo 'broken model' >&2; exit 4")
        let engine = CommandEngine(adapter: try adapter(executable: executable))
        try await engine.prepare()
        do {
            _ = try await engine.transcribe(audio(duration: 0.5))
            XCTFail("expected failure")
        } catch is TranscriptionCommandError {
            let path = try String(contentsOf: log, encoding: .utf8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        }
    }

    func testOpaqueEngineRuntimeFailureLeavesSessionPendingAfterEarlierSuccess() async throws {
        let files = ["mic": "mic.caf", "system": "system.caf"]
        for file in files.values { try Data("audio".utf8).write(to: root.appendingPathComponent(file)) }
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: root.appendingPathComponent("meta.json"))
        let engine = InjectedTranscriptionEngine(failure: .runtime("system.caf"))
        let coordinator = TranscriptionCoordinator(engineFactory: { engine })

        do {
            try await coordinator.transcribe(root)
            XCTFail("expected opaque engine failure")
        } catch is InjectedRuntimeFailure {
        }

        let transcribedFiles = await engine.transcribedFiles()
        XCTAssertEqual(transcribedFiles, ["mic.caf", "system.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))
    }

    func testUnreadableEngineInputIsSkippedAndLaterInputCompletes() async throws {
        let files = ["mic": "mic.caf", "system": "system.caf"]
        for file in files.values { try Data("audio".utf8).write(to: root.appendingPathComponent(file)) }
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: root.appendingPathComponent("meta.json"))
        let engine = InjectedTranscriptionEngine(failure: .unreadable("mic.caf"))
        let coordinator = TranscriptionCoordinator(engineFactory: { engine })

        try await coordinator.transcribe(root)

        let transcribedFiles = await engine.transcribedFiles()
        XCTAssertEqual(transcribedFiles, ["mic.caf", "system.caf"])
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: root.appendingPathComponent("transcript.json"))
        )
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them"])
        XCTAssertEqual(transcript.segments.map(\.text), ["recognized system.caf"])
    }

    func testMissingReferencedAudioLeavesSessionPendingAndRetryCompletes() async throws {
        let missingAudio = root.appendingPathComponent("mic.caf")
        let laterAudio = root.appendingPathComponent("system.caf")
        try Data("audio".utf8).write(to: laterAudio)
        let files = ["mic": missingAudio.lastPathComponent, "system": laterAudio.lastPathComponent]
        try JSONSerialization.data(withJSONObject: ["files": files]).write(to: root.appendingPathComponent("meta.json"))
        let engine = InjectedTranscriptionEngine(failure: .runtime("never"))
        let coordinator = TranscriptionCoordinator(engineFactory: { engine })

        do {
            try await coordinator.transcribe(root)
            XCTFail("expected missing referenced audio to fail")
        } catch let error as TranscriptionCommandError {
            XCTAssertTrue(error.description.contains(missingAudio.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))

        try Data("restored audio".utf8).write(to: missingAudio)
        try await coordinator.transcribe(root)

        let transcribedFiles = await engine.transcribedFiles()
        XCTAssertEqual(transcribedFiles, ["mic.caf", "system.caf"])
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: root.appendingPathComponent("transcript.json"))
        )
        XCTAssertEqual(transcript.segments.map(\.text), ["recognized mic.caf", "recognized system.caf"])
    }

    func testProviderFailureLeavesSessionPendingAndRetryPreservesProvenance() async throws {
        let source = try audio(duration: 0.5)
        let metadata: [String: Any] = ["files": ["mic": source.lastPathComponent], "start_offset_ms": ["mic": 250]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("meta.json"))
        let executable = try script("echo 'model failed' >&2; exit 1")
        let engine = CommandEngine(adapter: try adapter(executable: executable))
        let coordinator = TranscriptionCoordinator(engineFactory: { engine })
        do {
            try await coordinator.transcribe(root)
            XCTFail("expected provider failure")
        } catch is TranscriptionCommandError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))
        }

        try Data("#!/bin/sh\necho '{\"text\":\"recovered\"}'\n".utf8).write(to: executable)
        try await coordinator.transcribe(root)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: root.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.engine, "test-provider")
        XCTAssertEqual(transcript.model, "test model")
        XCTAssertEqual(transcript.segments.first?.start_ms, 250)
        XCTAssertEqual(transcript.segments.first?.end_ms, 750)
        XCTAssertEqual(transcript.segments.first?.speaker, "me")
    }

    /// Opt-in smoke test; never downloads a model or reads personal recordings.
    /// Supply a synthetic speech fixture with QUILL_HANDY_TEST_AUDIO.
    func testInstalledHandyWithSyntheticSpeech() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_HANDY_TEST_AUDIO"] else {
            throw XCTSkip("set QUILL_HANDY_TEST_AUDIO to opt in to the installed Handy smoke test")
        }
        let engine = try TranscriptionProvider(configuration: ["engine": "handy"]).makeEngine()
        let readiness = try TranscriptionProvider(configuration: ["engine": "handy"]).checkReadiness()
        guard case .ok = readiness.status else { return XCTFail("installed Handy should pass provider readiness") }
        try await engine.prepare()
        let segments = try await engine.transcribe(URL(fileURLWithPath: path))
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.map(\.text).joined(separator: " ").lowercased().contains("meeting"))
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertGreaterThan(segments.last?.end ?? 0, 1)
        await engine.release()
    }

    /// Drives the user-configured adapter contract against an installed local
    /// provider, rather than only a test command. Handy is used here because
    /// its headless CLI implements the documented JSON response contract.
    func testConfiguredCommandAdapterWithInstalledHandy() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_HANDY_TEST_AUDIO"] else {
            throw XCTSkip("set QUILL_HANDY_TEST_AUDIO to opt in to the installed Handy smoke test")
        }
        let model = HandyAdapter.defaultModel
        let provider = try TranscriptionProvider(configuration: [
            "engine": "command",
            "command": [
                "name": "handy-command",
                "model": model,
                "executable": "/Applications/Handy.app/Contents/MacOS/handy",
                "arguments": ["--transcribe-file", "{audio}", "--model", "{model}", "--json"],
            ],
        ])
        guard case .command(let adapter) = provider else { return XCTFail("expected configured command provider") }
        let engine = CommandEngine(adapter: adapter)
        try await engine.prepare()
        let segments = try await engine.transcribe(URL(fileURLWithPath: path))
        XCTAssertTrue(segments.map(\.text).joined(separator: " ").lowercased().contains("meeting"))
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertGreaterThan(segments.last?.end ?? 0, 1)
        await engine.release()
    }

    func testHandyChecksCLIAndInstalledModel() throws {
        let executable = try script(
            """
            case "$1" in
                --help) echo '--transcribe-file --list-models --json' ;;
                --list-models) echo '[{"id":"installed","is_downloaded":true},{"id":"missing","is_downloaded":false}]' ;;
                *) exit 2 ;;
            esac
            """)
        try HandyAdapter(model: "installed", executablePath: executable.path).prepare()
        for model in ["missing", "unknown"] {
            XCTAssertThrowsError(try HandyAdapter(model: model, executablePath: executable.path).prepare())
        }
        let old = try script("echo 'Handy --toggle-transcription'")
        XCTAssertThrowsError(try HandyAdapter(executablePath: old.path).prepare()) { error in
            XCTAssertTrue(String(describing: error).contains("headless JSON CLI"))
        }
        let provider = try TranscriptionProvider(configuration: ["engine": "handy", "handy_executable": executable.path, "handy_model": "missing"])
        guard case .fail = provider.checkReadiness().status else { return XCTFail("doctor must fail for a missing model") }
    }
}
