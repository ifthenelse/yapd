import SwiftUI

@main
struct YapdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var appState: AppState { appDelegate.appState }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(appState.isRecording ? "MenuBarListening" : "MenuBarIdle")
                .accessibilityLabel(appState.isRecording ? "Yapd, recording" : "Yapd")
        }
        .menuBarExtraStyle(.menu)

        // A plain `Window` rather than a `Settings` scene: only `Window`
        // honours `defaultLaunchBehavior`, which opens it on first launch.
        Window("Yapd Settings", id: WindowID.settings) {
            SettingsView()
                .environment(appState)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(appState.isFirstLaunch ? .presented : .suppressed)
    }
}

enum WindowID {
    static let settings = "settings"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    /// Quitting (menu, ⌘Q, logout) waits for a recording in progress to be saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.isRecording else { return .terminateNow }
        Task {
            await appState.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
