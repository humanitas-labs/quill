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

        FileHandle.standardError.write(
            Data(
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
    private var session: RecordingSession?
    private var captureStatus = RecordingSession.CaptureStatus.allHealthy
    private var ticker: Timer?
    private var stopDeadline: Date?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onStartTimed = { [weak self] d in self?.startTimed(d) }
        menuBar.onExtend = { [weak self] d in self?.extend(by: d) }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(.idle)

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
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startTimed(_ duration: TimeInterval) {
        guard session == nil else { return }
        startSession(duration: duration)
    }

    private func extend(by seconds: TimeInterval) {
        guard session != nil, let deadline = stopDeadline else { return }
        stopDeadline = StopTimer(deadline: deadline).extended(by: seconds).deadline
        FileHandle.standardError.write(
            Data("◍ auto-stop extended by \(Self.shortFormat(seconds))\n".utf8))
        refreshMenu()
    }

    private func startSession(duration: TimeInterval? = nil) {
        do {
            let newSession = try RecordingSession(root: root)
            newSession.onStatus = { [weak self] status in
                self?.captureStatus = status
                self?.refreshMenu()
            }
            newSession.onDegraded = { kind in
                // The session fires this once per degradation episode, so the
                // user gets one notification, not one per watchdog tick.
                notifyUser(
                    title: "quill — \(kind.label) capture lost",
                    body: "Recovery failed; the recording will be marked incomplete."
                )
            }
            try newSession.start()
            session = newSession
            captureStatus = .allHealthy
            stopDeadline = duration.map { newSession.startedAt.addingTimeInterval($0) }
            let autoStop = duration.map { " (auto-stop in \(Self.shortFormat($0)))" } ?? ""
            FileHandle.standardError.write(
                Data("● recording\(autoStop) → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        refreshMenu()
        // Explicitly .common so the elapsed counter and menu state keep
        // updating while the menu is open (event-tracking run-loop mode).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopSession() {
        guard let session else { return }
        let result = session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(
            Data(
                "○ stopped · \(elapsed) · \(result.status.rawValue) · \(session.dir.path)\n".utf8
            ))
        self.session = nil
        captureStatus = .allHealthy
        stopDeadline = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(.idle)

        // Warn about a gap before the later "transcript ready" notification
        // implies everything went fine. Transcription still runs — recovered
        // and incomplete sessions keep whatever audio they have.
        switch result.status {
        case .complete:
            break
        case .recovered:
            notifyUser(
                title: "quill — recording recovered",
                body: "Capture was interrupted and resumed; see meta.json for the gap."
            )
        case .incomplete:
            notifyUser(
                title: "quill — recording incomplete",
                body: "Part of the session was not captured; see meta.json."
            )
        }
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Rebuild the menu presentation from capture status plus elapsed time.
    private func refreshMenu() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        let remaining = stopDeadline.map {
            Self.format(ceil(StopTimer(deadline: $0).remaining(at: Date())))
        }
        let display: MenuBarController.Display
        switch captureStatus.display {
        case .healthy:
            display = .recording(elapsed: elapsed)
        case .recovering(let kind):
            display = .recovering(track: kind.label, elapsed: elapsed)
        case .degraded(let kind):
            display = .degraded(track: kind.label, elapsed: elapsed)
        }
        menuBar.update(display, signalWarning: captureStatus.signalWarning, remaining: remaining)
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
        if let deadline = stopDeadline,
            StopTimer(deadline: deadline).isExpired(at: Date())
        {
            let elapsed = Self.format(Date().timeIntervalSince(session?.startedAt ?? Date()))
            notifyUser(
                title: "quill — timer finished",
                body: "Recording stopped after \(elapsed)."
            )
            FileHandle.standardError.write(Data("◍ auto-stop reached · \(elapsed)\n".utf8))
            stopSession()
            return
        }
        refreshMenu()
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private static func shortFormat(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds % 3600 == 0 ? "\(seconds / 3600)h" : "\(seconds / 60)m"
    }
}
