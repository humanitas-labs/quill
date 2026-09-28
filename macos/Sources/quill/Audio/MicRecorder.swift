import AVFoundation
import CoreAudio
import Foundation

/// Records the default input device to a file via AVAudioEngine as 16-bit PCM
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and reports it so the session can rotate to a raw-capture segment.
///
/// One start/stop pair is one segment. The recorder observes route and engine
/// configuration changes while a segment runs and reports them as health
/// events (rca-006); the session owns the recovery decision. All graph
/// construction and teardown is serialized on a private control queue so the
/// main actor never blocks on Core Audio.
final class MicRecorder: TrackRecorder, @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case alreadyRecording
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .alreadyRecording: return "mic segment already active"
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    let kind = TrackKind.mic

    private let control = DispatchQueue(label: "com.digimata.quill.mic-control")
    private var engine: AVAudioEngine?
    private var segment: SegmentFile?
    private var configObserver: NSObjectProtocol?
    private var routeListener: AudioObjectPropertyListenerBlock?
    /// Set once voice processing has proven silent on this session's route;
    /// every later segment captures raw.
    private let preferRaw = AtomicFlag()
    private var lastStats: SegmentStats?

    /// Start a new segment. Throws if one is already active.
    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        try control.sync {
            guard engine == nil else { throw RecorderError.alreadyRecording }
            let voice = Config.micVoiceProcessing() && !preferRaw.value
            try attach(url: url, clock: clock, voiceProcessing: voice, onEvent: onEvent)
        }
    }

    /// Stop the active segment and return its stats. Bounded: if Core Audio
    /// teardown wedges, gives up after 5 s and reports stats from telemetry
    /// rather than hanging the caller.
    func stop() -> SegmentStats? {
        let done = DispatchSemaphore(value: 0)
        control.async {
            self.lastStats = self.teardownLocked()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data("mic teardown timed out\n".utf8))
            return nil
        }
        return lastStats
    }

    func telemetry() -> TelemetrySnapshot {
        segment?.telemetry.snapshot() ?? TelemetrySnapshot()
    }

    // MARK: -

    /// Build the engine graph, create the PCM file, start capture, and attach
    /// route observers. Runs on the control queue.
    private func attach(
        url: URL,
        clock: SessionClock,
        voiceProcessing: Bool,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                    ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            // CAF with fixed-size PCM packets remains readable after SIGKILL.
            // AAC needs a packet table finalized on clean close.
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        let segment = SegmentFile(
            file: file,
            fileName: url.lastPathComponent,
            sampleRateHz: Int(monoFormat.sampleRate),
            channels: 1,
            clock: clock
        )

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            installVoiceTap(on: input, format: monoFormat, segment: segment, onEvent: onEvent)
        } else {
            try installRawTap(
                on: input, inputFormat: inputFormat, monoFormat: monoFormat,
                segment: segment, onEvent: onEvent
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = segment.finish()
            throw RecorderError.engineStartFailed(error)
        }

        self.engine = engine
        self.segment = segment
        observeRoute(engine: engine, onEvent: onEvent)

        let report =
            "mic: segment=\(url.lastPathComponent) "
            + "voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Watch for the engine's graph being reconfigured by a route change and
    /// for the system default input moving. Both mark the track suspect; the
    /// watchdog decides whether callbacks actually stopped. An engine that is
    /// no longer running after a configuration change is reported immediately.
    private func observeRoute(engine: AVAudioEngine, onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            onEvent(.routeChanged)
            guard let self else { return }
            self.control.async {
                if let engine = self.engine, !engine.isRunning {
                    onEvent(.transportStopped)
                }
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onEvent(.routeChanged)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener
        )
        if status == noErr {
            routeListener = listener
        } else {
            FileHandle.standardError.write(
                Data(
                    "warning: default-input listener failed (OSStatus \(status))\n".utf8
                ))
        }
    }

    /// Idempotent, ordered teardown: stop engine, remove tap, detach
    /// observers, close file, release graph. Runs on the control queue.
    private func teardownLocked() -> SegmentStats? {
        guard let engine else { return nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let routeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, routeListener
            )
            self.routeListener = nil
        }
        let stats: SegmentStats?
        if let segment {
            _ = segment.finish()
            stats = segment.stats()
        } else {
            stats = nil
        }
        segment = nil
        self.engine = nil
        return stats
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is a raw-capture segment, which the session rotates
    /// to on the reported event.
    private func installVoiceTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        segment: SegmentFile,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) {
        let checkFrames = Int(format.sampleRate)
        let preferRaw = preferRaw
        // Liveness state is only touched from the serially invoked tap.
        final class Liveness: @unchecked Sendable {
            var frames = 0
            var peak: Float = 0
            var settled = false
        }
        let liveness = Liveness()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            if !liveness.settled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        liveness.peak = max(liveness.peak, abs(data[i]))
                    }
                }
                liveness.frames += frames
                if liveness.frames >= checkFrames {
                    liveness.settled = true
                    if liveness.peak == 0 {
                        preferRaw.set()
                        onEvent(.voiceProcessingSilent)
                        return
                    }
                }
            }
            let hostTime = when.isHostTimeValid ? when.hostTime : nil
            if let error = segment.write(buffer, hostTime: hostTime) {
                onEvent(.writeFailed(error))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        segment: SegmentFile,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, when in
            guard
                let mono = AVAudioPCMBuffer(
                    pcmFormat: monoFormat,
                    frameCapacity: buffer.frameCapacity
                )
            else { return }
            do {
                try converter.convert(to: mono, from: buffer)
            } catch {
                onEvent(.writeFailed("mic downmix failed: \(error)"))
                return
            }
            let hostTime = when.isHostTimeValid ? when.hostTime : nil
            if let error = segment.write(mono, hostTime: hostTime) {
                onEvent(.writeFailed(error))
            }
        }
    }
}
