import SwiftUI

/// The menu bar menu. While recording, nothing in it changes on its own:
/// SwiftUI's menu bridge can't cope with content that updates while the menu
/// is open (it crashed Yapd), so live levels and a running timer are left out.
/// Recording state is shown by the menu bar icon and announced to VoiceOver.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var coordinator: RecordingCoordinator { appState.recordingCoordinator }

    var body: some View {
        switch coordinator.state {
        case .recording:
            issueRow(.systemAudio)
            issueRow(.microphone)
            Button("Stop Recording") { appState.stopRecording() }
                .keyboardShortcut(HotkeyManager.keyEquivalent, modifiers: HotkeyManager.eventModifiers)
        case .preparing:
            Text("Starting\u{2026}")
        case .stopping:
            Text("Saving\u{2026}")
        case .failed(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
            startRecordingItems
        case .idle:
            startRecordingItems
        }

        if coordinator.transcriptionsInProgress > 0 {
            Divider()
            Label("Transcribing\u{2026}", systemImage: "text.bubble")
        } else if let issue = coordinator.transcriptionIssue {
            Divider()
            Label(issue, systemImage: "exclamationmark.triangle")
        }

        Divider()

        Button("Open Recordings") { openRecordingsFolder() }
        Button("Settings\u{2026}") {
            openWindow(id: WindowID.settings)
            appState.bringSettingsToFront()
        }
        Button("About Yapd") {
            // After the menu has closed, so the alert isn't run inside its tracking loop.
            Task { AboutPanel.show(appState: appState) }
        }

        Divider()

        Button("Quit Yapd") { NSApplication.shared.terminate(nil) }
    }

    @ViewBuilder
    private var startRecordingItems: some View {
        Button("Start Recording") { appState.startRecording() }
            .keyboardShortcut(HotkeyManager.keyEquivalent, modifiers: HotkeyManager.eventModifiers)
        Divider()
        permissionRow(title: "Computer Audio", kind: .systemAudio)
        permissionRow(title: "Microphone", kind: .microphone)
    }

    /// While recording: why a source isn't recording, if it isn't.
    @ViewBuilder
    private func issueRow(_ source: AudioSource) -> some View {
        if let issue = coordinator.sourceIssues[source] {
            Label(issue, systemImage: "exclamationmark.triangle")
        }
    }

    /// A granted source is a status line whose text says so (the icon alone
    /// wouldn't be read out); a missing one becomes the action that fixes it.
    @ViewBuilder
    private func permissionRow(title: String, kind: PermissionKind) -> some View {
        switch appState.status(of: kind) {
        case .granted:
            Label("\(title): Allowed", systemImage: "checkmark.circle")
        case .notDetermined, .denied:
            Button {
                Task { await appState.resolvePermission(kind) }
            } label: {
                Label("Allow \(title) Access\u{2026}", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func openRecordingsFolder() {
        let directory = appState.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
