import Cocoa
import CoreText

/// A flat-colour Bauhaus dial: debossed numerals and markers pressed into a
/// finely grained plate, with raised white hands carrying a recessed lume
/// channel, and a layered centre hub.
///
/// The whole face is built from two opposed depth cues, and getting either
/// backwards is what makes a dial like this read as a diagram:
///
///  - Marks are *recessed*. A recess lit from the upper-left catches light
///    on its lower-right inner wall, so each mark gets a pale rim offset
///    down-and-right behind the dark ink (`deboss`).
///  - Hands and hub are *raised*. They cast down-and-right onto the plate,
///    and their domed cross-section is bright on the side facing the light.
///
/// CoreGraphics here is y-UP (this is an NSView-backed context), unlike the
/// y-down canvas the design was prototyped in — every direction constant
/// below is already converted. Do not flip them again.
enum BauhausFace {

    // MARK: - Palettes

    struct Palette {
        let key: String
        let name: String
        let bg: NSColor      // the plate
        let mark: NSColor    // numerals, markers
        let lume: NSColor    // the hands' recessed channel
        let hand: NSColor    // hand + hub body
        let isDark: Bool
        /// A lume plate: the marks read as *emitting* light rather than as
        /// recesses catching it. Flips the depth model — see `deboss`.
        let isLume: Bool

        init(_ key: String, _ name: String, bg: String, mark: String, lume: String, hand: String,
             isDark: Bool = false, isLume: Bool = false) {
            self.key = key; self.name = name
            self.bg = NSColor(hex: bg); self.mark = NSColor(hex: mark)
            self.lume = NSColor(hex: lume); self.hand = NSColor(hex: hand)
            self.isDark = isDark; self.isLume = isLume
        }

        /// The plates offered as the daytime dial.
        static let day: [Palette] = [
            Palette("lagoon",    "Lagoon",    bg: "#a9d9d2", mark: "#0e4b48", lume: "#dcf1f5", hand: "#fbfdfd"),
            Palette("pistachio", "Pistachio", bg: "#d7e3c2", mark: "#233b20", lume: "#f2f8e8", hand: "#fdfdfa"),
            Palette("cream",     "Cream",     bg: "#ece0cb", mark: "#3b3226", lume: "#faf4ea", hand: "#fffdf9"),
            Palette("sky",       "Sky",       bg: "#bfd4e6", mark: "#1d3e57", lume: "#e9f2fb", hand: "#fbfdff"),
            Palette("salmon",    "Salmon",    bg: "#eec3b8", mark: "#5e2b2a", lume: "#fdece6", hand: "#fffbf9"),
            Palette("yellow",    "Yellow",    bg: "#efcf6b", mark: "#4a3712", lume: "#fdf3cb", hand: "#fffdf6"),
            Palette("beige",     "Beige",     bg: "#ddcfb4", mark: "#3a3324", lume: "#f7f0e2", hand: "#fffdf8"),
            Palette("slate",     "Slate",     bg: "#20272e", mark: "#aebdc9", lume: "#46545f", hand: "#e6ecf1", isDark: true),
        ]

        /// The plates offered for the overnight window. Slate is the plain
        /// one: a dark dial, still lit from outside. The five lume plates
        /// invert that — the marks and the hands' channel are the only light
        /// in the frame, so `hand` is a muted steel rather than white, or the
        /// baton bodies would outshine the lume they carry.
        static let night: [Palette] = [
            Palette("slate",        "Slate",    bg: "#20272e", mark: "#aebdc9", lume: "#46545f", hand: "#e6ecf1", isDark: true),
            Palette("lumeGreen",    "Green",    bg: "#12181a", mark: "#57d493", lume: "#8dffc0", hand: "#7f8f95", isDark: true, isLume: true),
            Palette("lumeBlue",     "Blue",     bg: "#0f151d", mark: "#5cb9e8", lume: "#a8e2ff", hand: "#7c8b98", isDark: true, isLume: true),
            Palette("lumeAmber",    "Amber",    bg: "#191309", mark: "#e0a44e", lume: "#ffcf85", hand: "#948a7c", isDark: true, isLume: true),
            Palette("lumeRed",      "Red",      bg: "#180f0e", mark: "#e07360", lume: "#ff9d8a", hand: "#93837f", isDark: true, isLume: true),
            Palette("lumeLavender", "Lavender", bg: "#14111d", mark: "#a893e8", lume: "#d0bcff", hand: "#8a8598", isDark: true, isLume: true),
        ]

        static let all: [Palette] = day + night.dropFirst() // Slate is in both

        static func named(_ key: String) -> Palette {
            all.first { $0.key == key } ?? all[0]
        }

        static func nightNamed(_ key: String) -> Palette {
            night.first { $0.key == key } ?? night[0]
        }
    }

    /// Which palette to actually draw. "Follow the day" swaps to the chosen
    /// night plate overnight rather than dimming a bright pastel toward mud
    /// — a light dial dimmed 70% reads as dirty, not as night.
    static func activePalette(now: Date, isPreview: Bool, defaults: FormzeitDefaults) -> Palette {
        let chosen = Palette.named(defaults.bauhausPalette)
        guard defaults.nightDimming, !isPreview, !chosen.isDark else { return chosen }
        let h = Calendar.current.component(.hour, from: now)
        return (h >= 22 || h < 7) ? Palette.nightNamed(defaults.bauhausNightPalette) : chosen
    }

    // MARK: - Light

    // Fixed light, upper-left, in y-UP screen space.
    static let LX: CGFloat = -0.45
    static let LY: CGFloat = 0.89

    // Geometry, all as fractions of the plate radius R.
    static let markerOuter: CGFloat = 0.960
    static let markerLenFive: CGFloat = 0.068
    static let markerLenMinute: CGFloat = 0.042
    static let markerHalfFive: CGFloat = 0.0130
    static let markerHalfMinute: CGFloat = 0.0092
    static let numeralRing: CGFloat = 0.735
    static let numeralScale: CGFloat = 0.178
    static let hourLen: CGFloat = 0.47,  hourHalf: CGFloat = 0.034
    static let minuteLen: CGFloat = 0.73, minuteHalf: CGFloat = 0.0258
    static let secondLen: CGFloat = 0.80
    static let hubR: CGFloat = 0.050

    // MARK: - Passes
    //
    // Split to match FormzeitView's cache: the plate, its grain, the markers
    // and the numerals change only with slow drift and dimming, so they ride
    // the cached pass. Only hands and hub are redrawn every frame.

    static func renderFace(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval,
                            isPreview: Bool, defaults: FormzeitDefaults) {
        let g = geometry(bounds: bounds, now: now, isPreview: isPreview, defaults: defaults)
        let p = activePalette(now: now, isPreview: isPreview, defaults: defaults)
        let dim = dimFactor(elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)

        // The plate fills the whole frame, not just a disc — it reads as a
        // surface the screen is cut out of, not a coin on a backdrop. It and
        // its grain are identical between regenerations, so they come from a
        // cached bitmap; see plateImage.
        if let plate = plateImage(context: context, bounds: bounds, palette: p, dim: dim) {
            context.draw(plate, in: bounds)
        } else {
            context.setFillColor(p.bg.blended(dim: dim).cgColor)
            context.fill(bounds)
            drawGrain(context: context, bounds: bounds, isDark: p.isDark)
        }

        context.saveGState()
        applyDrift(context: context, g: g)
        drawMarkers(context: context, center: g.center, R: g.R, palette: p, dim: dim)
        drawNumerals(context: context, center: g.center, R: g.R, palette: p, dim: dim,
                     use24Hour: defaults.use24Hour)
        context.restoreGState()
    }

    static func renderHands(context: CGContext, bounds: CGRect, now: Date, elapsedRunTime: TimeInterval,
                             isPreview: Bool, defaults: FormzeitDefaults, reduceMotion: Bool) {
        let g = geometry(bounds: bounds, now: now, isPreview: isPreview, defaults: defaults)
        let p = activePalette(now: now, isPreview: isPreview, defaults: defaults)
        let dim = dimFactor(elapsedRunTime: elapsedRunTime, isPreview: isPreview, defaults: defaults)
        let t = ClassicFace.wallClock(now)

        let minuteFrac = Double(t.minute) + t.secondFraction / 60.0
        let hourSpan: Double = defaults.use24Hour ? 24.0 : 12.0
        let hourFrac = Double(t.hour).truncatingRemainder(dividingBy: hourSpan) + minuteFrac / 60.0

        let hourAngle = CGFloat(hourFrac / hourSpan) * 2 * .pi
        let minuteAngle = CGFloat(minuteFrac / 60.0) * 2 * .pi
        let secondAngle = secondsAngleV2(secondFraction: t.secondFraction, movement: defaults.movement,
                                          reduceMotion: reduceMotion)

        context.saveGState()
        applyDrift(context: context, g: g)

        // Hour, minute, second, hub — the order they're stacked on a real
        // movement. The second hand was drawn first, which sank it beneath
        // both batons and made it vanish and reappear as it swept past them.
        drawHand(context: context, center: g.center, R: g.R, angle: hourAngle,
                 length: g.R * hourLen, halfW: g.R * hourHalf, palette: p, dim: dim)
        drawHand(context: context, center: g.center, R: g.R, angle: minuteAngle,
                 length: g.R * minuteLen, halfW: g.R * minuteHalf, palette: p, dim: dim)
        drawSecondHand(context: context, center: g.center, R: g.R, angle: secondAngle, palette: p, dim: dim,
                       color: secondHandColor(palette: p, defaults: defaults))
        drawHub(context: context, center: g.center, R: g.R, palette: p, dim: dim,
                tint: accentTint(defaults: defaults))

        context.restoreGState()
    }

    // MARK: - Layout, drift, dimming

    private struct Geometry {
        let center: CGPoint
        let R: CGFloat
        let dx: CGFloat, dy: CGFloat, scale: CGFloat
    }

    private static func geometry(bounds: CGRect, now: Date, isPreview: Bool,
                                  defaults: FormzeitDefaults) -> Geometry {
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let R = side * 0.44

        guard defaults.burnInProtection, !isPreview else {
            return Geometry(center: center, R: R, dx: 0, dy: 0, scale: 1)
        }
        // Slow, incommensurate drift plus a whisper of scale — the spec's
        // 1-3% translation / 1-2% scale budget. Both passes derive it from
        // `now`, so the cached plate and the live hands never separate.
        let t = now.timeIntervalSinceReferenceDate
        let dx = (0.017 * sin(t * 0.0021) + 0.008 * sin(t * 0.00073 + 0.4)) * side
        let dy = (0.015 * sin(t * 0.0017 + 1.3) + 0.007 * sin(t * 0.00051 + 0.7)) * side
        let scale = 1.0 + 0.010 * sin(t * 0.00039 + 2.1)
        return Geometry(center: center, R: R, dx: CGFloat(dx), dy: CGFloat(dy), scale: CGFloat(scale))
    }

    private static func applyDrift(context: CGContext, g: Geometry) {
        context.translateBy(x: g.dx, y: g.dy)
        guard g.scale != 1 else { return }
        context.translateBy(x: g.center.x, y: g.center.y)
        context.scaleBy(x: g.scale, y: g.scale)
        context.translateBy(x: -g.center.x, y: -g.center.y)
    }

    /// The burn-in idle ramp, and *only* that.
    ///
    /// The diel luminance curve is deliberately not applied here. On the
    /// light-based faces dimming means "less light reaching you", which is
    /// physical. On a flat pastel plate it just multiplies the colour toward
    /// black, and Lagoon at 0.6 is not a darker mint — it is grey-green mud.
    /// This face's day/night is the palette swap instead (see activePalette).
    private static func dimFactor(elapsedRunTime: TimeInterval, isPreview: Bool,
                                   defaults: FormzeitDefaults) -> CGFloat {
        guard !isPreview, defaults.burnInProtection else { return 1.0 }
        let rampStart = 300.0, rampEnd = 2700.0
        let floor: CGFloat = 0.82
        guard elapsedRunTime > rampStart else { return 1.0 }
        let p = min(1.0, (elapsedRunTime - rampStart) / (rampEnd - rampStart))
        let eased = p * p * (3 - 2 * p)
        return 1.0 - CGFloat(eased) * (1.0 - floor)
    }

    // MARK: - Grain

    /// Fine plaster grain, generated once. Deliberately visible — at the
    /// reference's strength it is the difference between a flat fill and a
    /// material. Two passes (soft-light then a lighter offset overlay) so it
    /// reads as a surface rather than as TV static.
    private static let grainImage: CGImage? = {
        let dim = 512
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: dim,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: dim * dim)
        for i in 0..<(dim * dim) {
            let fine = Double.random(in: -23...23)
            let coarse = Double.random(in: -13...13)
            ptr[i] = UInt8(max(0, min(255, 128 + fine + coarse)))
        }
        return ctx.makeImage()
    }()

    // MARK: - Cached plate
    //
    // The flat fill plus its two grain passes are the entire cost of the
    // face pass — measured at ~570ms on a 5K frame, versus ~2ms for all the
    // markers and numerals combined. And every regeneration produces the
    // same pixels: the grain is a static texture drawn before `applyDrift`,
    // and the only thing varying underneath is a dim ramp that moves
    // 0.000075/s and is constant after minute 45. Regenerating it every
    // 1.5s was ~40% of a core doing nothing, which is the same class of
    // regression this project already fixed once.
    //
    // So it is composited once into a bitmap and reused. Built at *device*
    // resolution with the grain tiled 1:1 and no interpolation, because a
    // 512pt tile resampled into a 2x context was itself a large part of the
    // cost even on the miss.

    private struct PlateKey: Equatable {
        let w: Int, h: Int, palette: String, dimBucket: Int
    }
    private static var plateCache: CGImage?
    private static var plateKey: PlateKey?
    private static let plateLock = NSLock()

    private static func plateImage(context: CGContext, bounds: CGRect,
                                    palette: Palette, dim: CGFloat) -> CGImage? {
        let scale = max(1.0, abs(context.ctm.a))
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        // Quantise dim so the idle ramp's continuous crawl doesn't bust the
        // cache every frame; 1/64 steps are far below the visible threshold.
        let key = PlateKey(w: w, h: h, palette: palette.key, dimBucket: Int((dim * 64).rounded()))

        plateLock.lock()
        defer { plateLock.unlock() }
        if let cached = plateCache, plateKey == key { return cached }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let px = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.setFillColor(palette.bg.blended(dim: dim).cgColor)
        ctx.fill(px)
        ctx.interpolationQuality = .none
        drawGrain(context: ctx, bounds: px, isDark: palette.isDark)

        guard let image = ctx.makeImage() else { return nil }
        plateCache = image
        plateKey = key
        return image
    }

    private static func drawGrain(context: CGContext, bounds: CGRect, isDark: Bool) {
        guard let grain = grainImage else { return }
        let tile: CGFloat = 512
        context.saveGState()
        context.setBlendMode(.softLight)
        context.setAlpha(isDark ? 0.55 : 0.95)
        var y = bounds.minY
        while y < bounds.maxY {
            var x = bounds.minX
            while x < bounds.maxX {
                context.draw(grain, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        context.setBlendMode(.overlay)
        context.setAlpha(isDark ? 0.14 : 0.28)
        y = bounds.minY - 61
        while y < bounds.maxY {
            var x = bounds.minX - 37
            while x < bounds.maxX {
                context.draw(grain, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        context.restoreGState()
    }

    // MARK: - Debossed marks

    /// Draws `shape` as a recess: a pale rim peeking out on the lower-right
    /// (away from the upper-left light), then the dark ink on top.
    ///
    /// On a lume plate the depth model inverts. A mark that emits light isn't
    /// a recess catching an external source, so the pale down-right rim is
    /// wrong there — it reads as a printing misregistration on a dark plate.
    /// Those marks get a symmetric halo of their own colour instead.
    private static func deboss(context: CGContext, R: CGFloat, ink: NSColor, glow: NSColor?,
                                _ shape: (CGContext) -> Void) {
        if let glow = glow {
            context.saveGState()
            // Zero offset: light from the mark itself spreads evenly. Blur is
            // kept tight — a wide halo washes the plate grey and costs real
            // time, since blur is roughly linear in radius and this runs once
            // per mark.
            context.setShadow(offset: .zero, blur: max(1.5, R * 0.012),
                              color: glow.withAlphaComponent(0.55).cgColor)
            context.setFillColor(ink.cgColor)
            shape(context)
            context.restoreGState()
            return
        }
        // Keep this small and soft. Too far or too opaque and the pale rim
        // stops reading as a lit recess wall and starts reading as badly
        // registered two-colour printing.
        let off = max(0.75, R * 0.0032)
        context.saveGState()
        context.translateBy(x: off, y: -off) // y-up: lower-right
        context.setFillColor(NSColor.white.withAlphaComponent(0.34).cgColor)
        shape(context)
        context.restoreGState()

        context.setFillColor(ink.cgColor)
        shape(context)
    }

    private static func drawMarkers(context: CGContext, center: CGPoint, R: CGFloat,
                                     palette: Palette, dim: CGFloat) {
        let ink = palette.mark.blended(dim: dim)
        for i in 0..<60 {
            let isFive = i % 5 == 0
            let len = R * (isFive ? markerLenFive : markerLenMinute)
            let halfW = R * (isFive ? markerHalfFive : markerHalfMinute)
            let angle = CGFloat(i) / 60.0 * 2 * .pi
            // Only the twelve hour markers glow. The 48 minute ticks are a
            // fifth the area, so a halo on them barely reads — and it would
            // quadruple the number of blurred fills in this pass.
            let glow = (palette.isLume && isFive) ? palette.lume : nil

            deboss(context: context, R: R, ink: ink, glow: glow) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: -angle) // y-up: clockwise from 12
                let rect = CGRect(x: -halfW, y: R * markerOuter - len, width: halfW * 2, height: len)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: halfW, cornerHeight: halfW, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }

    private static func drawNumerals(context: CGContext, center: CGPoint, R: CGFloat,
                                      palette: Palette, dim: CGFloat, use24Hour: Bool) {
        let font = ClassicFace.numeralFont(size: R * numeralScale, medium: false)
        let ink = palette.mark.blended(dim: dim)

        for i in 0..<12 {
            let value = use24Hour ? i * 2 : (i == 0 ? 12 : i)
            let angle = .pi / 2 - CGFloat(i) / 12.0 * 2 * .pi
            let point = CGPoint(x: center.x + R * numeralRing * cos(angle),
                                y: center.y + R * numeralRing * sin(angle))

            // Centre on true glyph ink and the font's cap-height midpoint,
            // not the layout box — see ClassicFace.drawNumeral for why.
            // kCTForegroundColorFromContextAttribute is required: without it
            // CTLineDraw ignores the context's fill colour and paints black,
            // so `deboss`'s two-pass white/ink fill has no effect on text.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(value), attributes: attrs))
            let inkRect = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard !inkRect.isNull else { continue }

            deboss(context: context, R: R, ink: ink, glow: palette.isLume ? palette.lume : nil) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: point.x, y: point.y)
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: -inkRect.midX, y: -font.capHeight / 2)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Hands

    /// A moulded baton: a narrow neck off the hub flaring into a long paddle,
    /// a recessed lume channel, a domed cross-section and a soft cast shadow.
    private static func drawHand(context: CGContext, center: CGPoint, R: CGFloat, angle: CGFloat,
                                  length: CGFloat, halfW: CGFloat, palette: Palette, dim: CGFloat) {
        let theta = -angle // y-up: clockwise from 12
        // How strongly the local +x edge faces the light: +1 lit, -1 shadowed.
        let t = cos(theta) * LX + sin(theta) * LY

        let bodyStart = length * 0.33
        let stemHalf = halfW * 0.42
        let body = CGPath(roundedRect: CGRect(x: -halfW, y: bodyStart - halfW,
                                               width: halfW * 2, height: (length - bodyStart) + halfW),
                          cornerWidth: halfW, cornerHeight: halfW, transform: nil)
        let stem = CGPath(roundedRect: CGRect(x: -stemHalf, y: -halfW * 1.2,
                                               width: stemHalf * 2, height: bodyStart + halfW * 1.2),
                          cornerWidth: stemHalf, cornerHeight: stemHalf, transform: nil)

        let base = palette.hand.blended(dim: dim)

        // Shadow pass. The offset is set in the UNROTATED frame so it stays
        // down-right on screen whichever way the hand points.
        //
        // Skipped entirely on a lume plate: a dark shadow on a near-black
        // plate is invisible, and blur is the single most expensive thing in
        // this pass — cost runs roughly linear in radius, and a shadowed fill
        // is ~50x an unshadowed one. On the light plates 1.15 keeps the
        // contact shadow reading while costing about half what 2.3 did.
        context.saveGState()
        if !palette.isLume {
            context.setShadow(offset: CGSize(width: halfW * 0.30, height: -halfW * 0.55),
                              blur: halfW * 1.15,
                              color: NSColor(calibratedRed: 0.09, green: 0.23, blue: 0.22, alpha: 0.34).cgColor)
        }
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: theta)
        context.setFillColor(base.cgColor)
        context.addPath(stem); context.fillPath()
        context.addPath(body); context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: theta)

        // Outline goes down BEFORE the fill at double width, so the fill
        // buries its inner half and — the part that matters — the seam where
        // the paddle's round cap crosses the neck. Stroking after the fill
        // instead leaves that arc scarred across the neck.
        context.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.27, alpha: 0.20).cgColor)
        context.setLineWidth(max(1.4, halfW * 0.16))
        context.setLineJoin(.round)
        context.addPath(body); context.strokePath()
        context.addPath(stem); context.strokePath()

        // Domed cross-section. One gradient shared by neck and paddle so
        // they cannot tonally mismatch where they meet.
        let volume = gradient([
            lightMix(base, -t), base, lightMix(base, t * 0.75), lightMix(base, t)
        ], [0.0, 0.34, 0.72, 1.0])
        if let volume = volume {
            context.saveGState()
            context.addPath(stem); context.addPath(body); context.clip()
            context.drawLinearGradient(volume, start: CGPoint(x: -halfW, y: 0), end: CGPoint(x: halfW, y: 0),
                                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }

        // Recessed lume channel. The white frame is thin — about a quarter
        // of the half-width — so the channel dominates the baton's face.
        let m = halfW * 0.28
        let chHalf = halfW - m
        let chA = bodyStart - halfW + m + chHalf * 0.9
        let chB = length - m - chHalf * 0.9
        if chB > chA, chHalf > halfW * 0.12 {
            let ch = CGPath(roundedRect: CGRect(x: -chHalf, y: chA, width: chHalf * 2, height: chB - chA),
                            cornerWidth: chHalf, cornerHeight: chHalf, transform: nil)
            let lume = palette.lume.blended(dim: dim)
            // Shallow recess: the lit-side interior edge takes a *whisper* of
            // the lip's shadow. A wide dark wash here turns icy blue to mud.
            // On a lume plate the shading is nearly flat instead: a charged
            // lume pip is uniformly bright, and shading it like a recess is
            // what makes painted-on lume look painted on.
            let shade = palette.isLume ? palette.bg : NSColor(hex: "#8fb6bb")
            let nearLit = lume.blended(withFraction: palette.isLume ? 0.08 : 0.20, of: shade) ?? lume
            let farSide = lume.blended(withFraction: palette.isLume ? 0.10 : 0.22, of: .white) ?? lume
            if palette.isLume {
                // Two hands a frame, so one blurred fill each — well inside
                // budget, unlike putting a halo on all 60 markers.
                context.saveGState()
                context.setShadow(offset: .zero, blur: max(1.5, halfW * 0.9),
                                  color: lume.withAlphaComponent(0.6).cgColor)
                context.setFillColor(lume.cgColor)
                context.addPath(ch); context.fillPath()
                context.restoreGState()
            }
            if let cg = gradient([t >= 0 ? farSide : nearLit, lume, t >= 0 ? nearLit : farSide], [0, 0.5, 1]) {
                context.saveGState()
                context.addPath(ch); context.clip()
                context.drawLinearGradient(cg, start: CGPoint(x: -chHalf, y: 0), end: CGPoint(x: chHalf, y: 0),
                                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
            context.setStrokeColor(NSColor(calibratedRed: 0.17, green: 0.36, blue: 0.36, alpha: 0.20).cgColor)
            context.setLineWidth(max(0.5, halfW * 0.055))
            context.addPath(ch); context.strokePath()
        }
        context.restoreGState()
    }

    /// The one place a Bauhaus dial takes a colour that isn't from its plate.
    /// Adaptive keeps the hand the same white as the other two — a raised
    /// part, not a mark cut into the plate; drawn in `mark` it would read as a
    /// scratch across the dial. Any other accent paints the hairline that hue.
    /// nil for Adaptive — there is no fixed hue, so the two accented parts
    /// (the second hand and the hub's centre dome) keep the hands' colour.
    static func accentTint(defaults: FormzeitDefaults) -> NSColor? {
        defaults.accentV2.hex.map { NSColor(hex: $0) }
    }

    static func secondHandColor(palette: Palette, defaults: FormzeitDefaults) -> NSColor {
        if let tint = accentTint(defaults: defaults) { return tint }
        guard palette.isLume else { return palette.hand }
        // A lume plate's `hand` is a deliberately muted steel so the baton
        // bodies don't outshine the lume they carry. On a hairline that thin
        // it's near-invisible against a near-black plate, so the second hand
        // gets the brighter steel the wide hands can't have.
        return palette.hand.blended(withFraction: 0.45, of: .white) ?? palette.hand
    }

    private static func drawSecondHand(context: CGContext, center: CGPoint, R: CGFloat, angle: CGFloat,
                                        palette: Palette, dim: CGFloat, color: NSColor) {
        // No shadow here on purpose: on a hairline this thin it is not
        // visible, and it measured ~8x the cost of drawing the hand itself.
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: -angle)
        context.setStrokeColor(color.blended(dim: dim).cgColor)
        context.setLineWidth(R * 0.0075)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 0, y: -R * 0.15))
        context.addLine(to: CGPoint(x: 0, y: R * secondLen))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Hub

    /// Four stacked layers: collar, boss stepped up off it, dark bearing
    /// annulus, centre dome. The step's edge between collar and boss is what
    /// sells the depth — one disc with a dot in it reads flat however
    /// carefully it is shaded.
    ///
    /// `tint` colours only the centre dome, so it matches the second hand
    /// seated on it. The dark bearing annulus around it stays dark on
    /// purpose: it's the frame that keeps a saturated dot from smearing into
    /// the pale boss underneath.
    private static func drawHub(context: CGContext, center: CGPoint, R: CGFloat,
                                 palette: Palette, dim: CGFloat, tint: NSColor?) {
        let r = R * hubR
        let base = palette.hand.blended(dim: dim)

        func domeFill(_ rad: CGFloat, _ lo: NSColor, _ hi: NSColor) {
            guard let g = gradient([hi, lo], [0, 1]) else { return }
            context.saveGState()
            context.addEllipse(in: circleRect(center, rad)); context.clip()
            context.drawLinearGradient(g,
                start: CGPoint(x: center.x + LX * rad, y: center.y + LY * rad),
                end: CGPoint(x: center.x - LX * rad, y: center.y - LY * rad),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }

        // 1. Collar — widest layer, carries the hub's shadow onto the plate.
        context.saveGState()
        context.setShadow(offset: CGSize(width: r * 0.16, height: -r * 0.36), blur: r * 1.6,
                          color: NSColor(calibratedRed: 0.09, green: 0.23, blue: 0.22, alpha: 0.34).cgColor)
        context.setFillColor(base.cgColor)
        context.fillEllipse(in: circleRect(center, r))
        context.restoreGState()
        domeFill(r, base.blended(withFraction: 0.40, of: NSColor(hex: "#adbcbc")) ?? base,
                 base.blended(withFraction: 0.45, of: .white) ?? base)
        context.setStrokeColor(NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.27, alpha: 0.18).cgColor)
        context.setLineWidth(max(0.6, r * 0.045))
        context.strokeEllipse(in: circleRect(center, r))

        // 2. Boss — stepped up off the collar, with its own contact shadow.
        let br = r * 0.76
        context.saveGState()
        context.setShadow(offset: CGSize(width: br * 0.10, height: -br * 0.20), blur: br * 0.55,
                          color: NSColor(calibratedRed: 0.09, green: 0.23, blue: 0.22, alpha: 0.26).cgColor)
        context.setFillColor(base.cgColor)
        context.fillEllipse(in: circleRect(center, br))
        context.restoreGState()
        domeFill(br, base.blended(withFraction: 0.30, of: NSColor(hex: "#bcc9c9")) ?? base,
                 base.blended(withFraction: 0.60, of: .white) ?? base)
        context.setStrokeColor(NSColor(calibratedRed: 0.17, green: 0.31, blue: 0.31, alpha: 0.16).cgColor)
        context.setLineWidth(max(0.5, br * 0.05))
        context.strokeEllipse(in: circleRect(center, br))

        // 3. Bearing annulus — sunk into the boss, so it is lit on the
        //    lower-right, the inverse of every raised part above.
        let ao = r * 0.44
        let ringLo = palette.isDark ? NSColor(hex: "#080c0f") : NSColor(hex: "#5e6d6d")
        let ringHi = palette.isDark ? NSColor(hex: "#39434c") : NSColor(hex: "#97a5a5")
        domeFill(ao, ringHi.blended(dim: dim), ringLo.blended(dim: dim))

        // 4. Centre dome seated in the ring.
        let ai = r * 0.30
        if let tint = tint?.blended(dim: dim) {
            // Shade a saturated dome toward black/white rather than through
            // the cool grey the pale version uses — that grey is what gives
            // white its metal read, but it desaturates a hue to putty.
            //
            // On a lume plate the shaded half is pulled up hard: a dot this
            // small, shaded 30% toward black, loses its lower edge into a
            // near-black plate and stops reading as a dome at all.
            let lo: CGFloat = palette.isLume ? 0.12 : 0.30
            let hi: CGFloat = palette.isLume ? 0.52 : 0.42
            domeFill(ai, tint.blended(withFraction: lo, of: .black) ?? tint,
                     tint.blended(withFraction: hi, of: .white) ?? tint)
        } else {
            domeFill(ai, base.blended(withFraction: 0.34, of: NSColor(hex: "#9fb0b0")) ?? base,
                     base.blended(withFraction: 0.70, of: .white) ?? base)
        }
    }

    // MARK: - Small helpers

    /// `b` in -1...1: positive lifts toward white, negative sinks toward a
    /// cool grey. One light model shared by every raised surface here.
    private static func lightMix(_ c: NSColor, _ b: CGFloat) -> NSColor {
        if b >= 0 { return c.blended(withFraction: min(1, b) * 0.55, of: .white) ?? c }
        return c.blended(withFraction: min(1, -b) * 0.55, of: NSColor(hex: "#b9c6c6")) ?? c
    }

    private static func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: colors.map { $0.cgColor } as CFArray,
                   locations: locations)
    }
}
