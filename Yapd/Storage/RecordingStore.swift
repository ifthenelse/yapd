import Foundation

/// Owns the on-disk layout of recordings: one directory per recording,
/// nested under `<root>/yyyy/MM/`, named with a sortable timestamp.
///
///     Recordings/2026/09/20260915-120214/
///         recording.m4a
///         transcript.txt
///         metadata.json
struct RecordingStore {
    let rootDirectory: URL

    private static let directoryNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM"
        return formatter
    }()

    /// Creates and returns a fresh directory for a recording starting now.
    /// Throws if the destination isn't writable, so callers can surface a
    /// clear "recording folder is unwritable" failure before capture starts.
    func makeRecordingDirectory(for startedAt: Date = Date()) throws -> URL {
        let year = Self.yearFormatter.string(from: startedAt)
        let month = Self.monthFormatter.string(from: startedAt)
        let name = Self.directoryNameFormatter.string(from: startedAt)

        let directory = rootDirectory
            .appending(path: year, directoryHint: .isDirectory)
            .appending(path: month, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.destinationUnwritable(reason: error.localizedDescription)
        }
        return directory
    }

    func write(_ metadata: RecordingMetadata, to directory: URL) throws {
        let data = try RecordingMetadata.encoder().encode(metadata)
        try data.write(to: directory.appending(path: "metadata.json"), options: .atomic)
    }

    /// Verifies the root directory exists (creating it if needed) and is
    /// writable. Used during setup and before each recording starts.
    func verifyRootIsWritable() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory)

        if !exists {
            do {
                try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            } catch {
                throw RecordingError.destinationUnwritable(reason: error.localizedDescription)
            }
            return
        }

        guard isDirectory.boolValue, fileManager.isWritableFile(atPath: rootDirectory.path) else {
            throw RecordingError.destinationUnwritable(reason: "\(rootDirectory.path) is not a writable directory")
        }
    }
}
