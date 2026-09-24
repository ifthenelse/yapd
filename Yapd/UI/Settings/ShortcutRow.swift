import SwiftUI
import AppKit

/// "Start and stop recording" shortcut: a single popup, plus an inline
/// recorder when the user picks "Record Shortcut…".
struct ShortcutRow: View {
    @Environment(AppState.self) private var appState

    private enum Choice: Hashable {
        case fnDoubleTap, custom, none, record
    }

    var body: some View {
        LabeledContent {
            if appState.isCapturingShortcut {
                HStack(spacing: 8) {
                    Text("Type a shortcut")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { appState.isCapturingShortcut = false }
                }
                .background(ShortcutCaptureView(onCapture: captured))
            } else {
                Picker("Shortcut", selection: selection) {
                    Text("Double-tap fn").tag(Choice.fnDoubleTap)
                    if case .custom(let combo) = appState.settings.hotkeyMode {
                        Text(combo.displayString).tag(Choice.custom)
                    }
                    Text("None").tag(Choice.none)
                    Divider()
                    Text("Record Shortcut\u{2026}").tag(Choice.record)
                }
                .labelsHidden()
                .fixedSize()
            }
        } label: {
            Text("Start and stop recording")
            if let conflict {
                Text(conflict).foregroundStyle(.orange)
            }
        }
        .onDisappear { appState.isCapturingShortcut = false }
    }

    private var selection: Binding<Choice> {
        Binding {
            switch appState.settings.hotkeyMode {
            case .fnDoubleTap: .fnDoubleTap
            case .custom: .custom
            case .disabled: .none
            }
        } set: { choice in
            switch choice {
            case .fnDoubleTap: appState.updateSettings { $0.hotkeyMode = .fnDoubleTap }
            case .none: appState.updateSettings { $0.hotkeyMode = .disabled }
            case .record: appState.isCapturingShortcut = true
            case .custom: break
            }
        }
    }

    private var conflict: String? {
        guard case .custom(let combo) = appState.settings.hotkeyMode,
              SystemShortcutConflictChecker.systemShortcutConflicts(with: combo) else { return nil }
        return "Also used by a macOS shortcut"
    }

    private func captured(_ combo: HotkeyCombo?) {
        appState.isCapturingShortcut = false
        guard let combo else { return }
        appState.updateSettings { $0.hotkeyMode = .custom(combo) }
    }
}

/// Invisible first responder that reports the next key combination.
/// `nil` means the user pressed Escape. Combinations without ⌘, ⌥ or ⌃
/// (other than function keys) are rejected, because they'd fire while typing.
private struct ShortcutCaptureView: NSViewRepresentable {
    var onCapture: (HotkeyCombo?) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.onCapture = onCapture
    }

    final class CaptureNSView: NSView {
        var onCapture: ((HotkeyCombo?) -> Void)?

        private static let escapeKeyCode: UInt16 = 53
        private static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            handle(event)
        }

        // ⌘-combinations arrive as key equivalents, before keyDown.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            handle(event)
            return true
        }

        private func handle(_ event: NSEvent) {
            if event.keyCode == Self.escapeKeyCode {
                onCapture?(nil)
                return
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard !modifiers.isEmpty || Self.functionKeyCodes.contains(event.keyCode) else {
                NSSound.beep()
                return
            }
            onCapture?(HotkeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags))
        }
    }
}
