import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    /// What the menu communicates about capture. Recovering and degraded are
    /// distinct from healthy recording so a user glancing mid-meeting can see
    /// that something happened; elapsed time stays visible in every recording
    /// state.
    enum Display: Equatable {
        case idle
        case recording(elapsed: String)
        case recovering(track: String, elapsed: String)
        case degraded(track: String, elapsed: String)
    }

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let warningLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let dropTarget = StatusItemDropTarget()

    var onToggle: (() -> Void)?
    var onImport: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Audio files dropped onto the feather (already filtered to supported
    /// types).
    var onDropFiles: (([URL]) -> Void)? {
        get { dropTarget.onDrop }
        set { dropTarget.onDrop = newValue }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        warningLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningLabel.isEnabled = false
        warningLabel.isHidden = true
        menu.addItem(warningLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let importItem = NSMenuItem(
            title: "Transcribe audio file…",
            action: #selector(importClicked),
            keyEquivalent: "i"
        )
        menu.addItem(importItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, importItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            dropTarget.button = button
            // The status item's window forwards dragging-destination
            // messages to its delegate, so dropping a file on the feather
            // works without replacing the button's own click handling.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = dropTarget
        }
    }

    /// Reflect capture state in the icon tint and menu item titles. The menu
    /// bar shows only the feather (red while healthy, orange while capture is
    /// recovering or lost); the elapsed counter lives in the menu's state
    /// label. Call once a second while recording and on every status change.
    /// `signalWarning` is a secondary diagnostic (exact digital silence on a
    /// track that is still delivering callbacks) — its own line, never the
    /// same visual state as stopped callbacks.
    func update(_ display: Display, signalWarning: Bool = false) {
        switch display {
        case .idle:
            stateLabel.title = "idle"
            toggleItem.title = "Start recording"
            statusItem.button?.contentTintColor = nil
        case .recording(let elapsed):
            stateLabel.title = "● recording · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemRed
        case .recovering(let track, let elapsed):
            stateLabel.title = "◐ recovering \(track) · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        case .degraded(let track, let elapsed):
            stateLabel.title = "⚠ \(track) capture lost · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        }
        let warn = signalWarning && display != .idle
        warningLabel.title = warn ? "△ system audio silent" : ""
        warningLabel.isHidden = !warn
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
        viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
        stroke-linecap="round" stroke-linejoin="round">\
        <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
        <path d="M16 8 2 22"/>\
        <path d="M17.5 15H9"/>\
        </svg>
        """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
            let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func importClicked() { onImport?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}

/// Accepts audio files dragged onto the menu-bar feather (e.g. a Voice Memo
/// just AirDropped into Downloads). The feather highlights while a drag
/// carrying at least one importable file hovers over it; anything else is
/// refused so the drag snaps back.
@MainActor
private final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    weak var button: NSStatusBarButton?
    var onDrop: (([URL]) -> Void)?

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accept = !audioURLs(in: sender).isEmpty
        button?.highlight(accept)
        return accept ? .copy : []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        audioURLs(in: sender).isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        button?.highlight(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let urls = audioURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func audioURLs(in info: any NSDraggingInfo) -> [URL] {
        let urls =
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        return urls.filter(AudioImport.isSupported)
    }
}
