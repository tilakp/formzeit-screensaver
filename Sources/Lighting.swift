import Cocoa

/// One computed lighting snapshot shared by Eclipse/Strata/Filament for a
/// given frame: the diel-driven field/light/plate colours (§3), the overall
/// dim multiplier (diel luminance × idle burn-in ramp), and the orbiting
/// light source's phase. Classic keeps its own `ClassicFace.Lighting` — its
/// night-window dim curve and shadow model are a different, simpler thing
/// this struct doesn't need to subsume.
struct DielLighting {
    let field: NSColor
    let light: NSColor
    let light2: NSColor?      // second source, Duplex world only
    let plate: NSColor
    let lum: CGFloat          // diel luminance alone (0...1) — day/night, no idle ramp
    let dim: CGFloat          // lum × idle ramp — the "L" multiplier the spec's tables use
    let sourceAngle: CGFloat  // primary light source's orbital phase, radians
    let source2Angle: CGFloat? // Duplex's second source, ~135° offset, orbiting together
    let reduceMotion: Bool

    /// `reduceMotion` freezes the orbit at its mean position (§9); the diel
    /// drift itself is never frozen — 24h is below any perceptual motion
    /// threshold, per the same accessibility table.
    init(now: Date, elapsedRunTime: TimeInterval, isPreview: Bool, reduceMotion: Bool, defaults: FormzeitDefaults) {
        let raw: (field: Oklab, light: Oklab, lum: CGFloat)
        if defaults.nightDimming {
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute, .second], from: now)
            let minutesOfDay = Double((c.hour ?? 12) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60.0
            raw = Self.diel(minutesOfDay: minutesOfDay)
        } else {
            // "Follow the day" off: pin to the midday stop rather than
            // running the curve, so brightness/colour stay fixed.
            raw = Self.diel(minutesOfDay: 12 * 60)
        }

        let world = defaults.world
        let worldLight = toOklab(NSColor(hex: world.lightHex))
        let worldField = toOklab(NSColor(hex: world.fieldHex))
        // Rotate toward the world's hue while preserving each stop's own L,
        // so the day's luminance arc survives a world change untouched.
        var fieldOk = mix(raw.field, worldField, 0.75); fieldOk.L = raw.field.L
        var lightOk = mix(raw.light, worldLight, 0.55); lightOk.L = raw.light.L

        let accent = defaults.accentV2
        if let hex = accent.hex {
            lightOk = mix(lightOk, toOklab(NSColor(hex: hex)), 0.65)
        }

        var light2Ok: Oklab?
        if world == .duplex, let secondHex = world.secondaryLightHex {
            var l2 = mix(raw.light, toOklab(NSColor(hex: secondHex)), 0.55); l2.L = raw.light.L
            if let hex = accent.hex { l2 = mix(l2, toOklab(NSColor(hex: hex)), 0.65) }
            light2Ok = l2
        }

        // Never exactly the field — an object in front of the light, not a
        // hole in it (§3.5). Too little to read as a colour on its own.
        let plateOk = mix(fieldOk, lightOk, 0.06)

        field = fromOklab(fieldOk)
        light = fromOklab(lightOk)
        light2 = light2Ok.map(fromOklab)
        plate = fromOklab(plateOk)
        lum = raw.lum

        if isPreview {
            dim = 1.0
        } else if defaults.burnInProtection {
            let rampStart = 300.0, rampEnd = 2700.0 // floor by 45 min
            let floor = 0.35
            var idle: CGFloat = 1.0
            if elapsedRunTime > rampStart {
                let p = min(1.0, (elapsedRunTime - rampStart) / (rampEnd - rampStart))
                idle = CGFloat(1.0 - Self.smoothstep(p) * (1.0 - floor))
            }
            dim = CGFloat(raw.lum) * idle
        } else {
            dim = raw.lum
        }

        // Continuous absolute time (not elapsed-run-time) so the orbit
        // phase doesn't reset to the same spot every relaunch — matches the
        // discipline of the old drift offset, which used the same clock for
        // the same reason.
        let motionFrozen = isPreview || reduceMotion || !defaults.burnInProtection
        let phase = motionFrozen ? 0.0 : now.timeIntervalSinceReferenceDate / (92.0 * 60.0) * 2 * Double.pi
        sourceAngle = CGFloat(phase)
        source2Angle = world == .duplex ? sourceAngle + 2.35 : nil
        self.reduceMotion = reduceMotion
    }

    /// The diel light color alone at a given hour of day (0..<24), with no
    /// world/accent bending applied. Used by the settings sheet's Adaptive
    /// accent swatch to paint an approximate conic sweep of the day.
    static func previewLightSample(hourOfDay: Double) -> Oklab {
        diel(minutesOfDay: hourOfDay * 60).light
    }

    /// World position of a light source at the given orbital phase.
    /// `1.31` on the y term so the path never traces the same ellipse twice.
    static func sourcePosition(center: CGPoint, S: CGFloat, theta: CGFloat) -> CGPoint {
        CGPoint(x: center.x + 0.10 * S * cos(theta),
                y: center.y + 0.06 * S * sin(theta * 1.31))
    }

    private static func diel(minutesOfDay: Double) -> (field: Oklab, light: Oklab, lum: CGFloat) {
        let H = (minutesOfDay / 60.0).truncatingRemainder(dividingBy: 24)
        var i = 0
        for k in dielStops.indices where dielStops[k].h <= H { i = k }
        let a = dielStops[i], b = dielStops[(i + 1) % dielStops.count]
        var span = b.h - a.h; if span <= 0 { span += 24 }
        var d = H - a.h; if d < 0 { d += 24 }
        let raw = span == 0 ? 0 : d / span
        let t = smoothstep(raw)
        return (mix(a.field, b.field, t), mix(a.light, b.light, t), CGFloat(a.lum + (b.lum - a.lum) * t))
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Wake-in easing (§6): an ease-out-cubic ramp from 0 to 1 over `duration`
/// seconds, starting `delay` seconds after `startAnimation()`. Shared so
/// every face's wake-in (the field/plate fading up, apertures staggered
/// slightly behind them) reads as one consistent event rather than each
/// face inventing its own curve. Always 1 for the System Settings preview
/// thumbnail (which should just look correct immediately) and for
/// reduce-motion (§9 — wake-in is dropped, not just slowed).
func wakeEase(elapsedRunTime: TimeInterval, delay: TimeInterval, duration: TimeInterval, isPreview: Bool,
              reduceMotion: Bool = false) -> CGFloat {
    guard !isPreview, !reduceMotion else { return 1.0 }
    let t = min(max((elapsedRunTime - delay) / duration, 0), 1)
    return CGFloat(1 - pow(1 - t, 3))
}

/// A single grayscale noise field, generated once and reused every frame by
/// every face. Values cluster around mid-gray (128) so, drawn with
/// `.softLight`, it nudges pixels lighter or darker without a visible cast —
/// the cheapest thing in the renderer and the only reason a full-screen dark
/// gradient doesn't band into visible rings on an 8-bit panel.
let sharedNoiseImage: CGImage? = {
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

/// Rotates a point `(x, y)` in a hand-local frame (x lateral, y outward)
/// by clock angle `theta` around center `c`, in CoreGraphics' y-up space.
/// Shared by every face that draws capsule hands/marks (Eclipse, Classic).
@inline(__always)
func local(_ c: CGPoint, _ theta: CGFloat, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let s = sin(theta), co = cos(theta)
    return CGPoint(x: c.x + x * co + y * s,
                   y: c.y - x * s + y * co)
}
