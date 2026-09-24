import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var coordinator: RecordingCoordinator { appState.recordingCoordinator }

    var body: some View {
        switch coordinator.state {
        case .recording(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Recording  \(elapsed(since: startedAt, to: context.date))")
            }
            levelRow(.systemAudio, symbol: "speaker.wave.3")
            levelRow(.microphone, symbol: "waveform")
            Divider()
            Button("Stop Recording") { appState.stopRecording() }
        case .preparing:
            Text("Starting\u{2026}")
        case .stopping:
            Text("Saving\u{2026}")
        case .failed(let error):
            Text(error.localizedDescription)
            Button("Start Recording") { appState.startRecording() }
            Divider()
            permissionRow(title: "Computer Audio", kind: .systemAudio)
            permissionRow(title: "Microphone", kind: .microphone)
        case .idle:
            Button("Start Recording") { appState.startRecording() }
            Divider()
            permissionRow(title: "Computer Audio", kind: .systemAudio)
            permissionRow(title: "Microphone", kind: .microphone)
        }

        Divider()

        Button("Open Recordings") { openRecordingsFolder() }
        Button("Settings\u{2026}") {
            openWindow(id: WindowID.settings)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Yapd") { NSApplication.shared.terminate(nil) }
    }

    /// While recording: the source's live level, or why it isn't recording.
    @ViewBuilder
    private func levelRow(_ source: AudioSource, symbol: String) -> some View {
        if let issue = coordinator.sourceIssues[source] {
            Label(issue, systemImage: "exclamationmark.triangle")
        } else {
            Label {
                Text(source.displayName)
            } icon: {
                Image(systemName: symbol, variableValue: Double(coordinator.levels[source] ?? 0))
            }
        }
    }

    /// When idle: a granted source is a plain status line; a missing one
    /// becomes the action that fixes it.
    @ViewBuilder
    private func permissionRow(title: String, kind: PermissionKind) -> some View {
        switch appState.status(of: kind) {
        case .granted:
            Label(title, systemImage: "checkmark.circle")
        case .notDetermined, .denied:
            Button {
                Task { await appState.resolvePermission(kind) }
            } label: {
                Label("Allow \(title) Access\u{2026}", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func elapsed(since start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%02d:%02d", minutes, seconds % 60)
    }

    private func openRecordingsFolder() {
        let directory = appState.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
