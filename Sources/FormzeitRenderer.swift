import Cocoa

/// Dispatches rendering to whichever face is selected in settings. Eclipse,
/// Strata, and Filament share `DielLighting` (Lighting.swift, §3); Classic
/// keeps its own independent lighting model, unchanged from v1.
enum FormzeitRenderer {

    static func render(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                        defaults: FormzeitDefaults) {
        renderFace(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)
        renderHands(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)
    }

    /// Cached pass: whatever changes almost imperceptibly frame to frame.
    /// Classic draws its bezel/texture/ticks/numerals here, as before.
    /// Eclipse draws only the field gradient here — the plate and every
    /// aperture moved into the per-frame pass, since they're all cut from
    /// the same surface and the light source orbits continuously (§8).
    /// Strata/Filament have no expensive/cheap split of their own (both are
    /// simple strokes, cheap to redraw whole every frame), so this is a
    /// no-op for them.
    static func renderFace(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                            defaults: FormzeitDefaults) {
        switch defaults.face {
        case .bauhaus:
            BauhausFace.renderFace(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                    isPreview: isPreview, defaults: defaults)
        case .classic:
            ClassicFace.renderFace(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                    isPreview: isPreview, defaults: defaults)
        case .eclipse:
            let lighting = DielLighting(now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                         reduceMotion: reduceMotion(), defaults: defaults)
            EclipseFace.renderField(context: context, bounds: bounds, lighting: lighting, increaseContrast: increaseContrast())
        case .strata, .filament:
            break
        }
    }

    /// Per-frame pass: whatever must be redrawn every animation tick.
    static func renderHands(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                             defaults: FormzeitDefaults) {
        let time = ClassicFace.wallClock(now)
        let reduceMotion = self.reduceMotion()

        switch defaults.face {
        case .bauhaus:
            BauhausFace.renderHands(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                     isPreview: isPreview, defaults: defaults, reduceMotion: reduceMotion)

        case .classic:
            let lighting = DielLighting(now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                         reduceMotion: reduceMotion, defaults: defaults)
            ClassicFace.renderHands(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime,
                                     isPreview: isPreview, defaults: defaults,
                                     accent: resolvedClassicAccent(defaults: defaults, lighting: lighting))

        case .eclipse:
            let lighting = DielLighting(now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                         reduceMotion: reduceMotion, defaults: defaults)
            EclipseFace.renderPlate(context: context, bounds: bounds, lighting: lighting,
                                     elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                     time: time, movement: defaults.movement, use24Hour: defaults.use24Hour,
                                     showNumerals: defaults.showNumerals, increaseContrast: increaseContrast())

        case .strata:
            let lighting = DielLighting(now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                         reduceMotion: reduceMotion, defaults: defaults)
            StrataFace.render(context: context, bounds: bounds, lighting: lighting,
                               wakeProgress: wakeEase(elapsedRunTime: elapsedRunTime, delay: 0, duration: 1.2, isPreview: isPreview),
                               time: time, movement: defaults.movement, use24Hour: defaults.use24Hour)

        case .filament:
            let lighting = DielLighting(now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview,
                                         reduceMotion: reduceMotion, defaults: defaults)
            FilamentFace.render(context: context, bounds: bounds, lighting: lighting,
                                 wakeProgress: wakeEase(elapsedRunTime: elapsedRunTime, delay: 0, duration: 1.2, isPreview: isPreview),
                                 time: time, movement: defaults.movement, use24Hour: defaults.use24Hour,
                                 showNumerals: defaults.showNumerals)
        }
    }

    // §9 accessibility flags, cached.
    //
    // These used to be read straight off NSWorkspace on every call — but the
    // face pass runs on a background queue, and NSWorkspace is not documented
    // thread-safe. They're now refreshed on the main thread (at view setup
    // and from NSWorkspace's accessibility-changed notification) and only
    // read from here, so nothing touches AppKit off-main.
    private static var cachedReduceMotion = false
    private static var cachedIncreaseContrast = false

    /// Must be called on the main thread.
    static func refreshAccessibilityFlags() {
        cachedReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cachedIncreaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func reduceMotion() -> Bool { cachedReduceMotion }
    static func increaseContrast() -> Bool { cachedIncreaseContrast }

    /// A cheap hash of everything that can change what a frame looks like,
    /// with each moving element quantised to about half a point of tip
    /// travel. `FormzeitView` skips the redraw when this is unchanged.
    ///
    /// This is what makes 30fps affordable: with a stepped movement most
    /// consecutive frames are pixel-identical, and a full redraw at 5K costs
    /// real CPU. A continuous sweep still changes every frame and so still
    /// redraws every frame — the quantisation decides that, not a per-style
    /// special case.
    static func frameFingerprint(now: Date, elapsedRunTime: TimeInterval,
                                  bounds: CGRect, defaults: FormzeitDefaults) -> Int {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return 0 }
        let R = side * 0.44
        // Angular step that moves a tip at radius R by ~0.5pt.
        let step = 0.5 / max(R, 1)

        let t = ClassicFace.wallClock(now)
        let minuteFrac = Double(t.minute) + t.secondFraction / 60.0
        let hourSpan: Double = defaults.use24Hour ? 24.0 : 12.0
        let hourFrac = Double(t.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0
        let second = secondsAngleV2(secondFraction: t.secondFraction, movement: defaults.movement,
                                     reduceMotion: reduceMotion())

        func q(_ radians: Double) -> Int { Int((radians / Double(step)).rounded()) }

        var hasher = Hasher()
        hasher.combine(q(hourFrac / hourSpan * 2 * .pi))
        hasher.combine(q(minuteFrac / 60.0 * 2 * .pi))
        hasher.combine(q(Double(second)))
        // Drift and the idle dim ramp both crawl; a 2s bucket keeps them
        // under a device pixel while still letting them advance.
        hasher.combine(Int(now.timeIntervalSinceReferenceDate / 2))
        hasher.combine(Int(elapsedRunTime / 2))
        hasher.combine(defaults.face.rawValue)
        return hasher.finalize()
    }

    /// Classic's second hand/hub color now comes from the shared v2 accent
    /// system: a fixed hex, or — for Adaptive — the current diel light
    /// color, so Classic quietly picks up the day/night color drift too.
    private static func resolvedClassicAccent(defaults: FormzeitDefaults, lighting: DielLighting) -> NSColor {
        if let hex = defaults.accentV2.hex {
            return NSColor(hex: hex)
        }
        return lighting.light
    }
}
