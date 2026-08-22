import Cocoa

/// Strata (§5.1): three concentric hairline gauge arcs — seconds outermost,
/// then minutes, then hours — each running from nearly invisible at its
/// origin to full light at its head. Time is read as arc length. Cheapest
/// of the three v2 faces and the most legible at a distance.
enum StrataFace {

    static func render(context: CGContext, bounds: CGRect, lighting: DielLighting, wakeProgress: CGFloat,
                        time: ClassicFace.WallClock, movement: Movement, use24Hour: Bool) {
        context.setFillColor(lighting.field.cgColor)
        context.fill(bounds)

        let S = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let L = lighting.dim * wakeProgress

        let minuteFrac = Double(time.minute) + time.secondFraction / 60.0
        let hourSpan: Double = use24Hour ? 24.0 : 12.0
        let hourFrac = Double(time.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0
        let secondAngle = secondsAngleV2(secondFraction: time.secondFraction, movement: movement,
                                          reduceMotion: lighting.reduceMotion)
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi

        drawGauge(context: context, center: center, radius: 0.420 * S, S: S, head: secondAngle, light: lighting.light, L: L)
        drawGauge(context: context, center: center, radius: 0.360 * S, S: S, head: minuteAngle, light: lighting.light, L: L)
        drawGauge(context: context, center: center, radius: 0.300 * S, S: S, head: hourAngle, light: lighting.light, L: L)

        drawReadout(context: context, center: center, S: S, time: time, use24Hour: use24Hour, light: lighting.light, L: L)

        if let noise = sharedNoiseImage {
            context.saveGState()
            context.setAlpha(0.035)
            context.setBlendMode(.softLight)
            context.draw(noise, in: bounds)
            context.restoreGState()
        }
    }

    /// Track + accumulated tail ramp + head bloom for one arc. CG has no
    /// gradient along an arc, so the ramp is built from N nested strokes
    /// that all end at the head; the overlap sums to a smooth linear fade
    /// rather than the visible seams a per-segment alpha sweep would leave.
    private static func drawGauge(context: CGContext, center: CGPoint, radius: CGFloat, S: CGFloat, head: CGFloat,
                                   light: NSColor, L: CGFloat) {
        let lineWidth: CGFloat = 0.0040 * S // same weight on all three arcs — hierarchy comes from length
        // Clock angle (clockwise from 12) -> CoreGraphics angle (ccw from +x).
        let headCG = .pi / 2 - head

        context.saveGState()
        context.setLineCap(.round)

        // Track: the full unlit circle behind the arc.
        context.setLineWidth(lineWidth)
        context.setStrokeColor(light.withAlphaComponent(0.05 * L).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()

        // Tail ramp by accumulation.
        let N = 26
        let total: CGFloat = 2 * .pi
        context.setStrokeColor(light.withAlphaComponent(0.055 * L).cgColor)
        for k in 0..<N {
            let span = total * pow(1 - CGFloat(k) / CGFloat(N), 1.35)
            guard span > 0 else { continue }
            context.addArc(center: center, radius: radius, startAngle: headCG - span, endAngle: headCG, clockwise: false)
            context.strokePath()
        }

        // Head bloom — the only soft element.
        let headPoint = CGPoint(x: center.x + radius * cos(headCG), y: center.y + radius * sin(headCG))
        let bloomRadius = 0.014 * S
        let colors = [light.withAlphaComponent(0.8 * L).cgColor, light.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: headPoint, startRadius: 0,
                                        endCenter: headPoint, endRadius: bloomRadius, options: [])
        }
        context.restoreGState()
    }

    private static func drawReadout(context: CGContext, center: CGPoint, S: CGFloat, time: ClassicFace.WallClock,
                                     use24Hour: Bool, light: NSColor, L: CGFloat) {
        let hour = use24Hour ? time.hour : (time.hour % 12 == 0 ? 12 : time.hour % 12)
        let text = String(format: "%d:%02d", hour, time.minute)
        let fontSize = 0.20 * S
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .ultraLight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: light.withAlphaComponent(0.22 * L),
            .kern: 0.04 * fontSize,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
