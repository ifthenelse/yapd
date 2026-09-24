import Foundation

/// Written as `metadata.json` alongside each recording's audio and
/// transcript. Field names and shape match the format documented in the
/// project spec so files remain readable without Yapd itself.
struct RecordingMetadata: Codable, Equatable {
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var language: String?
    var microphone: String?
    var systemAudio: Bool

    enum CodingKeys: String, CodingKey {
        case startedAt, endedAt, durationSeconds, language, microphone, systemAudio
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
