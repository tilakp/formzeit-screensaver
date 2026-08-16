import Cocoa
import ScreenSaver

/// A fully programmatic settings sheet (no .xib/.nib) so the whole module
/// can be built with `swiftc` alone. Presented by ScreenSaverView's
/// `configureSheet` when the user clicks "Screen Saver Options…".
final class ConfigureSheetController: NSWindowController {

    private let defaults: FormzeitDefaults
    private var swatchButtons: [SwatchButton] = []
    private var movementControl: NSSegmentedControl!
    private var use24HourCheckbox: NSButton!
    private var burnInCheckbox: NSButton!
    private var nightDimCheckbox: NSButton!

    init(defaults: FormzeitDefaults) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 402),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let window = window else { return }
        window.title = "Formzeit"

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content

        let title = label("Formzeit", size: 17, weight: .semibold)
        let subtitle = label("A quiet, Bauhaus-inspired analog clock.", size: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        let accentLabel = sectionLabel("Accent")
        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 12
        for (i, accent) in AccentColor.all.enumerated() {
            let swatch = SwatchButton(index: i, color: accent.color)
            swatch.toolTip = accent.name
            swatch.target = self
            swatch.action = #selector(accentTapped(_:))
            swatchButtons.append(swatch)
            swatchRow.addArrangedSubview(swatch)
        }
        updateSwatchSelection()

        let movementLabel = sectionLabel("Movement")
        movementControl = NSSegmentedControl(labels: Movement.allCases.map { $0.displayName },
                                              trackingMode: .selectOne, target: self,
                                              action: #selector(movementChanged(_:)))
        movementControl.selectedSegment = Movement.allCases.firstIndex(of: defaults.movement) ?? 0
        movementControl.segmentDistribution = .fillEqually

        let displayLabel = sectionLabel("Display")
        use24HourCheckbox = checkbox("24-hour time", selector: #selector(toggle24Hour(_:)), state: defaults.use24Hour)

        let protectionLabel = sectionLabel("Screen protection")
        burnInCheckbox = checkbox("Prevent burn-in (slow drift + auto-dim over time)",
                                   selector: #selector(toggleBurnIn(_:)), state: defaults.burnInProtection)
        nightDimCheckbox = checkbox("Dim automatically at night (10pm–7am)",
                                     selector: #selector(toggleNightDim(_:)), state: defaults.nightDimming)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title, subtitle,
            spacer(8),
            accentLabel, swatchRow,
            spacer(10),
            movementLabel, movementControl,
            spacer(10),
            displayLabel, use24HourCheckbox,
            spacer(10),
            protectionLabel, burnInCheckbox, nightDimCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let buttonRow = NSStackView(views: [NSView(), doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            movementControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func accentTapped(_ sender: SwatchButton) {
        defaults.accentIndex = sender.index
        updateSwatchSelection()
    }

    @objc private func movementChanged(_ sender: NSSegmentedControl) {
        defaults.movement = Movement.allCases[sender.selectedSegment]
    }

    @objc private func toggle24Hour(_ sender: NSButton) {
        defaults.use24Hour = sender.state == .on
    }

    @objc private func toggleBurnIn(_ sender: NSButton) {
        defaults.burnInProtection = sender.state == .on
    }

    @objc private func toggleNightDim(_ sender: NSButton) {
        defaults.nightDimming = sender.state == .on
    }

    @objc private func closeSheet() {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
    }

    private func updateSwatchSelection() {
        for swatch in swatchButtons {
            swatch.isSelected = swatch.index == defaults.accentIndex
        }
    }

    // MARK: - UI helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        return field
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = label(text.uppercased(), size: 10.5, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func checkbox(_ text: String, selector: Selector, state: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: text, target: self, action: selector)
        button.state = state ? .on : .off
        return button
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

/// A round color swatch with a selection ring, standing in for a proper
/// radio-button group since AppKit has no built-in color-chip control.
final class SwatchButton: NSButton {
    let index: Int
    private let swatchColor: NSColor
    private let diameter: CGFloat = 26

    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    init(index: Int, color: NSColor) {
        self.index = index
        self.swatchColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: diameter + 8, height: diameter + 8))
        isBordered = false
        title = ""
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: diameter + 8).isActive = true
        heightAnchor.constraint(equalToConstant: diameter + 8).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 4
        let circleRect = bounds.insetBy(dx: inset, dy: inset)

        if isSelected {
            let ringRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        let path = NSBezierPath(ovalIn: circleRect)
        swatchColor.setFill()
        path.fill()
    }
}
