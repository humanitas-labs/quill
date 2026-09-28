import AVFoundation
import CoreAudio
import Foundation

/// Records all system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes every
/// process's output to stereo and hands us buffers through a private aggregate
/// device. First use triggers the one-time "System Audio Recording" TCC prompt
/// and lights the purple recording indicator while active.
///
/// One start/stop pair is one segment and one complete process-tap/
/// aggregate-device/IO-proc lifecycle; recovery destroys the old resources and
/// constructs fresh ones for the next numbered file. Default-output and
/// device-list changes are reported as suspect events; exact-zero buffers keep
/// the transport heartbeat healthy (legitimate silence is possible) and only
/// feed the silence diagnostic.
final class SystemAudioRecorder: TrackRecorder, @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case alreadyRecording
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .alreadyRecording: return "system segment already active"
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    let kind = TrackKind.system

    private let control = DispatchQueue(label: "com.digimata.quill.system-control")
    private let ioQueue = DispatchQueue(label: "com.digimata.quill.system-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var segment: SegmentFile?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var lastStats: SegmentStats?

    private static let routeProperties: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    ]

    /// Start a new segment: create the tap, aggregate device, file, and IO
    /// proc, then attach route observers. Throws if a segment is active.
    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        try control.sync {
            guard tapID == kAudioObjectUnknown else { throw RecorderError.alreadyRecording }

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "quill system tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(description, &newTapID)
            guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
            tapID = newTapID

            // Any failure past this point releases exactly the resources this
            // attempt created, so a failed recovery never leaks a tap.
            do {
                let format = try tapStreamFormat()
                try createAggregateDevice(tapUUID: description.uuid)
                let file = try makeFile(url: url, format: format)
                segment = SegmentFile(
                    file: file,
                    fileName: url.lastPathComponent,
                    sampleRateHz: Int(format.sampleRate),
                    channels: Int(format.channelCount),
                    clock: clock
                )
                try installIOProc(format: format, onEvent: onEvent)
            } catch {
                cleanupLocked()
                throw error
            }

            observeRoute(onEvent: onEvent)
            FileHandle.standardError.write(
                Data(
                    "system: segment=\(url.lastPathComponent)\n".utf8
                ))
        }
    }

    /// Stop the active segment and return its stats. Bounded: if Core Audio
    /// teardown wedges, gives up after 5 s rather than hanging the caller.
    func stop() -> SegmentStats? {
        let done = DispatchSemaphore(value: 0)
        control.async {
            self.lastStats = self.teardownLocked()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data("system teardown timed out\n".utf8))
            return nil
        }
        return lastStats
    }

    func telemetry() -> TelemetrySnapshot {
        segment?.telemetry.snapshot() ?? TelemetrySnapshot()
    }

    // MARK: -

    /// Watch the system default output and the device list. Either changing
    /// marks the track suspect; the property-listener callback never touches
    /// the tap directly — the session decides on its own queue.
    private func observeRoute(onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onEvent(.routeChanged)
        }
        for selector in Self.routeProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, listener
            )
            if status != noErr {
                FileHandle.standardError.write(
                    Data(
                        "warning: system route listener failed (OSStatus \(status))\n".utf8
                    ))
            }
        }
        routeListener = listener
    }

    private func removeRouteListener() {
        guard let routeListener else { return }
        for selector in Self.routeProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, routeListener
            )
        }
        self.routeListener = nil
    }

    /// Ordered teardown on the control queue: stop the device, remove
    /// observers, destroy the IO proc/aggregate/tap, close the file.
    private func teardownLocked() -> SegmentStats? {
        guard tapID != kAudioObjectUnknown || segment != nil else { return nil }
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        removeRouteListener()
        let stats: SegmentStats?
        if let segment {
            _ = segment.finish()
            stats = segment.stats()
        } else {
            stats = nil
        }
        cleanupLocked()
        return stats
    }

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "quill-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            // Fixed-size PCM packets survive an unclean process exit.
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(
        format: AVAudioFormat,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) throws {
        guard let segment else { throw RecorderError.ioProcCreationFailed(-1) }
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            _, inInputData, inInputTime, _, _ in
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                )
            else { return }
            let stamp = inInputTime.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil
            if let error = segment.write(buffer, hostTime: hostTime) {
                onEvent(.writeFailed(error))
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    /// Release whatever this attempt created, in dependency order. Safe after
    /// partial construction.
    private func cleanupLocked() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        segment = nil
    }
}
