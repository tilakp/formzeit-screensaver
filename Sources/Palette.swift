import Cocoa

/// Curated Bauhaus-inspired accent colors for the Classic (BC12) face. One
/// accent drives the seconds hand and center hub — everything else in the
/// dial stays neutral, in keeping with the "one disciplined accent" language
/// of the reference clock.
struct AccentColor {
    let name: String
    let color: NSColor

    static let all: [AccentColor] = [
        AccentColor(name: "Braun Yellow", color: NSColor(calibratedRed: 0.949, green: 0.663, blue: 0.000, alpha: 1.0)),
        AccentColor(name: "Bauhaus Red", color: NSColor(calibratedRed: 0.839, green: 0.251, blue: 0.122, alpha: 1.0)),
        AccentColor(name: "Bauhaus Blue", color: NSColor(calibratedRed: 0.071, green: 0.337, blue: 0.627, alpha: 1.0)),
        AccentColor(name: "Signal Orange", color: NSColor(calibratedRed: 0.910, green: 0.349, blue: 0.047, alpha: 1.0)),
        AccentColor(name: "Pistachio", color: NSColor(calibratedRed: 0.561, green: 0.663, blue: 0.533, alpha: 1.0)),
        AccentColor(name: "Silver", color: NSColor(calibratedRed: 0.847, green: 0.847, blue: 0.847, alpha: 1.0)),
    ]
}

enum Movement: String, CaseIterable {
    case quartz
    case mechanical
    case digital // rawValue kept for persisted-defaults compatibility; display name is "Sweep" per v2.

    var displayName: String {
        switch self {
        case .quartz: return "Quartz"
        case .mechanical: return "Mechanical"
        case .digital: return "Sweep"
        }
    }
}

/// Which face is drawn. Classic is the original BC12 dial, kept as a fourth
/// option per product decision — cheap to keep, protects users who liked it.
enum FaceKind: String, CaseIterable {
    case eclipse
    case strata
    case filament
    case classic

    var displayName: String {
        switch self {
        case .eclipse: return "Eclipse"
        case .strata: return "Strata"
        case .filament: return "Filament"
        case .classic: return "Classic"
        }
    }
}

/// Fixed neutral tones for the Classic dial — deliberately near-black so the
/// screensaver stays a mostly-dark-pixel composition (kinder to OLED/plasma
/// panels regardless of whether burn-in protection is switched on).
enum DialPalette {
    static let background = NSColor.black
    static let face = NSColor(calibratedWhite: 0.071, alpha: 1.0)
    static let bezelLight = NSColor(calibratedWhite: 0.30, alpha: 1.0)
    static let bezelDark = NSColor(calibratedWhite: 0.12, alpha: 1.0)
    static let ink = NSColor(calibratedWhite: 0.91, alpha: 1.0)
    static let inkDim = NSColor(calibratedWhite: 0.60, alpha: 1.0)
}

// MARK: - v2 colour system (§3)
//
// Three layers, applied in order: a world picks the hue family, the diel
// curve moves it through the day, an accent bends it. Everything downstream
// (Eclipse/Strata/Filament) reads through `DielLighting` (Lighting.swift),
// not these types directly.

extension NSColor {
    /// `#RRGGBB` (leading `#` optional) → sRGB color. Every v2 hex constant
    /// in this file goes through this initializer rather than a literal
    /// `NSColor(srgbRed:...)` call, so the spec's hex table stays directly
    /// copyable and diffable against this source.
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

/// Oklab coordinates. Perceptually uniform enough that mixing two hues at
/// their midpoint stays chromatic instead of collapsing to grey-brown the
/// way sRGB-space mixing does — the golden→night diel transition runs 90
/// minutes and is on screen every evening, so the midpoint *is* the design.
struct Oklab {
    var L: Double
    var a: Double
    var b: Double
}

private func srgbToLinear(_ u: Double) -> Double {
    u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
}
private func linearToSrgb(_ u: Double) -> Double {
    u <= 0.0031308 ? u * 12.92 : 1.055 * pow(u, 1.0 / 2.4) - 0.055
}

func toOklab(_ c: NSColor) -> Oklab {
    guard let rgb = c.usingColorSpace(.sRGB) else { return Oklab(L: 0, a: 0, b: 0) }
    let r = srgbToLinear(Double(rgb.redComponent))
    let g = srgbToLinear(Double(rgb.greenComponent))
    let b = srgbToLinear(Double(rgb.blueComponent))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return Oklab(L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                 a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                 b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

func fromOklab(_ c: Oklab) -> NSColor {
    let l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
    let m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
    let s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
    let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    func ch(_ v: Double) -> CGFloat { CGFloat(min(max(linearToSrgb(min(max(v, 0), 1)), 0), 1)) }
    return NSColor(srgbRed: ch(r), green: ch(g), blue: ch(b), alpha: 1)
}

func mix(_ a: Oklab, _ b: Oklab, _ t: Double) -> Oklab {
    Oklab(L: a.L + (b.L - a.L) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t)
}

/// One diel keyframe: a field (ground) colour, a light (emissive) colour,
/// and a luminance multiplier, at a given hour of the day.
struct DielStop {
    let h: Double
    let field: Oklab
    let light: Oklab
    let lum: CGFloat
}

/// Nine stops, wrapped at 24h (§3.2). Hex values converted once at startup.
let dielStops: [DielStop] = [
    DielStop(h: 0.0,  field: toOklab(NSColor(hex: "#04050A")), light: toOklab(NSColor(hex: "#263156")), lum: 0.30),
    DielStop(h: 3.0,  field: toOklab(NSColor(hex: "#030409")), light: toOklab(NSColor(hex: "#1D2647")), lum: 0.26),
    DielStop(h: 5.5,  field: toOklab(NSColor(hex: "#070A14")), light: toOklab(NSColor(hex: "#35507F")), lum: 0.46),
    DielStop(h: 7.5,  field: toOklab(NSColor(hex: "#0B0E14")), light: toOklab(NSColor(hex: "#A8BDD4")), lum: 0.78),
    DielStop(h: 12.0, field: toOklab(NSColor(hex: "#0D0E10")), light: toOklab(NSColor(hex: "#F0EDE6")), lum: 1.00),
    DielStop(h: 16.5, field: toOklab(NSColor(hex: "#100E0C")), light: toOklab(NSColor(hex: "#E8CFA6")), lum: 0.94),
    DielStop(h: 18.5, field: toOklab(NSColor(hex: "#130F0A")), light: toOklab(NSColor(hex: "#F2A03C")), lum: 0.86),
    DielStop(h: 20.0, field: toOklab(NSColor(hex: "#0F0A0F")), light: toOklab(NSColor(hex: "#C4562E")), lum: 0.66),
    DielStop(h: 22.0, field: toOklab(NSColor(hex: "#06070C")), light: toOklab(NSColor(hex: "#46579B")), lum: 0.44),
]

/// A world re-anchors the hue family the diel curve travels through. Ship
/// all six; `Ember` is the default (closest to the current identity).
enum ColorWorld: String, CaseIterable {
    case ember, lunar, sodium, radium, quartz, duplex

    var displayName: String {
        switch self {
        case .ember: return "Ember"
        case .lunar: return "Lunar"
        case .sodium: return "Sodium"
        case .radium: return "Radium"
        case .quartz: return "Quartz"
        case .duplex: return "Duplex"
        }
    }

    var fieldHex: String {
        switch self {
        case .ember: return "#130F0A"
        case .lunar: return "#080A10"
        case .sodium: return "#0E0704"
        case .radium: return "#060B08"
        case .quartz: return "#100A0E"
        case .duplex: return "#07080E"
        }
    }

    var lightHex: String {
        switch self {
        case .ember: return "#F2A03C"
        case .lunar: return "#CFE0F2"
        case .sodium: return "#FF7A2B"
        case .radium: return "#9FE6A0"
        case .quartz: return "#F0A6B6"
        case .duplex: return "#F2A03C"
        }
    }

    /// Second light source, Duplex only.
    var secondaryLightHex: String? {
        self == .duplex ? "#4C86E8" : nil
    }
}

/// Accents tint the light at a fixed Oklab blend of 0.65; they do not
/// replace it. `Adaptive` (the new default) passes the diel light through
/// unchanged — the clock takes the colour of the hour.
enum Accent: String, CaseIterable {
    case adaptive, lumen, vermilion, cobalt, signal, verdigris, bone

    var displayName: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .lumen: return "Lumen"
        case .vermilion: return "Vermilion"
        case .cobalt: return "Cobalt"
        case .signal: return "Signal"
        case .verdigris: return "Verdigris"
        case .bone: return "Bone"
        }
    }

    /// nil for Adaptive — there is no fixed hue to bend toward.
    var hex: String? {
        switch self {
        case .adaptive: return nil
        case .lumen: return "#F2A03C"
        case .vermilion: return "#D8452E"
        case .cobalt: return "#2E6FCB"
        case .signal: return "#E8571C"
        case .verdigris: return "#6FA893"
        case .bone: return "#E6E4DE"
        }
    }

    /// The pre-v2 accent list was these same six colors in this same order,
    /// just renamed/recolored — index-for-index migration for anyone with a
    /// saved `accentIndex`. See `FormzeitDefaults.migrateAccentIfNeeded`.
    static func migrated(fromLegacyIndex idx: Int) -> Accent {
        switch idx {
        case 0: return .lumen
        case 1: return .vermilion
        case 2: return .cobalt
        case 3: return .signal
        case 4: return .verdigris
        default: return .bone
        }
    }
}
