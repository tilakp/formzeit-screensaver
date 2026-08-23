import Cocoa
import CoreText

/// Eclipse (§4): a matte plate occludes a field of light. Hands and marks
/// are cuts through the plate at one of four depths; what shows through is
/// the light behind. Nothing here animates aperture brightness directly —
/// it falls out of where the orbiting light source sits relative to each
/// cut, via the bevel/corona passes.
enum EclipseFace {

    static let R_FRACTION: CGFloat = 0.300 // R = 0.300 * S, deliberately smaller than Classic's 0.44

    struct Source {
        let position: CGPoint
        let color: NSColor
        let weight: CGFloat
    }

    // MARK: - Cached pass: field only (§4.5 steps 1-3)

    static func renderField(context: CGContext, bounds: CGRect, lighting: DielLighting, increaseContrast: Bool = false) {
        context.setFillColor(lighting.field.cgColor)
        context.fill(bounds)

        let S = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let sources = lightSources(center: center, S: S, lighting: lighting)

        for (i, source) in sources.enumerated() {
            // §9 increase-contrast: flatten the gradient to a single tone
            // rather than a soft day/night falloff.
            let stops: CFArray = increaseContrast
                ? [source.color.withAlphaComponent(0.35 * lighting.lum).cgColor,
                   source.color.withAlphaComponent(0.35 * lighting.lum).cgColor,
                   source.color.withAlphaComponent(0.0).cgColor] as CFArray
                : [source.color.withAlphaComponent(0.72 * lighting.lum).cgColor,
                   source.color.withAlphaComponent(0.24 * lighting.lum).cgColor,
                   source.color.withAlphaComponent(0.0).cgColor] as CFArray
            let locations: [CGFloat] = increaseContrast ? [0.0, 0.6, 1.0] : [0.0, 0.34, 1.0]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops,
                                             locations: locations) else { continue }
            context.saveGState()
            // Two lights add; they do not paint over each other.
            if i > 0 { context.setBlendMode(.plusLighter) }
            context.drawRadialGradient(gradient, startCenter: source.position, startRadius: 0,
                                        endCenter: source.position, endRadius: 0.95 * S, options: [])
            context.restoreGState()
        }

        if let noise = sharedNoiseImage {
            context.saveGState()
            context.setAlpha(0.035)
            context.setBlendMode(.softLight)
            context.draw(noise, in: bounds)
            context.restoreGState()
        }
    }

    private static func lightSources(center: CGPoint, S: CGFloat, lighting: DielLighting) -> [Source] {
        let isDuplex = lighting.light2 != nil
        var sources = [Source(position: DielLighting.sourcePosition(center: center, S: S, theta: lighting.sourceAngle),
                               color: vivid(lighting.light), weight: isDuplex ? 0.78 : 1.0)]
        if let light2 = lighting.light2, let theta2 = lighting.source2Angle {
            sources.append(Source(position: DielLighting.sourcePosition(center: center, S: S, theta: theta2),
                                   color: vivid(light2), weight: 0.74))
        }
        return sources
    }

    /// Eclipse-only chroma boost: the spec's diel/world/accent colours are
    /// tuned for a muted, "dark pixels are the material" read, but this
    /// face wants a punchier, more saturated glow. Scoped here rather than
    /// in `DielLighting` so Strata/Filament keep the original palette.
    /// Boosting in Oklab (not sRGB) keeps hue stable at high chroma instead
    /// of skewing toward whichever channel clips first.
    private static func vivid(_ color: NSColor, chroma: Double = 1.65) -> NSColor {
        var ok = toOklab(color)
        ok.a *= chroma
        ok.b *= chroma
        return fromOklab(ok)
    }

    // MARK: - Per-frame pass: plate + apertures + bevel + corona (§4.5 steps 4-15)

    static func renderPlate(context: CGContext, bounds: CGRect, lighting: DielLighting, elapsedRunTime: TimeInterval,
                            isPreview: Bool, time: ClassicFace.WallClock, movement: Movement, use24Hour: Bool,
                            showNumerals: Bool, increaseContrast: Bool = false) {
        let S = min(bounds.width, bounds.height)
        let R = R_FRACTION * S
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let L = lighting.dim

        let minuteFrac = Double(time.minute) + time.secondFraction / 60.0
        let hourSpan: Double = use24Hour ? 24.0 : 12.0
        let hourFrac = Double(time.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0
        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let secondAngle = secondsAngleV2(secondFraction: time.secondFraction, movement: movement,
                                          reduceMotion: lighting.reduceMotion)

        let sources = lightSources(center: center, S: S, lighting: lighting)
        // The plate is not the ground — it's a little brighter and more
        // colourful than a straight `lighting.plate` blend so it still
        // reads as an object catching the (now much more vivid) light,
        // not a flat cutout silhouette.
        let vividPlate = fromOklab(mix(toOklab(vivid(lighting.field, chroma: 1.35)), toOklab(sources[0].color), 0.14))
        let primaryU = unitVector(from: center, to: sources[0].position)
        // Through-cut cores sit off-centre from the light, the way a deep
        // slot's floor looks displaced from its mouth when viewed at an
        // angle (§4.6 parallax).
        let coreCenter = CGPoint(x: center.x - primaryU.dx * 0.0055 * R, y: center.y - primaryU.dy * 0.0055 * R)

        // §6: minute core blooms briefly right after the minute turns, hour
        // breath nudges overall luminance right after the hour turns — both
        // are just slow multipliers on values already computed. §9: both
        // are dropped outright under reduce-motion, not just slowed.
        let minuteBloom = lighting.reduceMotion ? 1.0 : 1.0 + 0.18 * (1 - easeOutCubic(min(time.secondFraction / 0.4, 1.0)))
        let hourBreath = lighting.reduceMotion ? 1.0 : 1.0 + 0.12 * (1 - easeOutCubic(min(minuteFrac / (2500.0 / 60000.0), 1.0)))
        let effectiveL = L * CGFloat(hourBreath)

        // §6 wake-in: the field/plate fade from black over the first
        // 1200ms; apertures fade in staggered 200ms behind that, so for a
        // brief moment only a blank lit plate is visible before its cuts
        // appear. §9: both are skipped outright under reduce-motion.
        let fieldProgress = wakeEase(elapsedRunTime: elapsedRunTime, delay: 0, duration: 1.2,
                                      isPreview: isPreview, reduceMotion: lighting.reduceMotion)
        let apertureProgress = wakeEase(elapsedRunTime: elapsedRunTime, delay: 0.2, duration: 1.0,
                                         isPreview: isPreview, reduceMotion: lighting.reduceMotion)

        let shallowPath = CGMutablePath()
        let deepPath = CGMutablePath()
        let throughPath = CGMutablePath()

        // Minute slots — 48 shallow radial hairlines.
        for i in 0..<60 where i % 5 != 0 {
            let theta = CGFloat(i) / 60.0 * 2 * .pi
            capsule(shallowPath, center, theta, 0.852 * R, 0.895 * R, 0.0030 * R, 0.0030 * R)
        }

        // Hour marks (1...11) + the Twelve double bar.
        for i in 0..<12 {
            let theta = CGFloat(i) / 12.0 * 2 * .pi
            if i == 0 {
                let outer = 0.900 * R, length = 0.100 * R, inner = outer - length
                for xOffset in [-0.0135 * R, 0.0135 * R] {
                    straightBar(deepPath, center, theta, xOffset, inner, outer, 0.0075 * R)
                    straightBar(throughPath, coreCenter, theta, xOffset, inner + 0.011 * R, outer - 0.011 * R, 0.0028 * R)
                }
            } else {
                let isQuarter = (i == 3 || i == 6 || i == 9)
                let outer = 0.900 * R, length = (isQuarter ? 0.100 : 0.086) * R, inner = outer - length
                capsule(deepPath, center, theta, inner, outer, 0.0105 * R, 0.0105 * R)
                let coreInner = inner + 0.012 * R, coreOuter = outer - 0.012 * R
                if coreOuter > coreInner {
                    capsule(throughPath, coreCenter, theta, coreInner, coreOuter, 0.0038 * R, 0.0038 * R)
                }
            }
        }

        // Hour hand: deep body + through core.
        capsule(deepPath, center, hourAngle, 0, 0.550 * R, 0.0360 * R, 0.0200 * R)
        capsule(throughPath, coreCenter, hourAngle, 0.100 * R, 0.505 * R, 0.0138 * R, 0.0058 * R)

        // Minute hand: deep body + through core, core briefly widened by the
        // minute-turn bloom.
        capsule(deepPath, center, minuteAngle, 0, 0.820 * R, 0.0280 * R, 0.0130 * R)
        capsule(throughPath, coreCenter, minuteAngle, 0.090 * R, 0.762 * R,
                0.0098 * R * CGFloat(minuteBloom), 0.0042 * R * CGFloat(minuteBloom))

        // Second needle: a single through-cut, no body — a wire of light.
        capsule(throughPath, coreCenter, secondAngle, -0.200 * R, 0.880 * R, 0.0052 * R, 0.0034 * R)
        // Counterweight, balancing the needle optically.
        capsule(deepPath, center, secondAngle, -0.210 * R, -0.130 * R, 0.0165 * R, 0.0150 * R)
        // Tip ring, threaded on the needle.
        let tipRingCenter = local(coreCenter, secondAngle, 0, 0.760 * R)
        throughPath.addEllipse(in: circleRect(tipRingCenter, 0.0300 * R))

        let allApertures = CGMutablePath()
        allApertures.addPath(shallowPath)
        allApertures.addPath(deepPath)
        allApertures.addPath(throughPath)

        context.saveGState()
        // Wake-in: the plate scales up from 0.94 as the screensaver starts.
        let plateScale = 0.94 + 0.06 * fieldProgress
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: plateScale, y: plateScale)
        context.translateBy(x: -center.x, y: -center.y)

        context.beginTransparencyLayer(auxiliaryInfo: nil)

        context.setBlendMode(.normal)
        context.setFillColor(vividPlate.cgColor)
        context.fillEllipse(in: circleRect(center, R))

        // destinationOut at partial alpha punches a partial cut — the cut
        // transmits part of the light behind rather than going fully
        // through. Winding fill (the default) so the lens where hour and
        // minute cuts overlap doesn't get double-punched by even-odd.
        context.setBlendMode(.destinationOut)
        // §9 increase-contrast: raise every aperture to full luminance
        // rather than the day/night falloff. Every depth is also scaled by
        // the staggered wake-in aperture reveal (1.0 once settled).
        let ap = Double(apertureProgress)
        context.setFillColor(CGColor(gray: 0, alpha: (increaseContrast ? 1.0 : 0.24) * ap))
        context.addPath(shallowPath)
        context.fillPath()

        context.setFillColor(CGColor(gray: 0, alpha: (increaseContrast ? 1.0 : 0.48) * ap))
        context.addPath(deepPath)
        context.fillPath()

        context.setFillColor(CGColor(gray: 0, alpha: ap))
        context.addPath(throughPath)
        context.fillPath()

        // Reseal the tip-ring centre — a ring threaded on the needle, not a
        // solid disc.
        context.setBlendMode(.normal)
        context.setFillColor(vividPlate.cgColor)
        context.fillEllipse(in: circleRect(tipRingCenter, 0.0185 * R))

        // Hub: score halo ring, then a small through collar re-sealed at
        // the centre — interleaved cut/reseal rather than a flat group fill.
        context.setBlendMode(.destinationOut)
        context.setFillColor(CGColor(gray: 0, alpha: 0.12))
        context.fillEllipse(in: circleRect(center, 0.078 * R))
        context.setBlendMode(.normal)
        context.setFillColor(vividPlate.cgColor)
        context.fillEllipse(in: circleRect(center, 0.056 * R))
        context.setBlendMode(.destinationOut)
        context.setFillColor(CGColor(gray: 0, alpha: 1.0))
        context.fillEllipse(in: circleRect(center, 0.034 * R))
        context.setBlendMode(.normal)
        context.setFillColor(vividPlate.cgColor)
        context.fillEllipse(in: circleRect(center, 0.020 * R))

        context.endTransparencyLayer()
        context.restoreGState()

        drawBevel(context: context, allApertures: allApertures, center: center, R: R, L: effectiveL,
                  primaryU: primaryU, sources: sources)
        drawCorona(context: context, center: center, R: R, S: S, L: effectiveL, sources: sources,
                   increaseContrast: increaseContrast)

        if showNumerals {
            drawNumerals(context: context, center: center, R: R, lighting: lighting, use24Hour: use24Hour)
        }

        // Wake-in veil: the whole composite (field cache + plate + hands)
        // fades up from black over `fieldProgress`, covering the full
        // bounds rather than just the plate so the cached field pass
        // underneath — which has no fade of its own — reads as fading too.
        if fieldProgress < 1 {
            context.saveGState()
            context.setBlendMode(.normal)
            context.setFillColor(CGColor(gray: 0, alpha: Double(1 - fieldProgress)))
            context.fill(bounds)
            context.restoreGState()
        }
    }

    private static func easeOutCubic(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    // MARK: - Bevel, corona (§4.6)

    private static func drawBevel(context: CGContext, allApertures: CGPath, center: CGPoint, R: CGFloat, L: CGFloat,
                                   primaryU: (dx: CGFloat, dy: CGFloat), sources: [Source]) {
        let bevel: CGFloat = 0.0042 * R
        context.saveGState()
        context.addPath(allApertures)
        context.clip()
        context.setLineWidth(0.0085 * R)

        for source in sources {
            let su = unitVector(from: center, to: source.position)
            context.saveGState()
            context.translateBy(x: su.dx * bevel, y: su.dy * bevel)
            context.setStrokeColor(source.color.withAlphaComponent(0.78 * L * source.weight).cgColor)
            context.addPath(allApertures)
            context.strokePath()
            context.restoreGState()
        }

        context.saveGState()
        context.translateBy(x: -primaryU.dx * bevel, y: -primaryU.dy * bevel)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.62))
        context.addPath(allApertures)
        context.strokePath()
        context.restoreGState()

        context.restoreGState()
    }

    private static func drawCorona(context: CGContext, center: CGPoint, R: CGFloat, S: CGFloat, L: CGFloat,
                                    sources: [Source], increaseContrast: Bool = false) {
        let segments = 64
        context.saveGState()
        context.setLineWidth((increaseContrast ? 0.003 : 0.0018) * S)
        context.setLineCap(.butt)

        for source in sources {
            let sourceAngle = clockAngle(from: center, to: source.position)
            for seg in 0..<segments {
                let a0 = CGFloat(seg) / CGFloat(segments) * 2 * .pi
                let a1 = CGFloat(seg + 1) / CGFloat(segments) * 2 * .pi
                let mid = (a0 + a1) / 2
                var angularDistance = abs(mid - sourceAngle).truncatingRemainder(dividingBy: 2 * .pi)
                if angularDistance > .pi { angularDistance = 2 * .pi - angularDistance }
                let prox = 1 - angularDistance / .pi
                let alpha = (0.16 + 0.60 * prox) * L * source.weight
                context.setStrokeColor(source.color.withAlphaComponent(alpha).cgColor)
                context.addArc(center: center, radius: R, startAngle: .pi / 2 - a0, endAngle: .pi / 2 - a1, clockwise: true)
                context.strokePath()
            }
        }

        context.setLineWidth(0.0011 * S)
        context.setStrokeColor(sources[0].color.withAlphaComponent(0.42 * L).cgColor)
        context.addArc(center: center, radius: 0.056 * R, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Numerals (optional, drawn ink rather than punched — §4.8)

    private static func drawNumerals(context: CGContext, center: CGPoint, R: CGFloat, lighting: DielLighting, use24Hour: Bool) {
        let fontSize = R * 0.075
        let font = ClassicFace.numeralFont(size: fontSize, medium: true)
        let color = lighting.light.withAlphaComponent(0.55 * lighting.dim)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let placementRadius = R * 0.965

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

// MARK: - Shared geometry helpers (used by Eclipse; Strata/Filament have their own simpler shapes)

func circleRect(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
}

func unitVector(from a: CGPoint, to b: CGPoint) -> (dx: CGFloat, dy: CGFloat) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = sqrt(dx * dx + dy * dy)
    guard len > 0 else { return (0, -1) }
    return (dx / len, dy / len)
}

/// Clock angle (clockwise from 12 o'clock, radians) of `p` as seen from `c`.
func clockAngle(from c: CGPoint, to p: CGPoint) -> CGFloat {
    atan2(p.x - c.x, p.y - c.y)
}

/// Tapered capsule from y0 (half-width w0) to y1 (half-width w1), round both
/// ends. `theta` is a clock angle (clockwise from 12); `x` lateral, `y`
/// outward in the rotated local frame (§2.2).
func capsule(_ path: CGMutablePath, _ c: CGPoint, _ theta: CGFloat,
             _ y0: CGFloat, _ y1: CGFloat, _ w0: CGFloat, _ w1: CGFloat) {
    let a  = local(c, theta, -w0, y0)
    let b  = local(c, theta, -w1, y1)
    let d  = local(c, theta,  w0, y0)
    let ct = local(c, theta,   0, y1)
    let cb = local(c, theta,   0, y0)
    path.move(to: a)
    path.addLine(to: b)
    path.addArc(center: ct, radius: w1, startAngle: .pi / 2 + theta, endAngle: -.pi / 2 + theta, clockwise: true)
    path.addLine(to: d)
    path.addArc(center: cb, radius: w0, startAngle: -.pi / 2 + theta, endAngle: .pi / 2 + theta, clockwise: true)
    path.closeSubpath()
}

/// Straight (non-rounded) bar offset laterally by `xOffset` — used for the
/// Twelve mark's double bar, which reads cleaner with square ends than the
/// capsule the other eleven marks use.
func straightBar(_ path: CGMutablePath, _ c: CGPoint, _ theta: CGFloat, _ xOffset: CGFloat,
                  _ y0: CGFloat, _ y1: CGFloat, _ halfWidth: CGFloat) {
    guard y1 > y0 else { return }
    path.move(to: local(c, theta, xOffset - halfWidth, y0))
    path.addLine(to: local(c, theta, xOffset - halfWidth, y1))
    path.addLine(to: local(c, theta, xOffset + halfWidth, y1))
    path.addLine(to: local(c, theta, xOffset + halfWidth, y0))
    path.closeSubpath()
}

/// v2 movement styles (§6.1-6.2). Classic keeps its own original
/// exp·sin quartz overshoot unchanged; Eclipse/Strata/Filament use the
/// damped-spring step response instead.
///
/// §9: reduce-motion forces discrete 1Hz stepping regardless of the chosen
/// movement — the quartz spring and the continuous sweep are both motion
/// effects, not just decoration.
func secondsAngleV2(secondFraction: Double, movement: Movement, reduceMotion: Bool = false) -> CGFloat {
    guard !reduceMotion else {
        return CGFloat(floor(secondFraction) / 60.0) * 2 * .pi
    }
    switch movement {
    case .digital: // displayed "Sweep"
        return CGFloat(secondFraction / 60.0) * 2 * .pi

    case .mechanical:
        let steps = 8.0
        let stepped = (secondFraction * steps).rounded(.down) / steps
        return CGFloat(stepped / 60.0) * 2 * .pi

    case .quartz:
        let baseSecond = floor(secondFraction)
        let target = CGFloat(baseSecond / 60.0) * 2 * .pi
        let t = secondFraction - baseSecond
        guard t < 0.35 else { return target }
        let zeta = 0.28, omega = 46.0
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let env = exp(-zeta * omega * t)
        let tickStep = 2 * Double.pi / 60.0
        let disp = -tickStep * env * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
        return target + CGFloat(disp)
    }
}
