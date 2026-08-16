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
    }

    private func registerFactoryDefaults() {
        store.register(defaults: [
            Keys.accentIndex: 0,
            Keys.movement: Movement.mechanical.rawValue,
            Keys.use24Hour: false,
            Keys.burnInProtection: true,
            Keys.nightDimming: true,
        ])
    }

    private enum Keys {
        static let accentIndex = "accentIndex"
        static let movement = "movement"
        static let use24Hour = "use24Hour"
        static let burnInProtection = "burnInProtection"
        static let nightDimming = "nightDimming"
    }

    var accentIndex: Int {
        get { clamp(store.integer(forKey: Keys.accentIndex), 0, AccentColor.all.count - 1) }
        set { store.set(newValue, forKey: Keys.accentIndex); save() }
    }

    var accent: AccentColor { AccentColor.all[accentIndex] }

    var movement: Movement {
        get { Movement(rawValue: store.string(forKey: Keys.movement) ?? "") ?? .mechanical }
        set { store.set(newValue.rawValue, forKey: Keys.movement); save() }
    }

    var use24Hour: Bool {
        get { store.bool(forKey: Keys.use24Hour) }
        set { store.set(newValue, forKey: Keys.use24Hour); save() }
    }

    var burnInProtection: Bool {
        get { store.bool(forKey: Keys.burnInProtection) }
        set { store.set(newValue, forKey: Keys.burnInProtection); save() }
    }

    var nightDimming: Bool {
        get { store.bool(forKey: Keys.nightDimming) }
        set { store.set(newValue, forKey: Keys.nightDimming); save() }
    }

    private func save() {
        if let ssd = store as? ScreenSaverDefaults {
            ssd.synchronize()
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }
}

extension Notification.Name {
    static let formzeitSettingsChanged = Notification.Name("FormzeitSettingsChanged")
}
