import Cocoa

// Geometry audit for the dial. Renders FormzeitRenderer straight into a
// bitmap (no window, no screensaver host) and then measures the resulting
// pixels, so every check reflects what is actually drawn rather than what
// the placement math intended.
//
// Per hour numeral it reports:
//   r        radial distance of the glyph's ink centre from the dial centre
//   tang     tangential offset from the slot's ray — how far off-centre the
//            numeral sits between its two flanking ticks (should be ~0)
//   top/bot  outward and inward radial extent of the ink
//   gap      smallest distance from the numeral's ink to any tick pixel
//
// Consistent r and top across all twelve means the ring is true; tang near
// zero means each numeral is centred on its hour ray; gap is the clearance
// the eye reads as "touching" when it gets small.

let W = 2000, H = 2000
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("cannot create context"); exit(1)
}

// Fixed instant so the audit is deterministic. Hand angles are irrelevant to
// the numeral geometry, and hand pixels are filtered out below.
let when = Date(timeIntervalSince1970: 1786820400)
let defaults = FormzeitDefaults()
// This audit's geometry checks are all Classic-dial constants (ring/tick/
// numeral placement); audit.sh pins the real settings domain to `face =
// classic` for the run, but pin it here too so the tool is self-contained
// if run against a domain that was never touched.
defaults.face = .classic
FormzeitRenderer.render(context: ctx, bounds: CGRect(x: 0, y: 0, width: W, height: H),
                        now: when, elapsedRunTime: 0, isPreview: false, defaults: defaults)

guard let image = ctx.makeImage(), let dp = image.dataProvider, let pix = dp.data,
      let base = CFDataGetBytePtr(pix) else { print("no image"); exit(1) }
let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8

// Sample in maths coordinates (y up), matching the renderer.
func lum(_ x: Int, _ y: Int) -> Int {
    guard x >= 0, x < W, y >= 0, y < H else { return 0 }
    let row = H - 1 - y
    let o = row * bpr + x * bpp
    return (Int(base[o]) + Int(base[o + 1]) + Int(base[o + 2])) / 3
}

// Dial centre and radius, measured from the rendered bezel rather than
// assumed, so slow burn-in drift can't skew the numbers.
var minX = W, maxX = 0, minY = H, maxY = 0
for y in 0..<H {
    for x in 0..<W where lum(x, y) > 35 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
// The dial is a symmetric disc, so its bounding box centre is its centre
// even with burn-in drift applied. The radius is the renderer's own
// definition rather than anything inferred from the bezel's soft edge.
let cx = CGFloat(minX + maxX) / 2, cy = CGFloat(minY + maxY) / 2
let R = CGFloat(min(W, H)) * 0.44

// Tick geometry is reproduced analytically from the renderer's constants,
// not detected by brightness: a glyph's own antialiased edge falls in the
// same brightness range as a tick, which made every measured clearance come
// out as 1px regardless of the real spacing.
let tickOuter = R * ClassicFace.tickOuterEdge
let tickInner = tickOuter - R * ClassicFace.tickLength
let tickHalfW = R * ClassicFace.tickWidth / 2
struct Tick { let ax: CGFloat, ay: CGFloat, bx: CGFloat, by: CGFloat }
let ticks: [Tick] = (0..<60).filter { $0 % 5 != 0 }.map { i in
    let phi = CGFloat.pi / 2 - CGFloat(i) / 60 * 2 * .pi
    return Tick(ax: cx + tickInner * cos(phi), ay: cy + tickInner * sin(phi),
                bx: cx + tickOuter * cos(phi), by: cy + tickOuter * sin(phi))
}
func distToTicks(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
    var best = CGFloat.infinity
    for t in ticks {
        let vx = t.bx - t.ax, vy = t.by - t.ay
        let wx = x - t.ax, wy = y - t.ay
        let len2 = vx * vx + vy * vy
        let s = max(0, min(1, (wx * vx + wy * vy) / len2))
        let dx = wx - s * vx, dy = wy - s * vy
        best = min(best, (dx * dx + dy * dy).squareRoot() - tickHalfW)
    }
    return best
}

var numeralMask = [Bool](repeating: false, count: W * H)
for y in 0..<H {
    for x in 0..<W where lum(x, y) > 200 {
        let dx = CGFloat(x) - cx, dy = CGFloat(y) - cy
        let r = (dx * dx + dy * dy).squareRoot() / R
        if r > 0.55 && r < 1.02 { numeralMask[y * W + x] = true }
    }
}

struct Blob { var pts: [(CGFloat, CGFloat)] = []; var minX = CGFloat.infinity, maxX = -CGFloat.infinity
              var minY = CGFloat.infinity, maxY = -CGFloat.infinity }

var seen = [Bool](repeating: false, count: W * H)
var blobs: [Blob] = []
for y in 0..<H {
    for x in 0..<W where numeralMask[y * W + x] && !seen[y * W + x] {
        var b = Blob(); var stack = [(x, y)]; seen[y * W + x] = true
        while let (px, py) = stack.popLast() {
            b.pts.append((CGFloat(px), CGFloat(py)))
            b.minX = min(b.minX, CGFloat(px)); b.maxX = max(b.maxX, CGFloat(px))
            b.minY = min(b.minY, CGFloat(py)); b.maxY = max(b.maxY, CGFloat(py))
            for (nx, ny) in [(px+1,py),(px-1,py),(px,py+1),(px,py-1)] {
                guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                if numeralMask[ny * W + nx] && !seen[ny * W + nx] { seen[ny * W + nx] = true; stack.append((nx, ny)) }
            }
        }
        blobs.append(b)
    }
}
// A glyph is compact and radially thin; a hand crossing the ring is a long
// radial streak. Filtering on radial thickness rejects the minute hand's
// fragment, which is short enough to slip past a bounding-box test alone.
func radialSpan(_ b: Blob) -> CGFloat {
    var lo = CGFloat.infinity, hi = -CGFloat.infinity
    for (x, y) in b.pts {
        let dx = x - cx, dy = y - cy
        let r = (dx * dx + dy * dy).squareRoot()
        lo = min(lo, r); hi = max(hi, r)
    }
    return hi - lo
}
let glyphs = blobs.filter {
    max($0.maxX - $0.minX, $0.maxY - $0.minY) < R * 0.22 && $0.pts.count > 200 && radialSpan($0) < R * 0.13
}

print(String(format: "dial centre (%.1f, %.1f)  R=%.1f px   glyph blobs found: %d", cx, cy, R, glyphs.count))

// Raw pixel extents can't be compared between glyphs directly — a "1" and a
// "7" have different ink shapes, so their bounding boxes legitimately differ
// even when both are placed perfectly. Each measurement is therefore
// converted back into the quantity it was supposed to encode: the ring
// radius the glyph's cap line implies, and its offset from the hour ray.
// Those *are* comparable, so any spread between them is real misplacement.
let auditFont = ClassicFace.numeralFont(size: R * ClassicFace.numeralFontScale, medium: true)
func inkBounds(_ s: String) -> CGRect {
    CTLineGetBoundsWithOptions(
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: auditFont])),
        [.useGlyphPathBounds])
}
print("slot | impliedR/R | tangOff/R |  gap/R  | gap px")
print("-----+------------+-----------+---------+-------")

// Merge blobs belonging to the same numeral ("10" is two blobs, "8" is one
// but a hollow "0" stays connected), by assigning each to its nearest slot.
var perSlot: [Int: [Blob]] = [:]
for g in glyphs {
    let gx = (g.minX + g.maxX) / 2 - cx, gy = (g.minY + g.maxY) / 2 - cy
    let ang = atan2(gy, gx)
    var best = 0; var bestD = CGFloat.infinity
    for i in 0..<12 {
        let slot = CGFloat.pi / 2 - CGFloat(i) / 12 * 2 * .pi
        var d = abs(atan2(sin(ang - slot), cos(ang - slot)))
        if d > .pi { d = 2 * .pi - d }
        if d < bestD { bestD = d; best = i }
    }
    perSlot[best, default: []].append(g)
}

var implied: [CGFloat] = [], tangs: [CGFloat] = [], gaps: [CGFloat] = []
for i in 0..<12 {
    let label = i == 0 ? 12 : i
    guard let parts = perSlot[i], !parts.isEmpty else { print(String(format: "  %2d | MISSING", label)); continue }
    let pts = parts.flatMap { $0.pts }
    let slot = CGFloat.pi / 2 - CGFloat(i) / 12 * 2 * .pi
    let ux = cos(slot), uy = sin(slot)      // along the ray
    let px = -sin(slot), py = cos(slot)     // perpendicular to it

    // Measure the ink box in screen axes. The numerals stay upright while the
    // hour rays rotate, so projecting onto a ray would fold the glyph's width
    // into what is meant to be a height measurement — only for the vertical
    // slots would it read correctly.
    var bxMin = CGFloat.infinity, bxMax = -CGFloat.infinity
    var byMin = CGFloat.infinity, byMax = -CGFloat.infinity
    var gap = CGFloat.infinity
    for (x, y) in pts {
        bxMin = min(bxMin, x); bxMax = max(bxMax, x)
        byMin = min(byMin, y); byMax = max(byMax, y)
        gap = min(gap, distToTicks(x, y))
    }

    // Solve back for the placement point this glyph implies: drawNumeral
    // centres the ink horizontally and puts the cap-height midpoint on it.
    // Recovering that point removes the glyph's shape entirely, so the twelve
    // results are directly comparable.
    let ink = inkBounds(String(label))
    let impliedX = (bxMin + bxMax) / 2
    let impliedY = byMax - (ink.maxY - auditFont.capHeight / 2)
    let dx = impliedX - cx, dy = impliedY - cy
    let impliedRadius = (dx * dx + dy * dy).squareRoot()
    var angErr = atan2(dy, dx) - slot
    while angErr > .pi { angErr -= 2 * .pi }
    while angErr < -.pi { angErr += 2 * .pi }
    let tangOffset = impliedRadius * sin(angErr)
    _ = (ux, uy, px, py)

    implied.append(impliedRadius / R); tangs.append(tangOffset / R); gaps.append(gap / R)
    print(String(format: "  %2d |   %6.4f   | %+9.5f | %6.4f | %5.1f",
                 label, impliedRadius / R, tangOffset / R, gap / R, gap))
}

func spread(_ v: [CGFloat]) -> CGFloat { (v.max() ?? 0) - (v.min() ?? 0) }
print("")
print(String(format: "impliedR spread  %.5f R   (ring roundness; want < 0.003)", spread(implied)))
print(String(format: "max |tangOff|    %.5f R   (ray centring; want < 0.003)", tangs.map { abs($0) }.max() ?? 0))
print(String(format: "min gap          %.5f R   (tick clearance; want > 0.010)", gaps.min() ?? 0))

// Numerals and ticks are meant to be centred on the same circle and to be
// comparable in size, the way they are on the reference clock.
let meanRing = implied.reduce(0, +) / CGFloat(implied.count)
let tickBandCentre = ClassicFace.tickOuterEdge - ClassicFace.tickLength / 2
let capH = auditFont.capHeight / R
print("")
print(String(format: "numeral ring     %.4f R   vs tick band centre %.4f R  (offset %+.4f R)",
             meanRing, tickBandCentre, meanRing - tickBandCentre))
print(String(format: "numeral capH     %.4f R   vs tick length      %.4f R  (ratio %.2fx)",
             capH, ClassicFace.tickLength, capH / ClassicFace.tickLength))

// MARK: - §8 performance budget: Eclipse mean frame luminance
//
// Informational, not asserted — a hard ≤6%/≤12% pass/fail needs display-
// referred luminance and a broader time sweep than is worth building into
// this tool right now. This renders Eclipse at a few points across the diel
// curve and reports mean pixel luminance so a regression that blows past
// the budget (e.g. an accidentally opaque plate) is at least visible here.
//
// Measured at a real screen aspect ratio (3008x1692, the resolution §11.4
// names), not the square 2000x2000 canvas the geometry audit above uses —
// the field gradient's falloff radius is a fraction of `S = min(w,h)`, so a
// square canvas puts proportionally more of the frame inside the bright
// falloff than a real widescreen display would. Measuring square
// overstates luminance and would chase a budget the shipped renderer never
// actually approaches.
func meanLuminance(face: FaceKind, hour: Int, minute: Int, w: Int, h: Int) -> Double {
    guard let c2 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    let d2 = FormzeitDefaults()
    d2.face = face
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 1; comps.hour = hour; comps.minute = minute
    let date = Calendar.current.date(from: comps) ?? Date()
    // elapsedRunTime must be past wake-in (§6, ~1.4s to fully reveal) and
    // well before the idle burn-in ramp engages (300s) — 0 would measure
    // the wake-in veil's opening (deliberately black) frame instead of
    // steady-state brightness.
    FormzeitRenderer.render(context: c2, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                             now: date, elapsedRunTime: 10, isPreview: false, defaults: d2)
    guard let img = c2.makeImage(), let dp2 = img.dataProvider, let pix2 = dp2.data,
          let base2 = CFDataGetBytePtr(pix2) else { return 0 }
    let bpr2 = img.bytesPerRow, bpp2 = img.bitsPerPixel / 8
    var total: UInt64 = 0
    let stride = 4 // sample every 4th pixel in each axis — plenty for a mean
    var count = 0
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let o = y * bpr2 + x * bpp2
            total += UInt64(base2[o]) + UInt64(base2[o + 1]) + UInt64(base2[o + 2])
            count += 3
            x += stride
        }
        y += stride
    }
    return Double(total) / Double(count) / 255.0
}

print("")
print("eclipse mean luminance by hour, 3008x1692 (§8 targets: <=6% night, <=12% day)")
for (label, h, m) in [("00:00", 0, 0), ("07:30", 7, 30), ("12:00", 12, 0), ("18:30", 18, 30), ("22:00", 22, 0)] {
    let l = meanLuminance(face: .eclipse, hour: h, minute: m, w: 3008, h: 1692)
    print(String(format: "  %@  %.2f%%", label, l * 100))
}
