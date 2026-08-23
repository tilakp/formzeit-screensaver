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

    /// §9: read live, not just at launch. FormzeitView also observes
    /// NSWorkspace's accessibility-options notification to invalidate the
    /// Eclipse field cache when these change, but every frame reads them
    /// directly here too, so a change is never more than one frame stale.
    static func reduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func increaseContrast() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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
