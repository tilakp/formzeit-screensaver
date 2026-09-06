import Cocoa

/// Filament (§5.2): sixty radial filaments, one per second. The current
/// second ignites its filament to full; each decays over ~6s, so a short
/// comet rotates once a minute. The minute holds a steady mid glow; the
/// hour is a single long filament reaching inward. Every filament carries a
/// low base glow that breathes. The most hypnotic of the three faces and
/// the weakest as a clock — ships with numerals on by default.
enum FilamentFace {

    private static let tau = 6.0
    private static let ringInner: CGFloat = 0.340
    private static let ringOuter: CGFloat = 0.440
    private static let filamentWeight: CGFloat = 0.0026
    private static let fiveMinuteExtra: CGFloat = 0.012

    /// Shared inner radius for the hour and minute filaments — they read as
    /// two hands from one hub only if they actually converge on a point;
    /// giving them independent inner radii (the original 0.100/0.300 split)
    /// left them in disjoint bands with nothing in common to anchor a clock
    /// gestalt.
    private static let handPivot: CGFloat = 0.100
    /// Minute and hour must clearly outrank the current second's comet, or
    /// the eye is pulled to the one filament that carries no time
    /// information. The comet's peak is scaled down below both.
    private static let cometPeakScale: CGFloat = 0.55
    /// Legibility floors for the two elements that actually tell the time,
    /// so the diel night dim can crush the decorative comet/glow toward
    /// black without taking the hands with it (mirrors Strata's readout floor).
    private static let hourFloor: CGFloat = 0.22
    private static let minuteFloor: CGFloat = 0.17

    static func render(context: CGContext, bounds: CGRect, now: Date, lighting: DielLighting, wakeProgress: CGFloat,
                        time: ClassicFace.WallClock, movement: Movement, use24Hour: Bool, showNumerals: Bool) {
        context.setFillColor(lighting.field.cgColor)
        context.fill(bounds)

        let S = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let L = lighting.dim * wakeProgress
        let reduceMotion = lighting.reduceMotion
        // `now`, not a fresh `Date()`: keeps this deterministic for a given
        // pinned frame (TestHarness/Audit/settings-sheet thumbnails), like
        // every other time source in the renderer.
        let breatheT = now.timeIntervalSinceReferenceDate

        let minuteFrac = Double(time.minute) + time.secondFraction / 60.0
        let hourSpan: Double = use24Hour ? 24.0 : 12.0
        let hourFrac = Double(time.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi

        context.saveGState()
        context.setLineCap(.butt)

        // Sixty second-filaments: the current second's comet plus a low
        // breathing base glow on every one, so the ring never goes fully dark.
        // Reduce Motion: no breathing pulse, and the comet's smooth ~6s decay
        // collapses to a single lit tick for the current second, like the
        // discrete-tick fallback other faces use for their second hand.
        for i in 0..<60 {
            let theta = CGFloat(i) / 60.0 * 2 * .pi
            var delta = time.secondFraction - Double(i)
            delta = delta.truncatingRemainder(dividingBy: 60)
            if delta < 0 { delta += 60 }
            let igniteAlpha = reduceMotion ? (delta < 1.0 ? 1.0 : 0.0) : exp(-delta / tau) * Double(cometPeakScale)
            let baseGlow = reduceMotion ? 0.085 : 0.085 + 0.025 * sin(breatheT / 9.0 + Double(i) * 0.21)
            let alpha = CGFloat(max(igniteAlpha, baseGlow)) * L

            let isFive = i % 5 == 0
            let outer = (ringOuter + (isFive ? fiveMinuteExtra : 0)) * S
            let inner = ringInner * S

            context.setLineWidth(filamentWeight * S)
            context.setStrokeColor(lighting.light.withAlphaComponent(alpha).cgColor)
            context.move(to: local(center, theta, 0, inner))
            context.addLine(to: local(center, theta, 0, outer))
            context.strokePath()
        }

        // Minute filament: steady mid glow, sharing the hour filament's inner
        // radius so both read as hands from one hub, reaching further out
        // than the hour into the second ring.
        context.setLineWidth(0.0030 * S)
        context.setStrokeColor(lighting.light.withAlphaComponent(max(0.65 * L, minuteFloor)).cgColor)
        context.move(to: local(center, minuteAngle, 0, handPivot * S))
        context.addLine(to: local(center, minuteAngle, 0, ringOuter * S))
        context.strokePath()

        // Hour filament: shorter and thicker, from the same pivot.
        context.setLineWidth(0.0038 * S)
        context.setStrokeColor(lighting.light.withAlphaComponent(max(0.80 * L, hourFloor)).cgColor)
        context.move(to: local(center, hourAngle, 0, handPivot * S))
        context.addLine(to: local(center, hourAngle, 0, 0.290 * S))
        context.strokePath()

        context.restoreGState()

        if showNumerals {
            drawNumerals(context: context, center: center, S: S, lighting: lighting, L: L, use24Hour: use24Hour)
        }

        if let noise = sharedNoiseImage {
            context.saveGState()
            context.setAlpha(0.035)
            context.setBlendMode(.softLight)
            context.draw(noise, in: bounds)
            context.restoreGState()
        }
    }

    /// `NSAttributedString.draw(at:)` silently no-ops with no current
    /// `NSGraphicsContext`, which is true of the per-frame hands-layer pass
    /// (see `HandsLayerDelegate` in FormzeitView.swift) — so these never
    /// actually appeared on screen. Draws through `CTLineDraw` instead, same
    /// as Classic/Eclipse/Strata. The placement radius is also clamped by
    /// the font's own cap-height so 12 and 6 can't overflow the top/bottom
    /// edge, which `S = min(width, height)` makes the tightest fit.
    private static func drawNumerals(context: CGContext, center: CGPoint, S: CGFloat, lighting: DielLighting, L: CGFloat, use24Hour: Bool) {
        let fontSize = S * 0.045
        let font = ClassicFace.numeralFont(size: fontSize, medium: true)
        let color = lighting.light.withAlphaComponent(0.5 * L)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let maxRadius = 0.5 * S - font.capHeight
        let placementRadius = min(ringOuter * S + fiveMinuteExtra * S + fontSize * 0.9, maxRadius)

        for i in 0..<12 {
            let angle: CGFloat = .pi / 2 - CGFloat(i) / 12.0 * 2 * .pi
            let point = CGPoint(x: center.x + placementRadius * cos(angle), y: center.y + placementRadius * sin(angle))
            let value = use24Hour ? i * 2 : (i == 0 ? 12 : i)
            let str = NSAttributedString(string: String(value), attributes: attrs)
            let line = CTLineCreateWithAttributedString(str)
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard !ink.isNull else { continue }

            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -ink.midX, y: -font.capHeight / 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
