import Cocoa

/// Curated Bauhaus-inspired accent colors. One accent drives the seconds hand
/// and center hub — everything else in the dial stays neutral, in keeping
/// with the "one disciplined accent" language of the reference clock.
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
    case digital

    var displayName: String {
        switch self {
        case .quartz: return "Quartz"
        case .mechanical: return "Mechanical"
        case .digital: return "Digital"
        }
    }
}

/// Fixed neutral tones for the dial itself — deliberately near-black so the
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
