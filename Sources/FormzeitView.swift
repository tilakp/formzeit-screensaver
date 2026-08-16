import ScreenSaver
import Cocoa

@objc(FormzeitView)
public final class FormzeitView: ScreenSaverView {

    private let settings = FormzeitDefaults()
    private var configController: ConfigureSheetController?

    // Elapsed run time (for the burn-in idle-dim ramp) is measured against
    // ProcessInfo.systemUptime, a monotonic clock, not Date. A wall clock can
    // step backward — NTP correction, sleep/wake drift, a manual time change
    // — and on something meant to run unattended for hours that's not
    // hypothetical: a backward Date step here used to be able to snap
    // dimming back to full brightness, the opposite of what burn-in
    // protection is for. See Lighting's doc comment in FormzeitRenderer.
    private var runStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    // The face (bezel/texture/ticks/numerals) barely changes frame to frame
    // — drift moves it a fraction of a pixel per second, dimming ramps over
    // minutes — but rendering it is the expensive part (soft shadows and a
    // blended noise texture): measured at ~1.4s on a 5K display, ~1.9s on a
    // Pro Display XDR, at native resolution. Redrawing it from scratch on
    // every animation tick was pegging a full CPU core; regenerating it
    // synchronously on the main thread even every few seconds is a
    // multi-second stutter on real Retina hardware. Both mistakes had the
    // same fix available and I only found it the second time: render it on
    // a background queue and swap the finished bitmap in on the main thread.
    // The old cache stays on screen (still valid — nothing here changes
    // fast) until the new one is ready, so the main thread never blocks on
    // this at all.
    private var faceCache: CGImage?
    private var faceCacheSize: NSSize = .zero
    private var faceCacheScale: CGFloat = 0
    private var faceCacheGeneratedAtUptime: TimeInterval = -.infinity
    private var isRegeneratingFaceCache = false
    // Cheap now that regeneration doesn't block the main thread — mainly
    // bounds how long a settings change (24-hour toggle, accent color, night
    // dimming) takes to reach the face layer, since those only affect
    // renderFace(); hands react to settings instantly either way.
    private let faceCacheRefreshInterval: TimeInterval = 1.5

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
        runStartUptime = ProcessInfo.processInfo.systemUptime
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
        let elapsedRunTime = ProcessInfo.processInfo.systemUptime - runStartUptime
        requestFaceCacheRefreshIfNeeded(now: now)

        if let cache = faceCache {
            context.draw(cache, in: bounds)
        } else {
            // First frame before the cache exists, or offscreen-context
            // creation failed (e.g. zero-size bounds) — fall back to a full
            // live render so something correct is always on screen. This is
            // the only case where the expensive face pass can still cost a
            // frame on the main thread, and it only happens once.
            FormzeitRenderer.renderFace(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                         isPreview: isPreview, defaults: settings)
        }
        FormzeitRenderer.renderHands(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                      isPreview: isPreview, defaults: settings)
    }

    private func requestFaceCacheRefreshIfNeeded(now: Date) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let nowUptime = ProcessInfo.processInfo.systemUptime

        if faceCache != nil, bounds.size == faceCacheSize, scale == faceCacheScale,
           nowUptime - faceCacheGeneratedAtUptime < faceCacheRefreshInterval {
            return
        }
        guard !isRegeneratingFaceCache else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }

        isRegeneratingFaceCache = true
        let boundsSnapshot = bounds
        let elapsedRunTime = nowUptime - runStartUptime
        let isPreviewSnapshot = isPreview
        // FormzeitDefaults reads through UserDefaults, which is safe to read
        // from a background thread; nothing here is mutated off the main
        // thread.
        let defaultsSnapshot = settings

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.renderFaceImage(bounds: boundsSnapshot, scale: scale, now: now,
                                              elapsedRunTime: elapsedRunTime, isPreview: isPreviewSnapshot,
                                              defaults: defaultsSnapshot)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let image = image {
                    self.faceCache = image
                    self.faceCacheSize = boundsSnapshot.size
                    self.faceCacheScale = scale
                    self.faceCacheGeneratedAtUptime = nowUptime
                }
                self.isRegeneratingFaceCache = false
                self.needsDisplay = true
            }
        }
    }

    private static func renderFaceImage(bounds: NSRect, scale: CGFloat, now: Date, elapsedRunTime: TimeInterval,
                                         isPreview: Bool, defaults: FormzeitDefaults) -> CGImage? {
        let pixelWidth = Int(bounds.width * scale), pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let offscreen = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        offscreen.scaleBy(x: scale, y: scale)
        FormzeitRenderer.renderFace(context: offscreen, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                     isPreview: isPreview, defaults: defaults)
        return offscreen.makeImage()
    }

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let controller = ConfigureSheetController(defaults: settings)
        configController = controller
        return controller.window
    }
}
