import Foundation

/// On-device transcription backed by the Speech framework's
/// `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+). Runs against the
/// finished recording file after capture stops, so transcription failures
/// never affect the audio recording itself.
///
/// Left unimplemented for this milestone; wiring it up requires the exact
/// `SpeechAnalyzer` input pipeline and `AssetInventory` download flow to be
/// verified against the macOS 26 SDK headers before use.
final class AppleTranscriptionService: TranscriptionService {
    func supportedLanguages() -> [Locale] {
        []
    }

    func transcribe(audioFileURL: URL, language: Locale) async throws -> String {
        throw TranscriptionError.unavailable(reason: "On-device transcription is not implemented yet.")
    }
}
