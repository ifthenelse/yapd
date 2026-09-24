import AVFoundation

/// Receives captured audio on the source's own audio thread, never the main
/// thread. The buffer is only valid for the duration of the call.
typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

enum AudioSource: String, CaseIterable {
    /// Audio played by other apps (the remote participants).
    case systemAudio
    /// The user's microphone.
    case microphone

    var displayName: String {
        switch self {
        case .systemAudio: return "Computer Audio"
        case .microphone: return "Microphone"
        }
    }

    /// How this source is named in a transcript.
    var speakerLabel: String {
        switch self {
        case .systemAudio: return "Others"
        case .microphone: return "You"
        }
    }
}

/// One independent capture source. Sources never depend on each other, so
/// one failing can't stop the other from recording.
@MainActor
protocol AudioCaptureSource: AnyObject {
    func start(onBuffer: @escaping AudioBufferHandler) throws
    /// Returns once no more buffers will be delivered.
    func stop()
}
