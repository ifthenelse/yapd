import Foundation

/// One recorded source handed to transcription.
struct TranscriptionTrack: Sendable {
    /// Who this track is, as it appears in the transcript.
    let speaker: String
    let url: URL
    /// Seconds from the start of the recording to this track's first sample.
    let offset: TimeInterval
}

struct TranscriptSegment: Sendable, Equatable {
    let speaker: String
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let text: String
}

struct TranscriptionResult: Sendable {
    let segments: [TranscriptSegment]
    /// The language actually used, as a BCP 47 identifier such as "it-IT".
    let language: String
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Transcription isn't available on this Mac."
        case .unsupportedLanguage(let language):
            return "Transcription isn't available for \(language)."
        case .modelUnavailable(let language):
            return "The \(language) speech model couldn't be downloaded. Connect to the internet once and record again."
        }
    }
}

/// Turns recorded audio into text. Runs after a recording is saved, never
/// during it, so a failure here can't affect the audio.
protocol TranscriptionService: Sendable {
    /// Languages the on-device model supports.
    func supportedLanguages() async -> [Locale]

    /// `languageIdentifier` nil means the Mac's preferred languages.
    func transcribe(_ tracks: [TranscriptionTrack], languageIdentifier: String?) async throws -> TranscriptionResult
}

/// The plain-text transcript written next to the recording:
///
///     [0:00:03] You: Hello, can you hear me?
///     [0:00:06] Others: Yes, loud and clear.
enum TranscriptFormatter {
    static func text(from segments: [TranscriptSegment]) -> String {
        var lines: [(start: TimeInterval, speaker: String, text: String)] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let last = lines.last, last.speaker == segment.speaker {
                lines[lines.count - 1].text += " " + segment.text
            } else {
                lines.append((segment.start, segment.speaker, segment.text))
            }
        }
        return lines
            .map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
