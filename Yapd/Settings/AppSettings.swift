import Foundation

/// User-configurable settings, persisted by `SettingsStore` and edited in
/// the Settings window.
struct AppSettings: Equatable {
    var hasLaunchedBefore: Bool
    var recordingsDirectoryPath: String?
    var selectedMicrophoneID: String?
    var transcriptionLanguageIdentifier: String?
    /// Whether Yapd has ever started a computer-audio tap, which is when
    /// macOS asks for the permission. The permission itself can't be queried.
    var systemAudioRequested: Bool

    static let defaultValue = AppSettings(
        hasLaunchedBefore: false,
        recordingsDirectoryPath: nil,
        selectedMicrophoneID: nil,
        transcriptionLanguageIdentifier: nil,
        systemAudioRequested: false
    )

    var recordingsDirectoryURL: URL? {
        recordingsDirectoryPath.map { URL(filePath: $0) }
    }

    static func defaultRecordingsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appending(path: "Yapd Recordings", directoryHint: .isDirectory)
    }
}

// Custom `Codable` so a settings file from before a field was added or removed
// still loads instead of silently resetting everything to defaults.
extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case hasLaunchedBefore, recordingsDirectoryPath, selectedMicrophoneID
        case transcriptionLanguageIdentifier, systemAudioRequested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasLaunchedBefore = try container.decodeIfPresent(Bool.self, forKey: .hasLaunchedBefore) ?? false
        recordingsDirectoryPath = try container.decodeIfPresent(String.self, forKey: .recordingsDirectoryPath)
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
        transcriptionLanguageIdentifier = try container.decodeIfPresent(String.self, forKey: .transcriptionLanguageIdentifier)
        systemAudioRequested = try container.decodeIfPresent(Bool.self, forKey: .systemAudioRequested) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasLaunchedBefore, forKey: .hasLaunchedBefore)
        try container.encodeIfPresent(recordingsDirectoryPath, forKey: .recordingsDirectoryPath)
        try container.encodeIfPresent(selectedMicrophoneID, forKey: .selectedMicrophoneID)
        try container.encodeIfPresent(transcriptionLanguageIdentifier, forKey: .transcriptionLanguageIdentifier)
        try container.encode(systemAudioRequested, forKey: .systemAudioRequested)
    }
}
