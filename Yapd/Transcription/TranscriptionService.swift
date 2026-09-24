import Foundation

/// Transcribes a finished recording into `transcript.txt`. Runs after
/// capture completes rather than live, so a transcription failure can
/// never interrupt or lose a recording (see `AppleTranscriptionService`).
protocol TranscriptionService: AnyObject {
    /// Locales the on-device model currently supports, independent of
    /// whether their assets are installed yet.
    func supportedLanguages() -> [Locale]

    func transcribe(audioFileURL: URL, language: Locale) async throws -> String
}

enum TranscriptionError: Error {
    case unavailable(reason: String)
    case unsupportedLanguage(Locale)
}
