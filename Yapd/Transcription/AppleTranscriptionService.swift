import AVFoundation
import CoreMedia
import Speech

/// On-device transcription with the Speech framework's `SpeechAnalyzer` and
/// `SpeechTranscriber` (macOS 26). Audio never leaves the Mac; the language
/// model is an Apple asset that macOS downloads and manages itself the first
/// time a language is used.
///
/// Each track is transcribed on its own so a transcript can say who spoke,
/// and overlapping speech doesn't confuse the recogniser.
struct AppleTranscriptionService: TranscriptionService {
    func supportedLanguages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func transcribe(_ tracks: [TranscriptionTrack], languageIdentifier: String?) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        let locale = try await resolveLocale(languageIdentifier)

        var segments: [TranscriptSegment] = []
        for track in tracks {
            segments += try await transcribe(track, locale: locale)
        }
        return TranscriptionResult(segments: segments, language: locale.identifier(.bcp47))
    }

    private func resolveLocale(_ identifier: String?) async throws -> Locale {
        let candidates = identifier.map { [Locale(identifier: $0)] }
            ?? Locale.preferredLanguages.map { Locale(identifier: $0) }
        for candidate in candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return supported
            }
        }
        throw TranscriptionError.unsupportedLanguage(Self.name(of: candidates.first ?? .current))
    }

    private func transcribe(_ track: TranscriptionTrack, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.modelUnavailable(Self.name(of: locale))
        }

        let file = try AVAudioFile(forReading: track.url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let speaker = track.speaker
        let offset = track.offset

        let collector = Task { () -> [TranscriptSegment] in
            var found: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                found.append(TranscriptSegment(speaker: speaker, start: offset + result.range.start.seconds, text: text))
            }
            return found
        }

        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
