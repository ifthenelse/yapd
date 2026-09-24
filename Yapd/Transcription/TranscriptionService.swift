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
    let end: TimeInterval
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

/// Without headphones the microphone also hears the speakers, so the other
/// participants' words are captured twice: cleanly from the computer's audio
/// and again, noisier, by the microphone. This removes from the microphone's
/// segments the runs of words the other side was saying at the same time,
/// keeping everything the user said.
enum EchoFilter {
    /// The echo reaches the microphone slightly after the clean copy, and the
    /// recogniser splits the two tracks at different points.
    private static let timeTolerance: TimeInterval = 4
    /// Shortest run of consecutive words that counts as an echo. Shorter runs
    /// are more likely to be the user genuinely saying the same thing.
    private static let minimumRun = 3
    /// A mistranscribed word or two inside an echo doesn't end it.
    private static let bridgeableGap = 2

    static func removeEchoes(in segments: [TranscriptSegment], local: String, remote: String) -> [TranscriptSegment] {
        let remoteSegments = segments.filter { $0.speaker == remote }
        guard !remoteSegments.isEmpty else { return segments }

        return segments.compactMap { segment in
            guard segment.speaker == local else { return segment }

            let nearby = remoteSegments
                .filter { $0.start - timeTolerance <= segment.end && $0.end + timeTolerance >= segment.start }
                .sorted { $0.start < $1.start }
            guard !nearby.isEmpty else { return segment }

            let own = words(in: segment.text)
            let remoteKeys = nearby.flatMap { words(in: $0.text).map(\.key) }
            let echoed = echoedPositions(own: own.map(\.key), remote: remoteKeys)
            guard !echoed.isEmpty else { return segment }

            let kept = own.enumerated().filter { !echoed.contains($0.offset) }.map(\.element.text)
            guard !kept.isEmpty else { return nil }
            return TranscriptSegment(speaker: segment.speaker, start: segment.start, end: segment.end, text: kept.joined(separator: " "))
        }
    }

    /// Words as written (`text`) and as compared (`key`: no case, accents or punctuation).
    private static func words(in text: String) -> [(text: String, key: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word in
            let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
            return key.isEmpty ? nil : (String(word), key)
        }
    }

    /// The same word, allowing one wrong letter in longer words: the two copies
    /// of the audio are recognised separately and often differ slightly.
    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        guard x.count >= 5, y.count >= 5, abs(x.count - y.count) <= 1 else { return false }
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count <= 1 }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        var i = 0
        while i < short.count, short[i] == long[i] { i += 1 }
        return Array(short[i...]) == Array(long[(i + 1)...])
    }

    /// Positions in `own` that belong to a run of at least `minimumRun`
    /// words also found, in the same order, in `remote`. Longest runs first.
    private static func echoedPositions(own: [String], remote: [String]) -> Set<Int> {
        var echoed = Set<Int>()
        var used = Set<Int>()

        while true {
            var best = (length: 0, ownEnd: 0, remoteEnd: 0)
            var previous = [Int](repeating: 0, count: remote.count + 1)
            for i in 0..<own.count {
                var current = [Int](repeating: 0, count: remote.count + 1)
                for j in 0..<remote.count where !echoed.contains(i) && !used.contains(j) && sameWord(own[i], remote[j]) {
                    current[j + 1] = previous[j] + 1
                    if current[j + 1] > best.length { best = (current[j + 1], i, j) }
                }
                previous = current
            }
            guard best.length >= minimumRun else { break }
            for offset in 0..<best.length {
                echoed.insert(best.ownEnd - offset)
                used.insert(best.remoteEnd - offset)
            }
        }

        // Bridge short gaps between echoed words (words the recogniser heard differently).
        let sorted = echoed.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a - 1 > 0 && b - a - 1 <= bridgeableGap {
            for gap in (a + 1)..<b { echoed.insert(gap) }
        }
        return echoed
    }
}
