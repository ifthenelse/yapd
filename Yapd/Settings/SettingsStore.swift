import Foundation

/// Persists `AppSettings` to `UserDefaults`. A single JSON blob under one
/// key is simpler than mapping each field to its own default and is plenty
/// for a handful of settings values — no database needed.
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "com.ifthenelse.Yapd.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return .defaultValue }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? .defaultValue
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
