import ScreenSaver
import Cocoa

@objc(FormzeitView)
public final class FormzeitView: ScreenSaverView {

    private let settings = FormzeitDefaults()
    private var configController: ConfigureSheetController?
    private var runStart = Date()

    // The face (bezel/texture/ticks/numerals) barely changes frame to frame
    // — drift moves it a fraction of a pixel per second, dimming ramps over
    // minutes — but rendering it is the expensive part (soft shadows and a
    // blended noise texture). Redrawing it from scratch on every animation
    // tick was pegging a full CPU core for no visible benefit, since 59 out
    // of every 60 frames looked identical to the one before. It's rendered
    // once into this cache and refreshed on a multi-second timer instead;
    // only the hands are drawn live every frame.
    private var faceCache: CGImage?
    private var faceCacheSize: NSSize = .zero
    private var faceCacheGeneratedAt: Date = .distantPast
    // Drift moves at most ~0.4px/sec and dim/glow ramp over minutes, so even
    // several seconds of cache staleness is invisible — worth spending on
    // fewer regenerations of the expensive face pass.
    private let faceCacheRefreshInterval: TimeInterval = 5.0

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
        animationTimeInterval = 1.0 / 30.0
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
        let now = Date()
        refreshFaceCacheIfNeeded(now: now)

        if let cache = faceCache {
            context.draw(cache, in: bounds)
        } else {
            // First frame before the cache exists, or offscreen-context
            // creation failed (e.g. zero-size bounds) — fall back to a full
            // live render so something correct is always on screen.
            FormzeitRenderer.renderFace(context: context, bounds: bounds, now: now, isPreview: isPreview,
                                         defaults: settings, runStart: runStart)
        }
        FormzeitRenderer.renderHands(context: context, bounds: bounds, now: now, isPreview: isPreview,
                                      defaults: settings, runStart: runStart)
    }

    private func refreshFaceCacheIfNeeded(now: Date) {
        if faceCache != nil, bounds.size == faceCacheSize,
           now.timeIntervalSince(faceCacheGeneratedAt) < faceCacheRefreshInterval {
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = Int(bounds.width * scale), pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let offscreen = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        offscreen.scaleBy(x: scale, y: scale)

        FormzeitRenderer.renderFace(context: offscreen, bounds: bounds, now: now, isPreview: isPreview,
                                     defaults: settings, runStart: runStart)
        faceCache = offscreen.makeImage()
        faceCacheSize = bounds.size
        faceCacheGeneratedAt = now
    }

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let controller = ConfigureSheetController(defaults: settings)
        configController = controller
        return controller.window
    }
}
