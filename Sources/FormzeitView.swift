import ScreenSaver
import Cocoa

@objc(FormzeitView)
public final class FormzeitView: ScreenSaverView {

    private let settings = FormzeitDefaults()
    private var configController: ConfigureSheetController?
    private var runStart = Date()

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        animationTimeInterval = 1.0 / 60.0
    }

    public override func startAnimation() {
        super.startAnimation()
        runStart = Date()
    }

    public override func animateOneFrame() {
        needsDisplay = true
    }

    public override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            super.draw(rect)
            return
        }
        FormzeitRenderer.render(context: context, bounds: bounds, now: Date(), isPreview: isPreview,
                                 defaults: settings, runStart: runStart)
    }

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let controller = ConfigureSheetController(defaults: settings)
        configController = controller
        return controller.window
    }
}
