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

    static func render(context: CGContext, bounds: CGRect, lighting: DielLighting, wakeProgress: CGFloat,
                        time: ClassicFace.WallClock, movement: Movement, use24Hour: Bool, showNumerals: Bool) {
        context.setFillColor(lighting.field.cgColor)
        context.fill(bounds)

        let S = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let L = lighting.dim * wakeProgress
        let breatheT = Date().timeIntervalSinceReferenceDate

        let minuteFrac = Double(time.minute) + time.secondFraction / 60.0
        let hourSpan: Double = use24Hour ? 24.0 : 12.0
        let hourFrac = Double(time.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi

        context.saveGState()
        context.setLineCap(.butt)

        // Sixty second-filaments: the current second's comet plus a low
        // breathing base glow on every one, so the ring never goes fully dark.
        for i in 0..<60 {
            let theta = CGFloat(i) / 60.0 * 2 * .pi
            var delta = time.secondFraction - Double(i)
            delta = delta.truncatingRemainder(dividingBy: 60)
            if delta < 0 { delta += 60 }
            let igniteAlpha = exp(-delta / tau)
            let baseGlow = 0.085 + 0.025 * sin(breatheT / 9.0 + Double(i) * 0.21)
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

        // Minute filament: steady mid glow, reaching further inward than
        // the second ring.
        context.setLineWidth(0.0030 * S)
        context.setStrokeColor(lighting.light.withAlphaComponent(0.45 * L).cgColor)
        context.move(to: local(center, minuteAngle, 0, 0.300 * S))
        context.addLine(to: local(center, minuteAngle, 0, ringOuter * S))
        context.strokePath()

        // Hour filament: a single long filament reaching in near the centre.
        context.setLineWidth(0.0038 * S)
        context.setStrokeColor(lighting.light.withAlphaComponent(0.80 * L).cgColor)
        context.move(to: local(center, hourAngle, 0, 0.100 * S))
        context.addLine(to: local(center, hourAngle, 0, 0.290 * S))
        context.strokePath()

        context.restoreGState()

        if showNumerals {
            drawNumerals(context: context, center: center, S: S, lighting: lighting, use24Hour: use24Hour)
        }

        if let noise = sharedNoiseImage {
            context.saveGState()
            context.setAlpha(0.035)
            context.setBlendMode(.softLight)
            context.draw(noise, in: bounds)
            context.restoreGState()
        }
    }

    private static func drawNumerals(context: CGContext, center: CGPoint, S: CGFloat, lighting: DielLighting, use24Hour: Bool) {
        let fontSize = S * 0.045
        let font = ClassicFace.numeralFont(size: fontSize, medium: true)
        let color = lighting.light.withAlphaComponent(0.5 * lighting.dim)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let placementRadius = ringOuter * S + fiveMinuteExtra * S + fontSize * 0.9

        for i in 0..<12 {
            let angle: CGFloat = .pi / 2 - CGFloat(i) / 12.0 * 2 * .pi
            let point = CGPoint(x: center.x + placementRadius * cos(angle), y: center.y + placementRadius * sin(angle))
            let value = use24Hour ? i * 2 : (i == 0 ? 12 : i)
            let str = NSAttributedString(string: String(value), attributes: attrs)
            let size = str.size()
            str.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        }
    }
}
