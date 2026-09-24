import AppKit

/// Speaks a message through VoiceOver (and shows it on a braille display).
/// Yapd is driven by a shortcut from other apps, so its state changes need
/// more than an icon; and it never plays sounds, which would end up in the
/// recording and wouldn't reach deaf users anyway.
@MainActor
enum Announcer {
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
