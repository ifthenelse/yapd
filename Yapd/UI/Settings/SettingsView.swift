import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var microphones: [MicrophoneDevice] = []

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(appState.relevantPermissions) { kind in
                    PermissionRow(kind: kind)
                }
            }

            Section("Recording") {
                folderRow
                microphoneRow
                LabeledContent("Start and stop recording") {
                    Text(HotkeyManager.displayString)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Start and stop recording")
                .accessibilityValue(HotkeyManager.spokenString)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismissWindow(id: WindowID.settings) }
        .onAppear {
            appState.bringSettingsToFront()
            microphones = MicrophoneDevice.all()
        }
        .task {
            // Keep statuses live while the window is open, e.g. as the user
            // flips switches in System Settings.
            while !Task.isCancelled {
                appState.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            microphones = MicrophoneDevice.all()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            microphones = MicrophoneDevice.all()
        }
    }

    private var folderRow: some View {
        let path = appState.recordingsDirectory.path(percentEncoded: false)
        return LabeledContent("Save to") {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(FileManager.default.displayName(atPath: path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(path)
                Button("Choose\u{2026}", action: chooseFolder)
                    .accessibilityLabel("Choose\u{2026} recordings folder")
            }
            .help(path)
        }
    }

    private var microphoneRow: some View {
        Picker("Microphone", selection: Binding(
            get: {
                let selected = appState.settings.selectedMicrophoneID
                return microphones.contains { $0.id == selected } ? selected : nil
            },
            set: { newValue in appState.updateSettings { $0.selectedMicrophoneID = newValue } }
        )) {
            Text("System Default").tag(String?.none)
            ForEach(microphones) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = appState.recordingsDirectory

        if panel.runModal() == .OK, let url = panel.url {
            appState.updateSettings { $0.recordingsDirectoryPath = url.path(percentEncoded: false) }
        }
    }
}

private struct PermissionRow: View {
    @Environment(AppState.self) private var appState
    let kind: PermissionKind

    var body: some View {
        LabeledContent {
            switch appState.status(of: kind) {
            case .granted:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Allowed")
                        .foregroundStyle(.secondary)
                }
            case .notDetermined:
                Button("Allow") {
                    Task { await appState.resolvePermission(kind) }
                }
                .accessibilityLabel("Allow \(kind.displayName)")
            case .denied:
                Button("Open System Settings") {
                    appState.permissionManager.openSystemSettings(for: kind)
                }
                .accessibilityLabel("Open System Settings to allow \(kind.displayName)")
            }
        } label: {
            Text(kind.displayName)
            Text(kind.usageExplanation)
        }
        // A granted row is one spoken item; a row with a button keeps that
        // button separately reachable.
        .accessibilityElement(children: appState.status(of: kind) == .granted ? .combine : .contain)
    }
}
