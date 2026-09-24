import Foundation
import AppKit
import AVFoundation
import Speech
@preconcurrency import ApplicationServices

/// The individual macOS permissions Yapd needs, and why. Each case maps to
/// exactly one system privacy setting so the UI can explain permissions
/// one at a time rather than as a vague bundle.
enum PermissionKind: String, CaseIterable, Identifiable, Equatable {
    case microphone
    case systemAudio
    case speechRecognition
    case accessibility

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        case .speechRecognition: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        }
    }

    /// Why Yapd needs this permission, in one line.
    var usageExplanation: String {
        switch self {
        case .microphone: return "Records your side of the call."
        case .systemAudio: return "Records the other participants."
        case .speechRecognition: return "Writes the transcript on this Mac."
        case .accessibility: return "Lets the recording shortcut work in any app."
        }
    }

    /// Deep link into System Settings for this permission's privacy pane.
    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudio:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

@MainActor
final class PermissionManager {
    /// `systemAudioRequested`: whether Yapd has ever asked for computer audio
    /// access. macOS can't be queried for it: a denial is detectable, but
    /// "never asked" and "allowed" look the same.
    func status(for kind: PermissionKind, systemAudioRequested: Bool) -> PermissionStatus {
        switch kind {
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return Self.map(SFSpeechRecognizer.authorizationStatus())
        case .accessibility:
            // Untrusted can't be told apart from never-asked; prompting again
            // is harmless and leads to the right System Settings pane.
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .systemAudio:
            if SystemAudioTap.hasAccess() == false { return .denied }
            return systemAudioRequested ? .granted : .notDetermined
        }
    }

    /// Shows the macOS prompt. Computer audio's answer can't be read back
    /// directly; re-check `status(for:)` afterwards.
    func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await Self.requestSpeechAuthorization()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemAudio:
            await SystemAudioTap.requestAccess()
        }
    }

    /// Nonisolated because Speech calls back on a background queue, and a
    /// callback written inside a main-actor method would trap there.
    private nonisolated static func requestSpeechAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        guard let url = kind.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
