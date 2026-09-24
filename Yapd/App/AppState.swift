import Foundation
import Observation
import AppKit

/// Root application state: settings, live permission statuses, and the
/// recording coordinator. Held once by `YapdApp` and shared via the
/// environment.
@MainActor
@Observable
final class AppState {
    private(set) var settings: AppSettings
    private(set) var permissions: [PermissionKind: PermissionStatus] = [:]
    /// Fixed at launch: SwiftUI reads it for the Settings window's launch
    /// behaviour, which must not flip while that window is being shown.
    let isFirstLaunch: Bool

    let recordingCoordinator: RecordingCoordinator
    let transcriptionService: any TranscriptionService = AppleTranscriptionService()
    let permissionManager = PermissionManager()

    private let settingsStore: SettingsStore
    private let hotkeyManager = HotkeyManager()

    init() {
        let store = SettingsStore()
        let loaded = store.load()
        settingsStore = store
        settings = loaded
        isFirstLaunch = !loaded.hasLaunchedBefore
        recordingCoordinator = RecordingCoordinator(transcriptionService: transcriptionService)
        refreshPermissions()
        applyHotkey()
        updateSettings { $0.hasLaunchedBefore = true }

        // Permissions change in System Settings; re-check whenever the user
        // switches apps (e.g. back from System Settings) so the menu is current.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    var recordingsDirectory: URL {
        settings.recordingsDirectoryURL ?? AppSettings.defaultRecordingsDirectory()
    }

    var isRecording: Bool { recordingCoordinator.state.isActive }

    // MARK: Settings

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        let previous = settings
        var updated = settings
        transform(&updated)
        guard updated != previous else { return }
        settings = updated
        settingsStore.save(updated)
    }

    // MARK: Permissions

    /// The permissions Yapd needs, in display order.
    var relevantPermissions: [PermissionKind] { PermissionKind.allCases }

    func status(of kind: PermissionKind) -> PermissionStatus {
        permissions[kind] ?? .notDetermined
    }

    func refreshPermissions() {
        for kind in PermissionKind.allCases {
            // Checking computer audio access starts a tap, which would disrupt a recording.
            if kind == .systemAudio, isRecording { continue }
            let current = permissionManager.status(for: kind, systemAudioRequested: settings.systemAudioRequested)
            let previous = permissions[kind]
            guard current != previous else { continue }
            permissions[kind] = current
            // Global key monitors installed before Accessibility was granted
            // never receive events, so reinstall them once it is.
            if kind == .accessibility, current == .granted, previous != nil { applyHotkey() }
        }
    }

    /// Asks macOS for the permission when it still can, otherwise opens the
    /// matching System Settings pane.
    func resolvePermission(_ kind: PermissionKind) async {
        switch status(of: kind) {
        case .granted:
            return
        case .notDetermined:
            await permissionManager.request(kind)
            if kind == .systemAudio { updateSettings { $0.systemAudioRequested = true } }
        case .denied:
            permissionManager.openSystemSettings(for: kind)
        }
        refreshPermissions()
    }

    // MARK: Recording

    func startRecording() {
        Task {
            if status(of: .microphone) == .notDetermined {
                await permissionManager.request(.microphone)
            }
            refreshPermissions()
            recordingCoordinator.startRecording(
                into: recordingsDirectory,
                microphoneDeviceID: settings.selectedMicrophoneID,
                microphoneAllowed: status(of: .microphone) == .granted,
                systemAudioAccess: status(of: .systemAudio),
                transcriptionLanguage: settings.transcriptionLanguageIdentifier
            )
            // Starting a tap is what makes macOS ask.
            if status(of: .systemAudio) == .notDetermined {
                updateSettings { $0.systemAudioRequested = true }
                refreshPermissions()
            }
        }
    }

    func stopRecording() {
        Task { await recordingCoordinator.stopRecording() }
    }

    /// Saves any recording in progress before Yapd quits.
    func prepareToQuit() async {
        if case .recording = recordingCoordinator.state {
            await recordingCoordinator.stopRecording()
        }
        while recordingCoordinator.state == .stopping {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func toggleRecording() {
        switch recordingCoordinator.state {
        case .idle, .failed: startRecording()
        case .recording: stopRecording()
        case .preparing, .stopping: break
        }
    }

    private func applyHotkey() {
        hotkeyManager.start { [weak self] in
            self?.toggleRecording()
        }
    }

    // MARK: Windows

    /// Yapd never appears in the Dock, and an app without a Dock icon isn't
    /// brought forward by macOS on its own, so put its window on top by hand.
    func bringSettingsToFront() {
        NSApp.activate()
        for window in NSApp.windows where window.title == "Yapd Settings" {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
