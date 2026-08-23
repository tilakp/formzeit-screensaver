import ScreenSaver

/// Thin typed wrapper around ScreenSaverDefaults. macOS gives every
/// screensaver module its own defaults domain, keyed by module name, that
/// stays valid whether the module is driven from System Settings or from
/// our own preview harness.
final class FormzeitDefaults {
    static let moduleName = "com.tilakpatel.formzeit"

    private let store: UserDefaults

    init() {
        store = ScreenSaverDefaults(forModuleWithName: FormzeitDefaults.moduleName) ?? .standard
        registerFactoryDefaults()
        migrateAccentIfNeeded()
    }

    /// An ephemeral, throwaway defaults domain seeded with a specific
    /// face/world/accent — never touches the real saved settings. Used only
    /// so the settings sheet's face picker can render its thumbnails with
    /// the exact same renderer real settings drive, at a fixed time,
    /// regardless of what's currently saved.
    init(transientFace face: FaceKind, world: ColorWorld, accent: Accent) {
        store = UserDefaults(suiteName: "formzeit.transient.\(UUID().uuidString)") ?? .standard
        registerFactoryDefaults()
        store.set(face.rawValue, forKey: Keys.face)
        store.set(world.rawValue, forKey: Keys.world)
        store.set(accent.rawValue, forKey: Keys.accent)
    }

    private func registerFactoryDefaults() {
        store.register(defaults: [
            Keys.accentIndex: 0,
            Keys.movement: Movement.mechanical.rawValue,
            Keys.use24Hour: false,
            Keys.burnInProtection: true,
            Keys.nightDimming: true,
            Keys.face: FaceKind.bauhaus.rawValue,
            Keys.world: ColorWorld.ember.rawValue,
            Keys.accent: Accent.adaptive.rawValue,
            Keys.showNumerals: false,
            Keys.bauhausPalette: "lagoon",
        ])
    }

    /// v1's `accentIndex` (0...5 into the old Braun-named swatch list) maps
    /// index-for-index onto the new `Accent` cases — same six colors,
    /// renamed/recolored. Only migrate if the user actually had a saved
    /// choice (the key exists in the store, not just the registered
    /// fallback) and hasn't already picked a v2 accent, so a fresh install
    /// keeps the new Adaptive default instead of landing on Lumen.
    private func migrateAccentIfNeeded() {
        guard store.object(forKey: Keys.accent) == nil else { return }
        guard store.object(forKey: Keys.accentIndex) != nil else { return }
        let idx = clamp(store.integer(forKey: Keys.accentIndex), 0, AccentColor.all.count - 1)
        store.set(Accent.migrated(fromLegacyIndex: idx).rawValue, forKey: Keys.accent)
        save()
    }

    private enum Keys {
        static let accentIndex = "accentIndex"
        static let movement = "movement"
        static let use24Hour = "use24Hour"
        static let burnInProtection = "burnInProtection"
        static let nightDimming = "nightDimming"
        static let face = "face"
        static let world = "world"
        static let accent = "accent"
        static let showNumerals = "showNumerals"
        static let bauhausPalette = "bauhausPalette"
    }

    /// Which flat-colour plate the Bauhaus face draws (Lagoon, Pistachio, …).
    /// Separate from `world`, which drives the light-based faces only.
    var bauhausPalette: String {
        get { store.string(forKey: Keys.bauhausPalette) ?? "lagoon" }
        set { store.set(newValue, forKey: Keys.bauhausPalette); save() }
    }

    var accentIndex: Int {
        get { clamp(store.integer(forKey: Keys.accentIndex), 0, AccentColor.all.count - 1) }
        set { store.set(newValue, forKey: Keys.accentIndex); save() }
    }

    /// Classic face's fixed accent color (legacy swatch list).
    var accent: AccentColor { AccentColor.all[accentIndex] }

    var movement: Movement {
        get { Movement(rawValue: store.string(forKey: Keys.movement) ?? "") ?? .mechanical }
        set { store.set(newValue.rawValue, forKey: Keys.movement); save() }
    }

    var use24Hour: Bool {
        get { store.bool(forKey: Keys.use24Hour) }
        set { store.set(newValue, forKey: Keys.use24Hour); save() }
    }

    /// v2 label: "Move the light" — also gates the Eclipse/Strata/Filament
    /// light-source orbit, not just the old translation drift and idle ramp.
    var burnInProtection: Bool {
        get { store.bool(forKey: Keys.burnInProtection) }
        set { store.set(newValue, forKey: Keys.burnInProtection); save() }
    }

    /// v2 label: "Follow the day" — gates the diel colour/luminance curve
    /// for Eclipse/Strata/Filament (off = pinned to the midday stop) in
    /// addition to its original night-window dimming role for Classic.
    var nightDimming: Bool {
        get { store.bool(forKey: Keys.nightDimming) }
        set { store.set(newValue, forKey: Keys.nightDimming); save() }
    }

    var face: FaceKind {
        get { FaceKind(rawValue: store.string(forKey: Keys.face) ?? "") ?? .eclipse }
        set { store.set(newValue.rawValue, forKey: Keys.face); save() }
    }

    var world: ColorWorld {
        get { ColorWorld(rawValue: store.string(forKey: Keys.world) ?? "") ?? .ember }
        set { store.set(newValue.rawValue, forKey: Keys.world); save() }
    }

    /// v2 accent — tints the diel light, or passes it through unchanged for
    /// `.adaptive`. Drives Eclipse/Strata/Filament, and (as a fixed hue, or
    /// the current diel light color when Adaptive) Classic's second hand too.
    var accentV2: Accent {
        get { Accent(rawValue: store.string(forKey: Keys.accent) ?? "") ?? .adaptive }
        set { store.set(newValue.rawValue, forKey: Keys.accent); save() }
    }

    var showNumerals: Bool {
        get { store.bool(forKey: Keys.showNumerals) }
        set { store.set(newValue, forKey: Keys.showNumerals); save() }
    }

    private func save() {
        if let ssd = store as? ScreenSaverDefaults {
            ssd.synchronize()
        }
        NotificationCenter.default.post(name: .formzeitSettingsChanged, object: self)
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }
}

extension Notification.Name {
    static let formzeitSettingsChanged = Notification.Name("FormzeitSettingsChanged")
}
