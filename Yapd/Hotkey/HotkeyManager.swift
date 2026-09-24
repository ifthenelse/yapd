import SwiftUI

/// Listens for the fixed shortcut that starts and stops recording, ⌃⌥⌘−, in
/// any app. Global monitors only see events while Yapd isn't the active app,
/// so a local monitor covers the case where a Yapd window is frontmost.
///
/// Receiving global key events needs Accessibility trust; until it's granted
/// the monitor is installed but never fires.
@MainActor
final class HotkeyManager {
    /// How the shortcut is shown in the UI.
    static let displayString = "\u{2303}\u{2325}\u{2318}\u{2212}"
    /// The same, as assistive technology should read it.
    static let spokenString = "Control, Option, Command, Minus"
    /// The key equivalent, for showing the shortcut next to menu items.
    static let keyEquivalent: KeyEquivalent = "-"
    static let eventModifiers: EventModifiers = [.control, .option, .command]

    private nonisolated static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private nonisolated static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// (Re)installs the monitors. Safe to call again, e.g. once Accessibility
    /// access has been granted.
    func start(onToggle: @escaping () -> Void) {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event) { onToggle() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.matches(event) else { return event }
            onToggle()
            return nil
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private nonisolated static func matches(_ event: NSEvent) -> Bool {
        // By character, not key code: key codes are physical positions, and the
        // minus key is somewhere else on non-US layouts.
        event.charactersIgnoringModifiers == "-"
            && event.modifierFlags.intersection(relevantModifiers) == modifiers
    }
}
