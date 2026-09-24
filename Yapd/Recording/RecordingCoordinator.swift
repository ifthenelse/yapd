import Foundation
import Observation

/// Owns the recording state machine and coordinates the independent capture
/// sources, their track files, and the final mix.
///
/// Sources are started separately: if one fails (say, the microphone isn't
/// allowed) the other still records and the problem is reported in
/// `sourceIssues`. Transcription will run only after the audio is saved, so
/// it can never interrupt or lose a recording.
@MainActor
@Observable
final class RecordingCoordinator {
    private(set) var state: RecordingState = .idle
    /// Sources that aren't recording during the current recording, with why.
    private(set) var sourceIssues: [AudioSource: String] = [:]

    private let transcriptionService: TranscriptionService

    private struct Session {
        let directory: URL
        let store: RecordingStore
        let startedAt: Date
        let microphoneName: String?
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
        systemAudioAccess: PermissionStatus
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
            if writer.hasHeardAudio, let startHostTime = writer.finish() {
                session.systemAudioSegments.append(RecordingMixer.Track(url: writer.url, startHostTime: startHostTime))
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

    private func performSystemAudioCheck() {
        guard var session else { return }
        defer { self.session = session }

        if SystemAudioTap.hasAccess() == false {
            if session.systemAudio != nil {
                stopSystemAudio(in: &session)
                session.systemAudioUnverified = true
            }
            sourceIssues[.systemAudio] = Self.systemAudioDenied
            return
        }

        if session.systemAudio == nil {
            // Access was turned back on, or the previous start failed.
            sourceIssues[.systemAudio] = nil
            startSystemAudio(in: &session)
            return
        }

        guard session.systemAudioUnverified else { return }
        if session.systemAudioWriter?.hasHeardAudio == true {
            session.systemAudioUnverified = false
        } else {
            // Still only silence; a fresh tap picks up a permission granted meanwhile.
            stopSystemAudio(in: &session)
            startSystemAudio(in: &session)
        }
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
        if let writer = session.microphoneWriter, let startHostTime = writer.finish() {
            tracks.append(RecordingMixer.Track(url: writer.url, startHostTime: startHostTime))
        }
        let endedAt = Date()

        var failure = initialFailure
        if tracks.isEmpty {
            Self.removeIfEmpty(session.directory)
            failure = failure ?? .noAudioSource(reason: "No audio arrived from any source.")
        } else {
            do {
                try await RecordingMixer.mix(tracks, into: session.directory.appending(path: "recording.m4a"))
                for track in tracks {
                    try? FileManager.default.removeItem(at: track.url)
                }
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
        }

        self.session = nil
        sourceIssues = [:]
        transition(to: failure.map { .failed($0) } ?? .idle)
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
