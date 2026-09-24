import Foundation

/// The recording lifecycle. Transitions are enforced by `RecordingCoordinator`
/// so that, for example, a second recording can never start while one is
/// already in progress.
enum RecordingState: Equatable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case stopping
    case failed(RecordingError)

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .stopping:
            return true
        case .idle, .failed:
            return false
        }
    }
}

enum RecordingError: Error, Equatable {
    case destinationUnwritable(reason: String)
    /// Neither computer audio nor the microphone could start.
    case noAudioSource(reason: String)
    /// Audio was captured but couldn't be turned into the final file. The
    /// raw tracks are kept in the recording's folder.
    case saveFailed(reason: String)

    var localizedDescription: String {
        switch self {
        case .destinationUnwritable(let reason):
            return "Can't write to the recordings folder. \(reason)"
        case .noAudioSource(let reason):
            return "Nothing to record. \(reason)"
        case .saveFailed(let reason):
            return "Couldn't finish saving the recording; the raw audio is in its folder. \(reason)"
        }
    }
}

/// Valid state transitions for the recording state machine. Kept separate
/// from `RecordingCoordinator` so the rules can be unit tested in isolation.
enum RecordingStateMachine {
    static func canTransition(from current: RecordingState, to next: RecordingState) -> Bool {
        switch (current, next) {
        case (.idle, .preparing):
            return true
        case (.preparing, .recording):
            return true
        case (.preparing, .failed):
            return true
        case (.recording, .stopping):
            return true
        case (.stopping, .idle):
            return true
        case (.stopping, .failed):
            return true
        case (.failed, .idle), (.failed, .preparing):
            return true
        default:
            return false
        }
    }
}
