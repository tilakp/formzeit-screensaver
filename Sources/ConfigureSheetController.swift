import Cocoa
import ScreenSaver

/// Formzeit v2 settings sheet (§7): grouped containers over a vibrancy
/// background, a live preview that observes settings changes, NSSwitch
/// toggles labeled by effect rather than mechanism, and picker rows for
/// face/world/accent/movement. Fully programmatic — no `.xib` — so the
/// whole module still builds with `swiftc` alone.
final class ConfigureSheetController: NSWindowController, NSWindowDelegate {

    private let defaults: FormzeitDefaults
    private var previewView: FormzeitView!

    private var faceButtons: [FaceThumbnailButton] = []
    private var worldButtons: [WorldChipButton] = []
    private var accentButtons: [AccentSwatchButton] = []
    private var plateButtons: [PlateChipButton] = []

    // Held so the colour groups can be shown/hidden per selected face.
    private weak var plateGroup: NSView?
    private weak var worldGroup: NSView?
    private weak var accentGroup: NSView?
    private weak var numeralsRow: NSView?
    /// Each row's preceding separator, so hiding a row hides its divider.
    /// Without this, `isHidden` on a row inside a groupBox is layout-inert:
    /// the hand-built constraint chain keeps its space and the NSBox above
    /// it is still drawn, leaving a stray divider over a dead band.
    private var rowSeparators: [ObjectIdentifier: NSBox] = [:]

    init(defaults: FormzeitDefaults) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    /// An orphaned ScreenSaverView timer left running inside System
    /// Settings after the sheet closes is a real battery bug — the preview
    /// must stop the instant the window goes away, not whenever the next
    /// GC cycle happens to reclaim it.
    func windowWillClose(_ notification: Notification) {
        previewView?.stopAnimation()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func settingsChanged() {
        previewView.invalidateFaceCache()
        updateFaceSelection()
        updateWorldSelection()
        updatePlateSelection()
        updateAccentSelection()
        updateGroupVisibility()
    }

    // MARK: - Build

    private func buildUI() {
        guard let window = window else { return }
        window.title = "Formzeit"

        let effect = NSVisualEffectView(frame: window.contentRect(forFrameRect: window.frame))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect

        previewView = FormzeitView(frame: NSRect(x: 0, y: 0, width: 560, height: 190), isPreview: true)
        effect.addSubview(previewView)
        previewView.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)

        // Flipped so the scroll view's initial position shows the *top* of
        // the content (Face/World groups) rather than a plain NSView
        // document's default of scrolling to the bottom first.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let faceGroup = groupBox("Face", rows: [buildFaceRow()])
        let plateGroup = groupBox("Plate", rows: [buildPlateRow()])
        let worldGroup = groupBox("World", rows: [buildWorldRow()])
        let accentGroup = groupBox("Accent", rows: [buildAccentRow()])
        let movementGroup = groupBox("Movement", rows: [buildMovementRow(), buildUse24HourRow(), buildShowNumeralsRow()])
        let protectionGroup = groupBox("Screen protection", rows: [
            switchRow("Move the light", "The light source drifts so no pixel stays lit.",
                       initial: defaults.burnInProtection, action: #selector(toggleMoveLight(_:))).row,
            switchRow("Follow the day", "Colour and brightness track the hour.",
                       initial: defaults.nightDimming, action: #selector(toggleFollowDay(_:))).row,
        ])

        // Colour controls are per-face and don't overlap: Plate paints the
        // Bauhaus dial, World/Accent light the aperture faces. Showing all
        // of them at once leaves whichever face you picked surrounded by
        // controls that visibly do nothing, so they're hidden instead.
        self.plateGroup = plateGroup
        self.worldGroup = worldGroup
        self.accentGroup = accentGroup

        let stack = NSStackView(views: [faceGroup, plateGroup, worldGroup, accentGroup, movementGroup, protectionGroup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        scroll.documentView = content

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let versionString = Bundle(for: ConfigureSheetController.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "v\(versionString)")
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        // Esc also closes the sheet — a hidden button carrying the escape
        // key equivalent is the standard AppKit idiom for this.
        let escButton = NSButton(title: "", target: self, action: #selector(closeSheet))
        escButton.keyEquivalent = "\u{1b}"
        escButton.isHidden = true
        escButton.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(versionLabel)
        footer.addSubview(doneButton)
        footer.addSubview(escButton)
        effect.addSubview(footer)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: effect.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            previewView.heightAnchor.constraint(equalToConstant: 190),

            scroll.topAnchor.constraint(equalTo: previewView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            faceGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            plateGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            worldGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accentGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            movementGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            protectionGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),

            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(equalToConstant: 24),
            versionLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            versionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        updateGroupVisibility()
        previewView.startAnimation()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                                name: .formzeitSettingsChanged, object: nil)
    }

    // MARK: - Rows

    private func buildFaceRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        for face in FaceKind.allCases {
            let button = FaceThumbnailButton(face: face, world: defaults.world, accent: defaults.accentV2)
            button.target = self
            button.action = #selector(faceTapped(_:))
            faceButtons.append(button)
            row.addArrangedSubview(button)
        }
        updateFaceSelection()
        return row
    }

    private func buildWorldRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        for world in ColorWorld.allCases {
            let button = WorldChipButton(world: world)
            button.target = self
            button.action = #selector(worldTapped(_:))
            worldButtons.append(button)
            row.addArrangedSubview(button)
        }
        updateWorldSelection()
        return row
    }

    /// The Bauhaus face's flat plate colours. Kept separate from World,
    /// which only drives the light-based faces.
    private func buildPlateRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        for palette in BauhausFace.Palette.all {
            let button = PlateChipButton(palette: palette)
            button.target = self
            button.action = #selector(plateTapped(_:))
            plateButtons.append(button)
            row.addArrangedSubview(button)
        }
        updatePlateSelection()
        return row
    }

    private func buildAccentRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 9
        for accent in Accent.allCases {
            let button = AccentSwatchButton(accent: accent)
            button.target = self
            button.action = #selector(accentTapped(_:))
            accentButtons.append(button)
            row.addArrangedSubview(button)
        }
        updateAccentSelection()
        return row
    }

    private func buildMovementRow() -> NSView {
        let label = sublabel("Second hand")
        let control = NSSegmentedControl(labels: Movement.allCases.map { $0.displayName },
                                          trackingMode: .selectOne, target: self,
                                          action: #selector(movementChanged(_:)))
        control.selectedSegment = Movement.allCases.firstIndex(of: defaults.movement) ?? 0
        control.segmentDistribution = .fillEqually
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([control.widthAnchor.constraint(equalToConstant: 508)])
        return stack
    }

    private func buildUse24HourRow() -> NSView {
        switchRow("24-hour time", "Show the hour in 24-hour format.",
                   initial: defaults.use24Hour, action: #selector(toggle24Hour(_:))).row
    }

    private func buildShowNumeralsRow() -> NSView {
        let row = switchRow("Show numerals", "Draw hour numerals over the marks, rather than marks alone.",
                             initial: defaults.showNumerals, action: #selector(toggleShowNumerals(_:))).row
        numeralsRow = row
        return row
    }

    // MARK: - Actions

    @objc private func faceTapped(_ sender: FaceThumbnailButton) {
        defaults.face = sender.face
        updateFaceSelection()
        updateGroupVisibility()
    }

    @objc private func plateTapped(_ sender: PlateChipButton) {
        defaults.bauhausPalette = sender.palette.key
        updatePlateSelection()
    }

    @objc private func worldTapped(_ sender: WorldChipButton) {
        defaults.world = sender.world
        updateWorldSelection()
    }

    @objc private func accentTapped(_ sender: AccentSwatchButton) {
        defaults.accentV2 = sender.accent
        updateAccentSelection()
    }

    @objc private func movementChanged(_ sender: NSSegmentedControl) {
        defaults.movement = Movement.allCases[sender.selectedSegment]
    }

    @objc private func toggle24Hour(_ sender: NSSwitch) { defaults.use24Hour = sender.state == .on }
    @objc private func toggleShowNumerals(_ sender: NSSwitch) { defaults.showNumerals = sender.state == .on }
    @objc private func toggleMoveLight(_ sender: NSSwitch) { defaults.burnInProtection = sender.state == .on }
    @objc private func toggleFollowDay(_ sender: NSSwitch) { defaults.nightDimming = sender.state == .on }

    @objc private func closeSheet() {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
    }

    private func updateFaceSelection() {
        for b in faceButtons { b.isSelected = (b.face == defaults.face) }
    }
    /// Bauhaus is painted from a Plate; Eclipse/Strata/Filament are lit by a
    /// World + Accent. Classic takes its second-hand colour from Accent but
    /// has no World. Hiding the rest keeps the sheet honest about what the
    /// current face actually responds to.
    private func updateGroupVisibility() {
        let face = defaults.face
        let usesPlate = (face == .bauhaus)
        let usesLight = (face == .eclipse || face == .strata || face == .filament)
        plateGroup?.isHidden = !usesPlate
        worldGroup?.isHidden = !usesLight
        accentGroup?.isHidden = !(usesLight || face == .classic)
        // Bauhaus, Classic and Strata always draw their own numerals (or
        // none at all); only the aperture faces can toggle them on.
        setRowHidden(numeralsRow, !(face == .eclipse || face == .filament))
    }

    /// Rows inside a groupBox are positioned by an explicit constraint chain
    /// rather than a stack view, so `isHidden` alone leaves their space and
    /// their separator behind. Collapse the height explicitly.
    private func setRowHidden(_ row: NSView?, _ hidden: Bool) {
        guard let row = row else { return }
        row.isHidden = hidden
        rowSeparators[ObjectIdentifier(row)]?.isHidden = hidden

        let existing = row.constraints.first { $0.identifier == "collapse" }
        if hidden {
            if existing == nil {
                let c = row.heightAnchor.constraint(equalToConstant: 0)
                c.identifier = "collapse"
                c.priority = .required
                c.isActive = true
            }
        } else {
            existing?.isActive = false
        }
    }

    private func updatePlateSelection() {
        for b in plateButtons { b.isSelected = (b.palette.key == defaults.bauhausPalette) }
    }
    private func updateWorldSelection() {
        for b in worldButtons { b.isSelected = (b.world == defaults.world) }
    }
    private func updateAccentSelection() {
        for b in accentButtons { b.isSelected = (b.accent == defaults.accentV2) }
    }

    // MARK: - UI helpers

    /// A rounded container (8pt radius, `controlBackgroundColor`, 13pt
    /// inset) with an uppercase header and 1pt `separatorColor` dividers
    /// between rows.
    private func groupBox(_ title: String, rows: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 9.5, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        var constraints: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -13),
        ]

        var previous: NSView = header
        for (i, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            constraints.append(row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13))
            constraints.append(row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -13))

            if i == 0 {
                constraints.append(row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10))
            } else {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(separator)
                rowSeparators[ObjectIdentifier(row)] = separator
                constraints.append(separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13))
                constraints.append(separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -13))
                constraints.append(separator.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 9))
                constraints.append(row.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 9))
            }
            previous = row
        }
        constraints.append(previous.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13))
        NSLayoutConstraint.activate(constraints)
        return container
    }

    /// A System-Settings-style toggle row: title + description on the
    /// left, an `NSSwitch` on the right. Switches read as persistent
    /// settings; checkboxes read as form fields awaiting submission.
    private func switchRow(_ title: String, _ subtitle: String, initial: Bool, action: Selector) -> (row: NSView, toggle: NSSwitch) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 380

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggle = NSSwitch()
        toggle.state = initial ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return (row, toggle)
    }

    private func sublabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }
}

/// A plain flipped container — used only as the scroll view's document
/// view, so it opens scrolled to the top (Face/World) instead of the
/// bottom, which is what a non-flipped document view defaults to.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Custom picker controls

/// Shared focus-ring support for the borderless custom buttons below —
/// `isBordered = false` otherwise drops the visible focus ring System
/// Settings' own controls get for free, which was the v1 sheet's one
/// keyboard-accessibility gap.
///
/// Also the shared fix for a real bug: as an arranged subview of an
/// `NSStackView`, a plain `NSButton` created via `init(frame:)` collapses to
/// zero size — `NSStackView` requires `translatesAutoresizingMaskIntoConstraints
/// = false` on its arranged subviews and sizes them from
/// `intrinsicContentSize`, not from the frame a subclass happened to init
/// with. Every picker row (Face/World/Accent) silently rendered empty until
/// this was in place.
class RoundIconButton: NSButton {
    private var preferredSize: NSSize = .zero

    override var intrinsicContentSize: NSSize { preferredSize }

    func setPreferredSize(_ size: NSSize) {
        preferredSize = size
        invalidateIntrinsicContentSize()
    }

    override var canBecomeKeyView: Bool { true }
    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A face thumbnail rendered by the real renderer at a fixed time
/// (10:09:36) via a throwaway settings domain — words alone can't
/// distinguish Eclipse/Strata/Filament/Classic, a picture can.
final class FaceThumbnailButton: RoundIconButton {
    let face: FaceKind
    private let world: ColorWorld
    private let accent: Accent
    private var cachedImage: NSImage?

    var isSelected = false { didSet { needsDisplay = true } }

    init(face: FaceKind, world: ColorWorld, accent: Accent) {
        self.face = face
        self.world = world
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        translatesAutoresizingMaskIntoConstraints = false
        setPreferredSize(NSSize(width: 96, height: 96))
        isBordered = false
        title = ""
        wantsLayer = true
        toolTip = face.displayName
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        if cachedImage == nil {
            cachedImage = Self.renderThumbnail(face: face, world: world, accent: accent, size: rect.size)
        }
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        cachedImage?.draw(in: rect)
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private static func renderThumbnail(face: FaceKind, world: ColorWorld, accent: Accent, size: NSSize) -> NSImage? {
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: size)
        let previewDefaults = FormzeitDefaults(transientFace: face, world: world, accent: accent)
        var comps = DateComponents()
        comps.hour = 10; comps.minute = 9; comps.second = 36
        let date = Calendar.current.date(from: comps) ?? Date()
        FormzeitRenderer.render(context: ctx, bounds: bounds, now: date, elapsedRunTime: 9999, isPreview: true, defaults: previewDefaults)
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

/// A 15pt dot in a world's light color (Duplex split half/half), with its
/// name beneath — the world picker.
final class WorldChipButton: RoundIconButton {
    let world: ColorWorld
    private let diameter: CGFloat = 15

    var isSelected = false { didSet { needsDisplay = true } }

    init(world: ColorWorld) {
        self.world = world
        super.init(frame: NSRect(x: 0, y: 0, width: 62, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        setPreferredSize(NSSize(width: 62, height: 44))
        isBordered = false
        title = ""
        wantsLayer = true
        toolTip = world.displayName
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let dotRect = CGRect(x: bounds.midX - diameter / 2, y: bounds.height - diameter - 6, width: diameter, height: diameter)

        if world == .duplex, let secondHex = world.secondaryLightHex, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.addPath(CGPath(ellipseIn: dotRect, transform: nil))
            ctx.clip()
            ctx.setFillColor(NSColor(hex: world.lightHex).cgColor)
            ctx.fill(CGRect(x: dotRect.minX, y: dotRect.minY, width: dotRect.width / 2, height: dotRect.height))
            ctx.setFillColor(NSColor(hex: secondHex).cgColor)
            ctx.fill(CGRect(x: dotRect.midX, y: dotRect.minY, width: dotRect.width / 2, height: dotRect.height))
            ctx.restoreGState()
        } else {
            NSColor(hex: world.lightHex).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        if isSelected {
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -3, dy: -3))
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let label = NSString(string: world.displayName)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 0), withAttributes: attrs)
    }
}

/// A 26pt circular swatch — the accent picker. Adaptive shows an
/// approximated conic sweep of the diel light track rather than a single
/// hue, since it has none of its own.
final class AccentSwatchButton: RoundIconButton {
    let accent: Accent
    private let diameter: CGFloat = 26

    var isSelected = false { didSet { needsDisplay = true } }

    // 26pt swatch + 5pt selection-ring offset (§7) + a little stroke
    // clearance, so the ring never gets clipped at the button's edge.
    private static let buttonSize: CGFloat = 44

    init(accent: Accent) {
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize))
        translatesAutoresizingMaskIntoConstraints = false
        setPreferredSize(NSSize(width: Self.buttonSize, height: Self.buttonSize))
        isBordered = false
        title = ""
        wantsLayer = true
        toolTip = accent.displayName
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: (Self.buttonSize - diameter) / 2, dy: (Self.buttonSize - diameter) / 2)

        if let hex = accent.hex {
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: circleRect).fill()
        } else if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            let center = CGPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = circleRect.width / 2
            let wedges = 24
            for i in 0..<wedges {
                let hour = Double(i) / Double(wedges) * 24.0
                let color = fromOklab(DielLighting.previewLightSample(hourOfDay: hour))
                let a0 = CGFloat(i) / CGFloat(wedges) * 2 * .pi
                let a1 = CGFloat(i + 1) / CGFloat(wedges) * 2 * .pi
                let wedge = CGMutablePath()
                wedge.move(to: center)
                wedge.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
                wedge.closeSubpath()
                ctx.addPath(wedge)
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        if isSelected {
            // 1.5pt ring at a 5pt offset from the swatch's own edge (§7),
            // in the swatch's own colour.
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: -5, dy: -5))
            let ringColor = accent.hex.map { NSColor(hex: $0) } ?? NSColor.labelColor
            ringColor.withAlphaComponent(0.85).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}


/// A flat swatch of a Bauhaus plate colour, with its dark ink shown as a
/// small bar so the pairing is visible before you pick it.
final class PlateChipButton: RoundIconButton {
    let palette: BauhausFace.Palette
    var isSelected = false { didSet { needsDisplay = true } }

    init(palette: BauhausFace.Palette) {
        self.palette = palette
        super.init(frame: NSRect(x: 0, y: 0, width: 62, height: 46))
        translatesAutoresizingMaskIntoConstraints = false
        setPreferredSize(NSSize(width: 62, height: 46))
        isBordered = false
        title = ""
        wantsLayer = true
        toolTip = palette.name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSRect(x: bounds.midX - 13, y: bounds.height - 26, width: 26, height: 20)
        let path = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        palette.bg.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        // the plate's ink, as a short bar
        palette.mark.setFill()
        NSBezierPath(roundedRect: NSRect(x: chip.midX - 6, y: chip.minY + 5, width: 12, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()

        if isSelected {
            let ring = NSBezierPath(roundedRect: chip.insetBy(dx: -3.5, dy: -3.5), xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let label = NSString(string: palette.name)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                      .foregroundColor: NSColor.secondaryLabelColor]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 0), withAttributes: attrs)
    }
}
