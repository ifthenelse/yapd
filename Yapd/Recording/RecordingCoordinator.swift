import AVFoundation
import Foundation
import Observation

/// Owns the recording state machine and coordinates the independent capture
/// sources, their track files, and the final mix.
///
/// Sources are started separately: if one fails (say, the microphone isn't
/// allowed) the other still records and the problem is reported in
/// `sourceIssues`. Transcription runs only after the audio is saved, in the
/// background, so it can never interrupt or lose a recording.
@MainActor
@Observable
final class RecordingCoordinator {
    private(set) var state: RecordingState = .idle
    /// Sources that aren't recording during the current recording, with why.
    private(set) var sourceIssues: [AudioSource: String] = [:]
    /// How many saved recordings are still waiting for or having a transcript made.
    private(set) var transcriptionsInProgress = 0
    /// Why the last transcription produced no transcript, if it didn't.
    private(set) var transcriptionIssue: String?

    private let transcriptionService: TranscriptionService
    private var transcriptionChain: Task<Void, Never>?

    private struct Session {
        let directory: URL
        let store: RecordingStore
        let startedAt: Date
        let microphoneName: String?
        let languageIdentifier: String?
        var microphone: MicrophoneInput?
        var microphoneWriter: TrackWriter?
        var systemAudio: SystemAudioTap?
        var systemAudioWriter: TrackWriter?
        /// Earlier computer-audio segments that held real audio.
        var systemAudioSegments: [RecordingMixer.Track] = []
        var systemAudioSegmentCount = 0
        /// True until computer audio has delivered real sound. A tap without
        /// permission records pure silence, and a grant only reaches taps
        /// started afterwards, so an unverified tap is rebuilt periodically.
        var systemAudioUnverified: Bool
    }

    private var session: Session?
    private var monitorTask: Task<Void, Never>?

    private static let systemAudioDenied = "Computer audio isn't allowed. Turn it on in System Settings."

    init(transcriptionService: TranscriptionService) {
        self.transcriptionService = transcriptionService
    }

    func startRecording(
        into recordingsRoot: URL,
        microphoneDeviceID: String?,
        microphoneAllowed: Bool,
        systemAudioAccess: PermissionStatus,
        transcriptionLanguage: String?
    ) {
        guard RecordingStateMachine.canTransition(from: state, to: .preparing) else { return }
        state = .preparing
        sourceIssues = [:]

        let store = RecordingStore(rootDirectory: recordingsRoot)
        let directory: URL
        do {
            try store.verifyRootIsWritable()
            directory = try store.makeRecordingDirectory()
        } catch {
            let reason = (error as? RecordingError) ?? .destinationUnwritable(reason: error.localizedDescription)
            transition(to: .failed(reason))
            return
        }

        let microphone = MicrophoneInput(deviceUID: microphoneDeviceID)
        var session = Session(
            directory: directory,
            store: store,
            startedAt: Date(),
            microphoneName: microphone.deviceName,
            languageIdentifier: transcriptionLanguage,
            systemAudioUnverified: systemAudioAccess != .granted
        )

        if systemAudioAccess == .denied {
            sourceIssues[.systemAudio] = Self.systemAudioDenied
        } else {
            startSystemAudio(in: &session)
        }

        if microphoneAllowed {
            let writer = TrackWriter(url: directory.appending(path: "microphone.caf"))
            do {
                try microphone.start { buffer, time in writer.write(buffer, at: time) }
                session.microphone = microphone
                session.microphoneWriter = writer
            } catch {
                sourceIssues[.microphone] = Self.message(for: error, source: .microphone)
            }
        } else {
            sourceIssues[.microphone] = "Microphone access isn't allowed."
        }

        // With computer audio merely denied, keep going on the microphone:
        // it resumes by itself if access is turned back on.
        guard session.systemAudio != nil || session.microphone != nil else {
            Self.removeIfEmpty(directory)
            let reasons = AudioSource.allCases.compactMap { sourceIssues[$0] }.joined(separator: " ")
            transition(to: .failed(.noAudioSource(reason: reasons)))
            return
        }

        self.session = session
        transition(to: .recording(startedAt: session.startedAt))
        startMonitoring()
    }

    func stopRecording() async {
        await finishRecording(failure: nil)
    }

    // MARK: Computer audio

    private func startSystemAudio(in session: inout Session) {
        session.systemAudioSegmentCount += 1
        let count = session.systemAudioSegmentCount
        let name = count == 1 ? "computer-audio.caf" : "computer-audio-\(count).caf"
        let writer = TrackWriter(url: session.directory.appending(path: name))
        let tap = SystemAudioTap()
        do {
            try tap.start { buffer, time in writer.write(buffer, at: time) }
            session.systemAudio = tap
            session.systemAudioWriter = writer
        } catch {
            sourceIssues[.systemAudio] = Self.message(for: error, source: .systemAudio)
        }
    }

    /// Stops the tap, keeping its segment only if it captured real audio.
    private func stopSystemAudio(in session: inout Session) {
        session.systemAudio?.stop()
        session.systemAudio = nil
        if let writer = session.systemAudioWriter {
            if writer.hasHeardAudio {
                session.systemAudioSegments += writer.finish().map {
                    RecordingMixer.Track(url: $0.url, startHostTime: $0.startHostTime, source: .systemAudio)
                }
            } else {
                writer.discard()
            }
        }
        session.systemAudioWriter = nil
    }

    /// Runs every few seconds while recording. Changes are announced, since
    /// nobody is necessarily looking at the menu.
    private func checkSystemAudio() {
        let before = sourceIssues[.systemAudio]
        performSystemAudioCheck()
        let after = sourceIssues[.systemAudio]
        if let after, after != before {
            Announcer.post(after)
        } else if before != nil, after == nil {
            Announcer.post("Computer audio is recording again.")
        }
    }

    /// Probing access creates a tap of its own, and doing that while another
    /// tap is running disrupts it (and the microphone with it), so it's only
    /// ever done with no tap running.
    private func performSystemAudioCheck() {
        guard var session else { return }
        defer { self.session = session }

        if session.systemAudio != nil {
            // Running and verified: leave it alone.
            guard session.systemAudioUnverified else { return }
            if session.systemAudioWriter?.hasHeardAudio == true {
                session.systemAudioUnverified = false
                return
            }
            // Still only silence; a fresh tap picks up a permission granted meanwhile.
            stopSystemAudio(in: &session)
        }

        if SystemAudioTap.hasAccess() == false {
            sourceIssues[.systemAudio] = Self.systemAudioDenied
            session.systemAudioUnverified = true
            return
        }
        sourceIssues[.systemAudio] = nil
        startSystemAudio(in: &session)
    }

    // MARK: Finishing

    private func finishRecording(failure initialFailure: RecordingError?) async {
        guard var session, RecordingStateMachine.canTransition(from: state, to: .stopping) else { return }
        transition(to: .stopping)
        monitorTask?.cancel()
        monitorTask = nil

        stopSystemAudio(in: &session)
        session.microphone?.stop()
        var tracks = session.systemAudioSegments
        if let writer = session.microphoneWriter {
            tracks += writer.finish().map {
                RecordingMixer.Track(url: $0.url, startHostTime: $0.startHostTime, source: .microphone)
            }
        }
        let endedAt = Date()

        var failure = initialFailure
        if tracks.isEmpty {
            Self.removeIfEmpty(session.directory)
            failure = failure ?? .noAudioSource(reason: "No audio arrived from any source.")
        } else {
            var mixed = false
            do {
                try await RecordingMixer.mix(tracks, into: session.directory.appending(path: "recording.m4a"))
                mixed = true
            } catch {
                failure = failure ?? .saveFailed(reason: error.localizedDescription)
            }

            let metadata = RecordingMetadata(
                startedAt: session.startedAt,
                endedAt: endedAt,
                durationSeconds: endedAt.timeIntervalSince(session.startedAt),
                language: nil,
                microphone: session.microphoneWriter == nil ? nil : session.microphoneName,
                systemAudio: !session.systemAudioSegments.isEmpty
            )
            try? session.store.write(metadata, to: session.directory)

            // The raw tracks are kept until transcription has used them, and
            // for good if the mix failed, so the audio can't be lost.
            queueTranscription(
                tracks: tracks,
                session: session,
                metadata: metadata,
                deleteTracksAfterwards: mixed
            )
        }

        self.session = nil
        sourceIssues = [:]
        transition(to: failure.map { .failed($0) } ?? .idle)
    }

    // MARK: Transcription

    /// Transcripts are made one at a time, after the audio is safely saved.
    private func queueTranscription(
        tracks: [RecordingMixer.Track],
        session: Session,
        metadata: RecordingMetadata,
        deleteTracksAfterwards: Bool
    ) {
        let origin = tracks.map(\.startHostTime).min() ?? 0
        let inputs = tracks.map {
            TranscriptionTrack(
                speaker: $0.source.speakerLabel,
                url: $0.url,
                offset: AVAudioTime.seconds(forHostTime: $0.startHostTime - origin)
            )
        }
        let service = transcriptionService
        let language = session.languageIdentifier
        let directory = session.directory
        let store = session.store
        let trackURLs = tracks.map(\.url)

        transcriptionsInProgress += 1
        transcriptionIssue = nil
        let previous = transcriptionChain
        transcriptionChain = Task { [weak self] in
            await previous?.value
            let outcome: Result<TranscriptionResult, Error>
            do {
                outcome = .success(try await service.transcribe(inputs, languageIdentifier: language))
            } catch {
                outcome = .failure(error)
            }
            self?.finishTranscription(
                outcome,
                directory: directory,
                store: store,
                metadata: metadata,
                trackURLs: deleteTracksAfterwards ? trackURLs : []
            )
        }
    }

    private func finishTranscription(
        _ outcome: Result<TranscriptionResult, Error>,
        directory: URL,
        store: RecordingStore,
        metadata: RecordingMetadata,
        trackURLs: [URL]
    ) {
        transcriptionsInProgress -= 1
        for url in trackURLs {
            try? FileManager.default.removeItem(at: url)
        }

        switch outcome {
        case .success(let result) where result.segments.isEmpty:
            report("No speech was found in the recording.")
        case .success(let result):
            let segments = EchoFilter.removeEchoes(
                in: result.segments,
                local: AudioSource.microphone.speakerLabel,
                remote: AudioSource.systemAudio.speakerLabel
            )
            do {
                try store.writeTranscript(TranscriptFormatter.text(from: segments), to: directory)
                var updated = metadata
                updated.language = result.language
                try? store.write(updated, to: directory)
                Announcer.post("Transcript saved.")
            } catch {
                report("The transcript couldn't be saved. \(error.localizedDescription)")
            }
        case .failure(let error):
            report(error.localizedDescription)
        }
    }

    private func report(_ issue: String) {
        transcriptionIssue = issue
        Announcer.post(issue)
    }

    // MARK: Monitoring

    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                tick += 1
                await self?.monitor(checkSystemAudio: tick % 6 == 0)
            }
        }
    }

    private func monitor(checkSystemAudio shouldCheck: Bool) async {
        guard let session, case .recording = state else { return }
        for writer in [session.systemAudioWriter, session.microphoneWriter] {
            if let error = writer?.error {
                // Disk full or folder removed: stop cleanly, keeping what was captured.
                await finishRecording(failure: .destinationUnwritable(reason: error.localizedDescription))
                return
            }
        }
        if shouldCheck { checkSystemAudio() }
    }

    // MARK: Helpers

    private func transition(to next: RecordingState) {
        guard RecordingStateMachine.canTransition(from: state, to: next) else { return }
        let previous = state
        state = next

        switch (previous, next) {
        case (.preparing, .recording):
            let issues = AudioSource.allCases.compactMap { sourceIssues[$0] }
            Announcer.post((["Recording started."] + issues).joined(separator: " "))
        case (.stopping, .idle):
            Announcer.post("Recording saved.")
        case (_, .failed(let error)):
            Announcer.post("Recording failed. \(error.localizedDescription)")
        default:
            break
        }
    }

    private static func message(for error: Error, source: AudioSource) -> String {
        switch error {
        case let error as SystemAudioTapError: return error.errorDescription ?? ""
        case let error as MicrophoneInputError: return error.errorDescription ?? ""
        default: return "\(source.displayName) couldn't start (error \((error as NSError).code))."
        }
    }

    private static func removeIfEmpty(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
