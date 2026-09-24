import AppKit

/// Listens system-wide for the configured recording toggle shortcut.
/// Global monitors only see events while Yapd isn't the active app, so a
/// local monitor mirrors the same detection for when a Yapd window (Setup,
/// Settings) is frontmost.
///
/// Needs Accessibility trust (`AXIsProcessTrusted`) to receive global key
/// events at all; until granted, monitors are installed but simply never
/// fire, which is why `PermissionKind.accessibility` exists.
@MainActor
final class HotkeyManager {
    private var mode: HotkeyMode = .disabled
    private var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var fnCurrentlyDown = false
    private var lastFnDownAt: Date?
    private static let doubleTapThreshold: TimeInterval = 0.4

    func configure(mode: HotkeyMode, onToggle: @escaping () -> Void) {
        self.mode = mode
        self.onToggle = onToggle
        restartMonitoring()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func restartMonitoring() {
        stop()

        switch mode {
        case .disabled:
            return

        case .fnDoubleTap:
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }

        case .custom(let combo):
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event, matching: combo)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event, matching: combo)
                return event
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isFnDown = event.modifierFlags.contains(.function)
        guard isFnDown != fnCurrentlyDown else { return }
        fnCurrentlyDown = isFnDown
        guard isFnDown else { return }

        let now = Date()
        if let last = lastFnDownAt, now.timeIntervalSince(last) <= Self.doubleTapThreshold {
            lastFnDownAt = nil
            onToggle?()
        } else {
            lastFnDownAt = now
        }
    }

    private func handleKeyDown(_ event: NSEvent, matching combo: HotkeyCombo) {
        guard event.keyCode == combo.keyCode,
              event.modifierFlags.intersection(HotkeyCombo.relevantModifiers) == combo.modifiers else { return }
        onToggle?()
    }
}

/// Best-effort conflict check against `com.apple.symbolichotkeys`, the
/// preferences domain macOS itself uses for its own configurable shortcuts.
/// There's no public API for this; the plist layout (`parameters: [unicode,
/// keyCode, modifierFlags]`) is stable but undocumented, so treat a "no
/// conflict" result as "no *known* conflict" rather than a guarantee.
enum SystemShortcutConflictChecker {
    static func systemShortcutConflicts(with combo: HotkeyCombo) -> Bool {
        guard let hotkeys = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any] else { return false }

        for entry in hotkeys.values {
            guard let entry = entry as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = parameters[1] as? Int,
                  let modifiersRaw = parameters[2] as? Int
            else { continue }

            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiersRaw)).intersection(HotkeyCombo.relevantModifiers)
            if UInt16(keyCode) == combo.keyCode, modifiers == combo.modifiers {
                return true
            }
        }
        return false
    }
}
