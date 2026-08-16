import Cocoa
import CoreText

enum FormzeitRenderer {

    // MARK: - Entry points
    //
    // Rendering is split into two passes with very different costs and very
    // different actual rates of change:
    //
    //  - renderFace: bezel, dial texture, ticks, numerals. Nothing here
    //    changes except drift (moves a fraction of a pixel per second) and
    //    dim/glow (ramps over minutes). Measured at ~250ms for a full pass
    //    on a 1800px canvas — dominated by the noise-texture blend and half
    //    a dozen soft shadows — because CGContext shadows and non-normal
    //    blend modes are inherently expensive to rasterize.
    //  - renderHands: hour/minute/second hands + hub. This is the only part
    //    that must be redrawn every animation frame.
    //
    // FormzeitView caches a renderFace bitmap and only regenerates it on a
    // multi-second interval, compositing it each frame and drawing fresh
    // hands on top. Redrawing the full scene from scratch on every
    // animateOneFrame() tick — as a single combined render() used to do —
    // meant paying the ~250ms face cost 60 times a second, which is exactly
    // why the host process was pegging a core: it wasn't idling between
    // frames, it was continuously behind, always mid-frame.
    //
    // render() below still does both in one call, for the audit tool and
    // test harness, where a single deterministic frame is all that's needed
    // and the cost of one frame doesn't matter.

    static func render(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                        defaults: FormzeitDefaults) {
        renderFace(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)
        renderHands(context: context, bounds: bounds, now: now, elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)
    }

    /// Background, bezel, dial texture, ticks, and numerals — everything
    /// that doesn't need to be redrawn every frame. Fully opaque (the
    /// background fill is included) so a cached copy of this pass can be
    /// blitted straight over whatever was on screen with no alpha
    /// compositing, and hands drawn on top of that each frame.
    static func renderFace(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                            defaults: FormzeitDefaults) {
        context.setFillColor(DialPalette.background.cgColor)
        context.fill(bounds)

        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side * 0.44

        let lighting = Lighting(now: now, isPreview: isPreview, elapsedRunTime: elapsedRunTime, defaults: defaults)
        let drift = driftOffset(now: now, isPreview: isPreview, side: side, defaults: defaults)

        context.saveGState()
        context.translateBy(x: drift.dx, y: drift.dy)

        let dim = lighting.dim
        drawBezel(context: context, center: center, radius: radius, dim: dim)
        drawFace(context: context, center: center, radius: radius, dim: dim)
        drawTicks(context: context, center: center, radius: radius, lighting: lighting)
        drawNumerals(context: context, center: center, radius: radius, lighting: lighting, use24Hour: defaults.use24Hour)

        context.restoreGState()
    }

    /// Hands + hub only — the one part redrawn every animation frame.
    /// Computes drift/lighting fresh rather than reusing whatever a cached
    /// face pass used: both move slowly enough (drift: fractions of a pixel
    /// per second; dim/glow: ramps over minutes) that the mismatch between a
    /// several-second-old cached face and a live hands pass is never
    /// visible, so there's no need to thread cached values through.
    static func renderHands(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval, isPreview: Bool,
                             defaults: FormzeitDefaults) {
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side * 0.44

        let lighting = Lighting(now: now, isPreview: isPreview, elapsedRunTime: elapsedRunTime, defaults: defaults)
        let drift = driftOffset(now: now, isPreview: isPreview, side: side, defaults: defaults)

        context.saveGState()
        context.translateBy(x: drift.dx, y: drift.dy)

        let time = wallClock(now)
        drawHands(context: context, center: center, radius: radius, lighting: lighting, time: time,
                   movement: defaults.movement, accent: defaults.accent.color, use24Hour: defaults.use24Hour)

        context.restoreGState()
    }

    // MARK: - Time

    private struct WallClock {
        var hour: Int
        var minute: Int
        var secondFraction: Double // 0..<60, includes sub-second precision
    }

    private static func wallClock(_ date: Date) -> WallClock {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let sec = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1_000_000_000.0
        return WallClock(hour: c.hour ?? 0, minute: c.minute ?? 0, secondFraction: sec)
    }

    // MARK: - Burn-in mitigation

    /// Slow organic drift of the entire composition, built from a few
    /// incommensurate sine waves so the path never visibly repeats over any
    /// reasonable viewing session, yet stays smooth frame to frame. Disabled
    /// for the System Settings preview thumbnail so it reads crisply.
    private static func driftOffset(now: Date, isPreview: Bool, side: CGFloat,
                                     defaults: FormzeitDefaults) -> (dx: CGFloat, dy: CGFloat) {
        guard defaults.burnInProtection, !isPreview else { return (0, 0) }
        let t = now.timeIntervalSinceReferenceDate
        let scale = side / 1600.0 // full swing tuned for a 1600pt-wide display
        let dx = (14 * sin(t * 0.0210) + 6 * sin(t * 0.0073 + 0.4)) * scale
        let dy = (12 * sin(t * 0.0170 + 1.3) + 5 * sin(t * 0.0051 + 0.7)) * scale
        return (CGFloat(dx), CGFloat(dy))
    }

    /// Bundles the two lighting quantities every element needs:
    ///  - `dim`: overall multiplicative brightness (night curve × idle ramp,
    ///    floored so the face never goes fully dark)
    ///  - `glow`: 0 by day, ramping to 1 at full night. Elements use this to
    ///    fade from a plain black drop shadow (day) to a soft colored bloom
    ///    (night) — see `mixedShadow` below.
    struct Lighting {
        let dim: CGFloat
        let glow: CGFloat

        /// Two independent, multiplicative dimming curves feed `dim`:
        ///  - a smooth night curve (dims 22:00–07:00, ~30min ease at each edge)
        ///  - a slow idle ramp so a screensaver left running for a long
        ///    unattended stretch keeps lowering luminance rather than holding a
        ///    bright static-ish image indefinitely.
        /// Never dims below a floor — this stays legible as an always-on clock.
        ///
        /// `elapsedRunTime` must come from a monotonic clock (e.g.
        /// `ProcessInfo.processInfo.systemUptime`), not `Date` subtraction —
        /// a wall clock can step backward (NTP correction, sleep/wake drift,
        /// a manual time change), and on a screensaver meant to run
        /// unattended for hours that's not a hypothetical. A backward step
        /// on `Date`-based elapsed time here would snap dimming back to full
        /// brightness, the opposite of what burn-in protection is for.
        /// `now` (wall-clock) is still correct and required for the
        /// night-window check just below, which genuinely needs calendar
        /// time, not elapsed time.
        init(now: Date, isPreview: Bool, elapsedRunTime: TimeInterval, defaults: FormzeitDefaults) {
            guard !isPreview else { dim = 1.0; glow = 0.0; return }

            var factor: CGFloat = 1.0
            var nightGlow: CGFloat = 0.0

            if defaults.nightDimming {
                let cal = Calendar.current
                let c = cal.dateComponents([.hour, .minute], from: now)
                let minutesOfDay = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
                let night = nightFactor(minutesOfDay: minutesOfDay)
                factor *= CGFloat(night)
                let nightLevel = 0.55
                nightGlow = CGFloat((1.0 - night) / (1.0 - nightLevel))
            }

            if defaults.burnInProtection {
                let elapsed = elapsedRunTime
                let rampStart = 300.0   // start easing off after 5 minutes
                let rampEnd = 1800.0    // reach floor by 30 minutes
                let floor = 0.45
                if elapsed > rampStart {
                    let p = min(1.0, (elapsed - rampStart) / (rampEnd - rampStart))
                    let eased = smoothstep(p)
                    factor *= CGFloat(1.0 - eased * (1.0 - floor))
                }
            }

            dim = max(factor, 0.22)
            glow = min(max(nightGlow, 0), 1)
        }
    }

    /// A shadow that reads as a plain contact shadow by day and eases into a
    /// soft colored bloom at night, unified into one CGContext shadow call.
    ///
    /// CGContext's shadow blur is a software rasterization whose cost scales
    /// worse than linearly with radius — measured at ~2.7ms/frame for the
    /// hands pass at the day blur (0.03R) versus ~38ms/frame at the glow
    /// blur this used to use (0.20R), a 14x cost jump for a 6.7x radius
    /// increase. Since the glow is exactly the effect meant to run for hours
    /// unattended overnight, that made the screensaver specifically expensive
    /// at the one time it's most likely to be left running. 0.08R keeps a
    /// real, visible soft bloom at a measured ~9ms/frame.
    private static func mixedShadow(color: NSColor, radius: CGFloat, glow: CGFloat) -> (blur: CGFloat, color: CGColor) {
        let dropBlur = radius * 0.03
        let glowBlur = radius * 0.08
        let blur = dropBlur + (glowBlur - dropBlur) * glow
        let dayColor = NSColor.black.withAlphaComponent(0.45)
        let nightColor = color.withAlphaComponent(0.95)
        let mixed = dayColor.blended(withFraction: glow, of: nightColor) ?? dayColor
        return (blur, mixed.cgColor)
    }

    /// 1.0 during the day, ~0.55 at night, smoothstepped across a 30-minute
    /// window centered on 22:00 and 07:00 so the transition is never noticed
    /// as a jump.
    private static func nightFactor(minutesOfDay: Double) -> Double {
        let nightLevel = 0.55
        let windowStart = 22.0 * 60.0
        let windowEnd = 7.0 * 60.0 + 24.0 * 60.0
        var m = minutesOfDay
        if m < 12 * 60 { m += 24 * 60 } // unwrap past-midnight hours onto the same ramp
        let halfEase = 15.0 // minutes
        if m < windowStart - halfEase { return 1.0 }
        if m < windowStart + halfEase {
            let p = (m - (windowStart - halfEase)) / (2 * halfEase)
            return 1.0 - smoothstep(p) * (1.0 - nightLevel)
        }
        if m < windowEnd - halfEase { return nightLevel }
        if m < windowEnd + halfEase {
            let p = (m - (windowEnd - halfEase)) / (2 * halfEase)
            return nightLevel + smoothstep(p) * (1.0 - nightLevel)
        }
        return 1.0
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Dial geometry

    private static func drawBezel(context: CGContext, center: CGPoint, radius: CGFloat, dim: CGFloat) {
        let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -radius * 0.02), blur: radius * 0.05,
                           color: NSColor.black.withAlphaComponent(0.55 * dim).cgColor)
        context.setFillColor(DialPalette.bezelDark.blended(dim: dim).cgColor)
        context.fillEllipse(in: ring.insetBy(dx: -radius * 0.02, dy: -radius * 0.02))
        context.restoreGState()

        // Faint brushed-metal highlight arc on the bezel rim.
        let rimWidth = radius * 0.018
        let rim = ring.insetBy(dx: -rimWidth, dy: -rimWidth)
        let path = CGPath(ellipseIn: rim, transform: nil)
        context.addPath(path)
        context.setLineWidth(rimWidth)
        context.setStrokeColor(DialPalette.bezelLight.blended(dim: dim).cgColor)
        context.strokePath()
    }

    private static func drawFace(context: CGContext, center: CGPoint, radius: CGFloat, dim: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()

        context.setFillColor(DialPalette.face.blended(dim: dim).cgColor)
        context.fill(rect)

        // Subtle radial vignette for depth.
        let colors = [
            NSColor.white.withAlphaComponent(0.05 * dim).cgColor,
            NSColor.black.withAlphaComponent(0.0).cgColor,
            NSColor.black.withAlphaComponent(0.16 * dim).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                      locations: [0.0, 0.55, 1.0]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.35),
                                        startRadius: 0, endCenter: center, endRadius: radius * 1.15,
                                        options: [.drawsAfterEndLocation])
        }

        // Fixed (non-animated) glass sheen — a soft diagonal highlight, cheap
        // and adds polish without any motion to draw the eye or add wear.
        context.saveGState()
        context.rotate(by: .pi / 5)
        let sheen = CGRect(x: -radius * 1.4, y: radius * 0.15, width: radius * 2.8, height: radius * 0.5)
        let sheenColors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.035 * dim).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray
        if let sg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(sg, start: CGPoint(x: sheen.minX, y: sheen.midY),
                                        end: CGPoint(x: sheen.maxX, y: sheen.midY), options: [])
        }
        context.restoreGState()

        // Faint film-grain: a soft-light noise pass so the face reads as a
        // matte physical surface rather than a flat vector fill.
        if let noise = noiseImage {
            context.saveGState()
            context.setAlpha(0.5)
            context.setBlendMode(.softLight)
            context.draw(noise, in: rect)
            context.restoreGState()
        }

        context.restoreGState()
    }

    /// A single grayscale noise field, generated once and reused every frame.
    /// Values cluster around mid-gray (128) so, drawn with `.softLight`, it
    /// nudges pixels lighter or darker without adding a visible gray cast.
    private static let noiseImage: CGImage? = {
        let dim = 384
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: dim,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: dim * dim)
        for i in 0..<(dim * dim) {
            ptr[i] = UInt8.random(in: 104...152)
        }
        return ctx.makeImage()
    }()

    /// Fixed screen-space offset every raised element (hour ticks, hands,
    /// hub) casts its contact shadow toward, and the axis their rim/channel
    /// shading is built from — one consistent light source, so the whole
    /// dial reads as physical parts under one lamp rather than each element
    /// having its own unrelated shading. Scale by `radius` at the call site.
    private static let raisedShadowOffsetUnit = CGSize(width: 0.012, height: -0.020)

    /// A darker "rim" and a lighter inset "channel" derived from one base
    /// color — the two-tone read that makes a flat capsule look like a
    /// machined metal baton with a polished groove down the middle.
    private static func rimAndChannel(_ color: NSColor) -> (rim: NSColor, channel: NSColor) {
        let rim = color.blended(withFraction: 0.22, of: .black) ?? color
        let channel = color.blended(withFraction: 0.55, of: .white) ?? color
        return (rim, channel)
    }

    // Dial track geometry, in fractions of the face radius. These are shared
    // with the geometry audit so the checks can't drift from the drawing.
    static let tickOuterEdge: CGFloat = 0.90
    static let tickLength: CGFloat = 0.050
    static let tickWidth: CGFloat = 0.005

    /// Numerals and ticks are sized and centred to match: on the reference
    /// clock a numeral's cap height is only about a quarter taller than a
    /// minute tick, and the two share one radial band rather than sitting on
    /// separate rings. Cap height here is `numeralFontScale × capHeight`
    /// ≈ 0.065 R against a 0.050 R tick.
    static let numeralFontScale: CGFloat = 0.085
    /// Centre of the tick band — numerals put their cap-height midpoint here,
    /// so both marks are centred on the same circle.
    static var numeralRingRadius: CGFloat { tickOuterEdge - tickLength / 2 }

    /// Minute-divider ticks only — no separate hour tick. The numeral
    /// itself now marks the hour position (see drawNumerals), sitting in
    /// the same radial band as these ticks, so hour markers don't compete
    /// with the numerals for space and hands have clear room below both.
    private static func drawTicks(context: CGContext, center: CGPoint, radius: CGFloat, lighting: Lighting) {
        let dim = lighting.dim
        let outer = radius * tickOuterEdge
        let length = radius * tickLength
        let width = radius * tickWidth
        let inner = outer - length

        for i in 0..<60 where i % 5 != 0 {
            let angle = -CGFloat(i) / 60.0 * 2 * .pi

            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            let rect = CGRect(x: -width / 2, y: inner, width: width, height: length)
            let path = CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
            context.addPath(path)
            context.setFillColor(DialPalette.inkDim.blended(dim: dim).cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }

    // Not private: the audit tool (compiled into the same module) reuses this
    // exact fallback chain rather than force-unwrapping Futura Medium itself
    // — a machine without that font resident (a clean CI runner, for
    // instance) would otherwise crash the audit rather than degrade like the
    // shipped renderer does.
    static func numeralFont(size: CGFloat, medium: Bool) -> NSFont {
        NSFont(name: medium ? "Futura Medium" : "Futura", size: size)
            ?? NSFont(name: "Futura", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
    }

    /// Draws `text` centered on its true glyph ink — not the font's
    /// line-height box. `NSAttributedString.size()`/`draw(at:)` center on
    /// ascender-to-descender metrics, which is wrong for a dial: Futura's
    /// numerals are old-style figures (3, 5, 7, 9 dip below the baseline;
    /// 6, 8 rise above it; 0, 1, 2 do neither), so metric-box centering
    /// plants every digit at a different effective height and the ring
    /// never reads as uniform. CTLineGetBoundsWithOptions(.useGlyphPathBounds)
    /// gives the actual drawn-ink rect, so centering on its midpoint lines
    /// every numeral up on the same optical center regardless of shape.
    ///
    /// Measurement and drawing must share one coordinate frame. CTLine
    /// bounds are relative to the text *baseline*, but
    /// `NSAttributedString.draw(at:)` positions by the lower-left of the
    /// *layout box* (baseline minus descender+leading). Feeding a
    /// baseline-relative offset into that API silently displaced every
    /// numeral outward by ~0.29 × fontSize. Drawing via CTLineDraw with an
    /// explicit `textPosition` keeps both in baseline coordinates.
    ///
    /// Numerals are aligned on the cap-height midpoint rather than each
    /// glyph's own ink midpoint. Futura's digits are lining figures, but
    /// their ink still varies (a pointed "4" overshoots the cap line, "7"
    /// and "9" dip slightly below the baseline), so ink-midpoint centering
    /// sets each digit on a subtly different baseline and the ring wobbles.
    /// The cap-height midpoint is identical for every digit, so all twelve
    /// numerals sit on one true baseline arc.
    private static func drawNumeral(_ text: String, attrs: [NSAttributedString.Key: Any],
                                     centeredAt point: CGPoint, context: CGContext, rotation: CGFloat = 0) {
        let str = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard !ink.isNull, let font = attrs[.font] as? NSFont else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        if rotation != 0 { context.rotate(by: rotation) }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -ink.midX, y: -font.capHeight / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A single ring, matching the reference: hour numerals sit in the same
    /// radial band as the minute ticks, one numeral standing in for the tick
    /// at each hour position. No secondary ring.
    private static func drawNumerals(context: CGContext, center: CGPoint, radius: CGFloat, lighting: Lighting, use24Hour: Bool) {
        // One size for every numeral, scaled to sit in the tick band rather
        // than tower over it. Oversized numerals were the reason two-digit
        // ones had to be shrunk to fit between their flanking ticks; at this
        // size they clear comfortably, so all twelve stay uniform.
        let fontSize = radius * numeralFontScale
        let font = numeralFont(size: fontSize, medium: true)
        let color = DialPalette.ink.blended(dim: lighting.dim)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        // Cap-height midpoint goes on the centre of the tick band, so numerals
        // and ticks are centred on one circle and read as a single ring.
        let placementRadius = radius * numeralRingRadius
        let shadow = mixedShadow(color: DialPalette.ink, radius: radius, glow: lighting.glow)

        // Slot i=0 is the 12 o'clock position, increasing clockwise. In
        // 12-hour mode slot 0 reads "12" (not "0"); every other slot reads
        // its own index. In 24-hour mode slot values are simply 2*i.
        for i in 0..<12 {
            let angle = .pi / 2 - CGFloat(i) / 12.0 * 2 * .pi
            let point = CGPoint(x: center.x + placementRadius * cos(angle), y: center.y + placementRadius * sin(angle))
            let value = use24Hour ? i * 2 : (i == 0 ? 12 : i)

            context.saveGState()
            context.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color)
            drawNumeral(String(value), attrs: attrs, centeredAt: point, context: context)
            context.restoreGState()
        }
    }

    // MARK: - Hands

    private static func drawHands(context: CGContext, center: CGPoint, radius: CGFloat, lighting: Lighting,
                                   time: WallClock, movement: Movement, accent: NSColor, use24Hour: Bool) {
        let dim = lighting.dim
        let minuteFrac = Double(time.minute) + time.secondFraction / 60.0
        let hourSpan: Double = use24Hour ? 24.0 : 12.0
        let hourFrac = Double(time.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0

        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let secondAngle = secondsAngle(secondFraction: time.secondFraction, movement: movement)

        let shadowOffset = CGSize(width: raisedShadowOffsetUnit.width * radius, height: raisedShadowOffsetUnit.height * radius)

        // Hour + minute hands: a machined-metal rim + polished channel (see
        // rimAndChannel), cast in the same fixed shadow direction as the
        // ticks and hub so every raised part reads as one lit object. Lit
        // shadow eases from a plain contact shadow (day) to a soft
        // ink-colored bloom (night).
        let inkShadow = mixedShadow(color: DialPalette.ink, radius: radius, glow: lighting.glow)
        context.saveGState()
        context.setShadow(offset: shadowOffset, blur: inkShadow.blur, color: inkShadow.color)

        drawHand(context: context, center: center, angle: hourAngle, length: radius * 0.50,
                 baseHalfWidth: radius * 0.028, tipHalfWidth: radius * 0.017, tailLength: 0,
                 color: DialPalette.ink.blended(dim: dim), groove: true)

        drawHand(context: context, center: center, angle: minuteAngle, length: radius * 0.73,
                 baseHalfWidth: radius * 0.023, tipHalfWidth: radius * 0.012, tailLength: 0,
                 color: DialPalette.ink.blended(dim: dim), groove: true)
        context.restoreGState()

        // Seconds hand: a plain slender needle in the accent color, glowing
        // in its own accent-tinted bloom at night rather than the ink white.
        let accentShadow = mixedShadow(color: accent, radius: radius, glow: lighting.glow)
        context.saveGState()
        context.setShadow(offset: shadowOffset, blur: accentShadow.blur, color: accentShadow.color)
        drawHand(context: context, center: center, angle: secondAngle, length: radius * 0.80,
                 baseHalfWidth: radius * 0.0055, tipHalfWidth: radius * 0.0055, tailLength: radius * 0.16,
                 color: accent.blended(dim: dim), groove: false)
        context.restoreGState()

        // Center hub: same rim/channel logic as the hands, wrapped into a
        // ring — a darker outer rim, a bright inner ring catching the light,
        // then the recessed core — plus the shared cast shadow so it reads
        // as the pivot the hands are physically mounted on.
        let hubOuter = radius * 0.040
        let hubRing = radius * 0.030
        let hubInner = radius * 0.014
        let (hubRim, hubChannel) = rimAndChannel(accent.blended(dim: dim))
        context.saveGState()
        context.setShadow(offset: shadowOffset, blur: accentShadow.blur * 0.6, color: accentShadow.color)
        context.setFillColor(hubRim.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - hubOuter, y: center.y - hubOuter, width: hubOuter * 2, height: hubOuter * 2))
        context.setShadow(offset: .zero, blur: 0, color: NSColor.clear.cgColor)
        context.setFillColor(hubChannel.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - hubRing, y: center.y - hubRing, width: hubRing * 2, height: hubRing * 2))
        context.setFillColor(DialPalette.face.blended(dim: dim).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - hubInner, y: center.y - hubInner, width: hubInner * 2, height: hubInner * 2))
        context.restoreGState()
    }

    /// Seconds-hand angle for the three movement styles:
    ///  - digital: perfectly continuous sweep
    ///  - mechanical: stepped at 8 sub-steps/second, an almost-smooth shudder
    ///  - quartz: a discrete 1Hz tick with a brief spring overshoot-and-settle,
    ///    the small mechanical-inertia detail real quartz movements have
    private static func secondsAngle(secondFraction: Double, movement: Movement) -> CGFloat {
        let tickStep = 2 * CGFloat.pi / 60.0
        switch movement {
        case .digital:
            return CGFloat(secondFraction / 60.0) * 2 * .pi

        case .mechanical:
            let steps = 8.0
            let stepped = (secondFraction * steps).rounded(.down) / steps
            return CGFloat(stepped / 60.0) * 2 * .pi

        case .quartz:
            let baseSecond = floor(secondFraction)
            let target = CGFloat(baseSecond / 60.0) * 2 * .pi
            let sinceTick = secondFraction - baseSecond
            let window = 0.25
            guard sinceTick < window else { return target }
            let p = sinceTick / window
            let bounce = exp(-p * 6.0) * sin(p * .pi * 3.0) * 0.35
            return target + tickStep * CGFloat(bounce)
        }
    }

    private static func drawHand(context: CGContext, center: CGPoint, angle: CGFloat, length: CGFloat,
                                  baseHalfWidth: CGFloat, tipHalfWidth: CGFloat, tailLength: CGFloat,
                                  color: NSColor, groove: Bool) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        // 0 radians = 12 o'clock, clockwise.
        context.rotate(by: .pi / 2 - angle)

        // A hand with no tail (hour/minute) gets a single clean base point at
        // the pivot. Only the tailed seconds hand gets the narrower flared
        // base + counterweight arc — reusing that flare for tailLength == 0
        // used to collapse two near-duplicate points at the same x, leaving
        // a stray sub-pixel notch right at the pivot.
        let path = CGMutablePath()
        if tailLength > 0 {
            path.move(to: CGPoint(x: -tailLength, y: -baseHalfWidth * 0.9))
            path.addLine(to: CGPoint(x: 0, y: -baseHalfWidth))
        } else {
            path.move(to: CGPoint(x: 0, y: -baseHalfWidth))
        }
        path.addLine(to: CGPoint(x: length - tipHalfWidth, y: -tipHalfWidth))
        path.addArc(center: CGPoint(x: length - tipHalfWidth, y: 0), radius: tipHalfWidth,
                    startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: baseHalfWidth))
        if tailLength > 0 {
            path.addLine(to: CGPoint(x: -tailLength, y: baseHalfWidth * 0.9))
            path.addArc(center: CGPoint(x: -tailLength, y: 0), radius: baseHalfWidth * 0.9,
                        startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
        }
        path.closeSubpath()

        if groove {
            // Machined metal: a darker rim (the hand's full silhouette) with
            // a lighter inset channel running most of its length — the same
            // two-tone language as the hour ticks, so hands and ticks read
            // as parts of one hardware set. The rim carries the one shadow;
            // the channel is drawn shadow-free so it doesn't double up.
            let (rim, channel) = rimAndChannel(color)

            context.addPath(path)
            context.setFillColor(rim.cgColor)
            context.fillPath()

            context.setShadow(offset: .zero, blur: 0, color: NSColor.clear.cgColor)
            let channelHalfWidth = baseHalfWidth * 0.42
            let channelStart = baseHalfWidth * 1.6
            let channelEnd = length - tipHalfWidth * 2.2
            if channelEnd > channelStart {
                let channelRect = CGRect(x: channelStart, y: -channelHalfWidth,
                                          width: channelEnd - channelStart, height: channelHalfWidth * 2)
                let channelPath = CGPath(roundedRect: channelRect, cornerWidth: channelHalfWidth,
                                          cornerHeight: channelHalfWidth, transform: nil)
                context.addPath(channelPath)
                context.setFillColor(channel.cgColor)
                context.fillPath()
            }
        } else {
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }
}

private extension NSColor {
    /// Blend toward black by the given dim factor (1 = full brightness).
    func blended(dim: CGFloat) -> NSColor {
        guard dim < 1.0 else { return self }
        guard let rgb = usingColorSpace(.deviceRGB) else { return self }
        return NSColor(deviceRed: rgb.redComponent * dim, green: rgb.greenComponent * dim,
                        blue: rgb.blueComponent * dim, alpha: rgb.alphaComponent)
    }
}
