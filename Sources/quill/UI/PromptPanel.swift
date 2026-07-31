import AppKit

/// Ask the user something with a floating banner. `onAccept` runs only if they
/// click `button`; dismissing or ignoring it does nothing. Any prompt already
/// on screen is replaced.
@MainActor
func askUser(
    title: String,
    body: String,
    button: String,
    onAccept: @escaping @MainActor () -> Void
) {
    PromptPanel.present(title: title, body: body, button: button, onAccept: onAccept)
}

/// Retire the prompt on screen, if any, without accepting it. For when the
/// thing it asked about stopped being true.
@MainActor
func retirePrompt() {
    PromptPanel.retireCurrent()
}

/// A borderless capsule panel centred under the menu bar, clear of whatever
/// notch widget lives up there.
///
/// An AppleScript `display dialog` would be four lines instead of this file,
/// but it activates the app and lands centre-screen on the *active* Space: the
/// app you just joined a call in loses focus, and a full-screen meeting window
/// hides the prompt outright. A `.nonactivatingPanel` that joins all spaces and
/// floats over full-screen windows has neither problem — which is the whole
/// job, since everyone we prompt is by definition mid-meeting.
@MainActor
final class PromptPanel: NSPanel {
    private static var current: PromptPanel?
    /// Long enough to catch someone settling into a call, short enough that a
    /// missed prompt doesn't linger for the rest of the meeting.
    private static let autoDismissAfter: TimeInterval = 120
    /// Clearance below the menu bar. Enough to clear a notch widget hanging
    /// off the menu bar without looking detached from it.
    private static let topGap: CGFloat = 12
    /// Keep the pill clear of the screen edges on narrow displays.
    private static let sideMargin: CGFloat = 20

    private let onAccept: @MainActor () -> Void
    private var autoDismiss: Timer?

    static func present(
        title: String,
        body: String,
        button: String,
        onAccept: @escaping @MainActor () -> Void
    ) {
        current?.close()
        let panel = PromptPanel(heading: title, body: body, button: button, onAccept: onAccept)
        current = panel
        panel.appear()
    }

    static func retireCurrent() {
        current?.fadeOut()
    }

    private init(
        heading: String,
        body: String,
        button: String,
        onAccept: @escaping @MainActor () -> Void
    ) {
        self.onAccept = onAccept
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // .statusBar, not .floating: this has to clear a full-screen app.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // NSWindow defaults to release-on-close, which over-releases under ARC.
        isReleasedWhenClosed = false
        animationBehavior = .none

        let content = contentStack(heading: heading, body: body, button: button)
        let background = PillView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            // A long app name must truncate rather than run off a small screen.
            content.widthAnchor.constraint(
                lessThanOrEqualToConstant: (Self.targetScreen()?.visibleFrame.width ?? 1440)
                    - 2 * Self.sideMargin
            ),
        ])
        contentView = background
        setContentSize(background.fittingSize)
    }

    // MARK: - Layout

    private func contentStack(heading: String, body: String, button: String) -> NSStackView {
        let text = NSStackView(views: [
            Self.label(heading, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor),
            Self.label(body, font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let dismiss = CapsuleButton(
            title: "Dismiss",
            fill: NSColor.labelColor.withAlphaComponent(0.10),
            textColor: .labelColor,
            target: self,
            action: #selector(dismissClicked)
        )
        let accept = CapsuleButton(
            title: button,
            fill: .controlAccentColor,
            textColor: .white,
            target: self,
            action: #selector(acceptClicked)
        )

        let stack = NSStackView(views: [AccentWell(diameter: 34), text, dismiss, accept])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(22, after: text)
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
        // When the width clamp bites, the text gives and the controls don't.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in stack.arrangedSubviews where view !== text {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return stack
    }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: - Lifecycle

    /// Drop out from under the menu bar and fade in — the same gesture as a
    /// system notification, so it reads as "the machine noticed something"
    /// rather than "an app is interrupting you".
    ///
    /// Top-centre on every Mac, measured off `visibleFrame`, so a notched
    /// laptop, a 27" external and an auto-hidden menu bar all land the same
    /// way — and on a notched Mac it clears whatever notch widget (Island,
    /// Alcove, NotchNook) is parked up there, instead of colliding with the
    /// menu-bar items a top-right banner would sit under.
    private func appear() {
        guard let screen = Self.targetScreen() else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let resting = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.maxY - size.height - Self.topGap,
            width: size.width,
            height: size.height
        )

        setFrameOrigin(NSPoint(x: resting.minX, y: resting.minY + 18))
        alphaValue = 0
        orderFrontRegardless()
        invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // setFrame(_:display:), not setFrameOrigin(_:): only the former
            // animates through NSWindow's proxy. The latter silently does
            // nothing, parking the panel at its pre-animation offset.
            animator().setFrame(resting, display: true)
            animator().alphaValue = 1
        }

        autoDismiss = Timer.scheduledTimer(
            withTimeInterval: Self.autoDismissAfter,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        autoDismiss?.invalidate()
        autoDismiss = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override func close() {
        autoDismiss?.invalidate()
        autoDismiss = nil
        if Self.current === self { Self.current = nil }
        super.close()
    }

    @objc private func dismissClicked() { fadeOut() }

    @objc private func acceptClicked() {
        let accept = onAccept
        fadeOut()
        accept()
    }

    /// NSScreen.main is the screen holding the active window — the one the
    /// user is looking at — but it's nil for an accessory app when nothing is
    /// focused, so fall back to the first attached display.
    private static func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: -

/// Capsule background for the banner: `NSVisualEffectView` doesn't round
/// itself, and a CGColor border doesn't follow light/dark on its own.
private final class PillView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyBorderColor()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Tinted circular well holding the quill feather.
private final class AccentWell: NSView {
    init(diameter: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        applyFill()

        let icon = NSImageView(image: Feather.image(size: diameter * 0.55) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }
    }
}

/// Pill-shaped button. AppKit has no capsule bezel style, and because the panel
/// is non-activating the buttons also have to accept the very first click
/// rather than spending it on focusing the window.
private final class CapsuleButton: NSButton {
    private let fill: NSColor
    private var hovered = false

    init(title: String, fill: NSColor, textColor: NSColor, target: AnyObject, action: Selector) {
        self.fill = fill
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: textColor,
            ]
        )
        applyFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 24, height: 28)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFill()
    }

    private func applyFill() {
        let color = hovered ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
