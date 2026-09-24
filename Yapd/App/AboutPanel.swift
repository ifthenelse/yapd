import AppKit

/// The About dialog: a standard alert listing the build's technical details,
/// with a Copy button that puts the same text on the clipboard for bug reports.
@MainActor
enum AboutPanel {
    static func show(appState: AppState) {
        let details = details(permissions: appState)

        let alert = NSAlert()
        alert.messageText = "Yapd"
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")

        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        }
    }

    static func details(permissions appState: AppState) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? { info[key] as? String }

        var lines = [
            "Version: \(value("CFBundleShortVersionString") ?? "?") (\(value("CFBundleVersion") ?? "?"))",
            "Commit: \(value("YapdGitCommit") ?? "unknown")",
            "Date: \(value("YapdBuildDate") ?? "unknown")",
            "Configuration: \(configuration)",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")",
        ]
        if let xcode = value("DTXcodeBuild") {
            lines.append("Xcode: \(xcode) (\(value("DTSDKName") ?? "?"))")
        }
        lines.append("OS: \(operatingSystem)")
        lines.append("Hardware: \(hardware)")

        for kind in PermissionKind.allCases {
            let state: String
            switch appState.status(of: kind) {
            case .granted: state = "Allowed"
            case .denied: state = "Not allowed"
            case .notDetermined: state = "Not asked yet"
            }
            lines.append("\(kind.displayName): \(state)")
        }
        return lines.joined(separator: "\n")
    }

    private static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var name = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { name += ".\(version.patchVersion)" }
        if let build = sysctlString("kern.osversion") { name += " (\(build))" }
        return name
    }

    private static var hardware: String {
        var parts: [String] = []
        var system = utsname()
        uname(&system)
        parts.append(withUnsafeBytes(of: &system.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        if let model = sysctlString("hw.model") { parts.append(model) }
        return parts.joined(separator: ", ")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
