import CoreAudio
import Darwin
import Foundation

/// Notices when something other than quill starts using the microphone.
///
/// "Some app is holding a live input stream" is as close to "you are in a call"
/// as macOS will say without extra permissions, and it beats matching a list of
/// meeting apps: a list has to be maintained, mislabels shared helper processes,
/// and fails *silently* for anything nobody thought to add. The trade is
/// deliberate — a false prompt costs one click, a missed one costs the meeting.
///
/// Polling rather than a property listener: listener callbacks for these
/// selectors are unreliable, and the answer almost always comes from one cheap
/// device read.
@MainActor
final class MeetingDetector {
    /// Something took the mic. The argument is a display name ("Microsoft
    /// Teams") when the capturing process belongs to an app, nil for the
    /// daemons and XPC helpers that have no app to name.
    var onMeetingStart: ((String?) -> Void)?

    /// The mic went quiet a moment ago (~2 s). The call could still come back
    /// from a device switch, so this is only for things that are cheap to
    /// lose — an unanswered prompt, not a running recording.
    var onMeetingQuiet: (() -> Void)?

    /// Still quiet after ~16 s: the call is over.
    var onMeetingEnd: (() -> Void)?

    /// One second. An idle poll is one cheap device read, so the ceiling on
    /// how fast the prompt can appear is worth more than the microseconds.
    private static let pollInterval: TimeInterval = 1
    /// Two hits (~2 s) still filters the blips — a Siri activation or a mic
    /// test rarely holds the input stream across two consecutive samples —
    /// while getting the prompt up while you're still saying hello.
    private static let activePollsToPrompt = 2
    /// A prompt for a call that already ended is worse than one that flickers
    /// back if the call resumes, so it goes ~2 s after the mic frees.
    private static let quietPollsToRetire = 2
    /// A recording is not cheap to lose, so it waits ~16 s — long enough to
    /// ride out swapping headphones mid-call.
    private static let quietPollsToEnd = 16

    private let ownPID = getpid()
    private var timer: Timer?
    /// The client we last saw capturing. Re-checking it is two reads; finding
    /// it in the first place is a scan, so remember it between polls.
    private var capturing: (object: AudioObjectID, pid: pid_t)?
    private var consecutiveActive = 0
    private var consecutiveInactive = 0
    /// Capture has been confirmed and not yet declared over. Drives the end
    /// detection, and outlives the prompt: the mic can drop for a moment
    /// mid-call without the call being over.
    private var inMeeting = false
    /// The process we have already asked about. Held by pid, like the decline
    /// below, because the question is about one specific call: if the mic
    /// passes straight from one app to another there is no quiet gap to clear
    /// a plain flag, and the second app would never be offered.
    private var askedPID: pid_t?
    /// The process the user said no to. A dropout of that same process stays
    /// declined, but a different app taking the mic is a different call.
    private var declinedPID: pid_t?
    private var loggedPollFailure = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Stops polling and forgets everything observed so far. The state has to
    /// go: nothing watched the mic while we were stopped, so a stale `asked`
    /// would suppress the prompt for a call that began in the gap, and a stale
    /// `inMeeting` would end a call that was already over.
    func stop() {
        timer?.invalidate()
        timer = nil
        capturing = nil
        consecutiveActive = 0
        consecutiveInactive = 0
        inMeeting = false
        askedPID = nil
        declinedPID = nil
    }

    /// The user dismissed the prompt for whoever holds the mic right now.
    /// Don't ask again for that process.
    func declineCurrentMeeting() {
        declinedPID = capturing?.pid
    }

    // MARK: -

    private func poll() {
        guard someoneElseIsCapturing() else {
            consecutiveActive = 0
            // No meeting was ever reported, so there is nothing to end.
            guard inMeeting else { return }
            consecutiveInactive += 1
            if consecutiveInactive == Self.quietPollsToRetire {
                askedPID = nil
                onMeetingQuiet?()
            }
            guard consecutiveInactive >= Self.quietPollsToEnd else { return }
            consecutiveInactive = 0
            inMeeting = false
            declinedPID = nil
            onMeetingEnd?()
            return
        }
        consecutiveInactive = 0
        consecutiveActive += 1
        guard consecutiveActive >= Self.activePollsToPrompt else { return }
        inMeeting = true
        // Ask once per capturing process: not again for one already asked
        // about, and never for one the user turned down.
        guard let pid = capturing?.pid, pid != askedPID, pid != declinedPID else { return }
        askedPID = pid
        onMeetingStart?(Self.appName(forPID: pid))
    }

    /// Whether any process except quill is holding an input stream.
    ///
    /// Three tiers, cheapest first, because this runs every second forever:
    /// ask the devices whether anyone at all is capturing (~0.1 ms, and the
    /// answer is no all day), then re-check the client we already know
    /// about (~2 ms), and only scan every client when neither settles it.
    /// Interrogating all ~50 audio clients costs ~45 ms — that is the main
    /// thread, so it stays off the common path.
    private func someoneElseIsCapturing() -> Bool {
        guard anyInputDeviceRunning() else {
            capturing = nil
            return false
        }
        // Same client as last poll? Confirm the id wasn't recycled onto another
        // process while we weren't looking, and we're done.
        if let capturing,
            uint32Property(capturing.object, kAudioProcessPropertyIsRunningInput) == 1,
            pidProperty(capturing.object) == capturing.pid {
            return true
        }
        for object in processObjects() {
            guard uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            // quill's own MicRecorder makes quill a capturing process; ignoring
            // it is what lets an auto-started recording notice the call ending.
            guard let pid = pidProperty(object), pid != ownPID else { continue }
            capturing = (object, pid)
            return true
        }
        capturing = nil
        return false
    }

    /// Whether any input device is running for anyone. Unlike the per-process
    /// properties this isn't tripped by playback: devices with no input streams
    /// are skipped, so music on the built-in speakers still answers "no".
    private func anyInputDeviceRunning() -> Bool {
        for device in deviceObjects() where hasInputStreams(device) {
            if uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 {
                return true
            }
        }
        return false
    }

    private func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Finder's name for the app owning `pid` — "Google Chrome" for a renderer
    /// buried in Chrome's Frameworks directory, since the outermost `.app` is
    /// the one a human would recognise. Daemons and XPC services have no `.app`
    /// and get no name.
    private static func appName(forPID pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(PATH_MAX))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }

        let components = (String(decoding: buffer[..<Int(length)], as: UTF8.self) as NSString)
            .pathComponents
        guard let end = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return FileManager.default.displayName(
            atPath: NSString.path(withComponents: Array(components[...end]))
        )
    }

    // MARK: - Core Audio plumbing

    private func processObjects() -> [AudioObjectID] {
        systemObjects(kAudioHardwarePropertyProcessObjectList, describedAs: "process list")
    }

    private func deviceObjects() -> [AudioObjectID] {
        systemObjects(kAudioHardwarePropertyDevices, describedAs: "device list")
    }

    private func systemObjects(
        _ selector: AudioObjectPropertySelector,
        describedAs what: String
    ) -> [AudioObjectID] {
        var address = Self.globalAddress(selector)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { return logPollFailure(what, status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects)
        guard status == noErr else { return logPollFailure(what, status) }
        let written = Int(size) / MemoryLayout<AudioObjectID>.size
        if written < count { objects.removeLast(count - written) }
        return objects
    }

    /// A failing poll is "nobody is on a call" — reported once, then silent, so
    /// a permanently unhappy Core Audio can't spam the log every 2 seconds.
    private func logPollFailure(_ what: String, _ status: OSStatus) -> [AudioObjectID] {
        if !loggedPollFailure {
            loggedPollFailure = true
            FileHandle.standardError.write(Data(
                "meeting detection: \(what) unreadable (OSStatus \(status)) — detection off\n".utf8
            ))
        }
        return []
    }

    private func uint32Property(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = Self.globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = Self.globalAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func globalAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
