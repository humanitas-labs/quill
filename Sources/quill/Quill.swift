import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let detector = MeetingDetector()
    private var session: RecordingSession?
    private var ticker: Timer?
    /// Whether the live session was started by the meeting prompt rather than
    /// by hand. Only those stop themselves when the call ends — silently
    /// ending a recording someone started deliberately would lose audio they
    /// asked for.
    private var autoStarted = false
    private var detectionEnabled = false

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        detectionEnabled = Config.meetingDetectionEnabled()
        if detectionEnabled {
            detector.onMeetingStart = { [weak self] appName in
                let who = appName ?? "Your microphone"
                FileHandle.standardError.write(Data("◆ \(who) is in use\n".utf8))
                // Already recording: nothing to offer.
                guard let self, self.session == nil else { return }
                askUser(
                    title: appName.map { "\($0) is in a call" } ?? "Your microphone is in use",
                    body: "Record this meeting?",
                    button: "Record",
                    // "No" holds for this call. A quiet poll clears the
                    // detector's own record of having asked, so without this a
                    // brief mic dropout would ask again after you declined.
                    onDismiss: { [weak self] in self?.detector.declineCurrentMeeting() }
                ) { [weak self] in
                    // Recording may have started manually while the prompt was up.
                    guard let self, self.session == nil else { return }
                    self.startSession(auto: true)
                }
            }
            // An unanswered prompt outlives the call it asked about (it sits
            // for two minutes). Accepting it then would start a session no
            // later end event could stop, so it goes as soon as the mic frees.
            detector.onMeetingQuiet = { retirePrompt() }
            detector.onMeetingEnd = { [weak self] in
                guard let self, self.session != nil, self.autoStarted else { return }
                FileHandle.standardError.write(Data("◇ call ended\n".utf8))
                self.stopSession()
            }
            detector.start()
        }

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        detector.stop()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession(auto: Bool = false) {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            autoStarted = auto
            if !auto {
                // Started from the menu, so any prompt on screen is offering
                // something we're already doing — and the pause below would
                // strand it there for its full two-minute timeout. (The pill's
                // own Record button has already faded itself by this point.)
                retirePrompt()
                // Holding the mic ourselves makes every audio client look
                // busy, so the detector would scan all of them once a second
                // to answer a question we'd ignore anyway: a call starting
                // can't prompt while a session is live. An auto-started
                // session keeps it, to notice the call it came from ending.
                detector.stop()
            }
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        autoStarted = false
        if detectionEnabled { detector.start() }
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
