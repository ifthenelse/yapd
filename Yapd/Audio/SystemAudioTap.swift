import AVFoundation
import CoreAudio

enum SystemAudioTapError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

/// Captures everything other apps play, via a Core Audio process tap on an
/// aggregate device. This needs only the "System Audio Recording" permission.
///
/// macOS asks for that permission the first time a tap starts. Without it a
/// tap still starts normally but delivers pure silence, and a grant only
/// reaches taps started afterwards.
@MainActor
final class SystemAudioTap: AudioCaptureSource {
    private let system = AudioHardwareSystem.shared
    private let queue = DispatchQueue(label: "Yapd.SystemAudioTap", qos: .userInitiated)
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?

    func start(onBuffer: @escaping AudioBufferHandler) throws {
        do {
            try startTap(onBuffer: onBuffer)
        } catch {
            stop()
            throw error
        }
    }

    /// Shows the macOS permission prompt (only the first time it's ever
    /// asked) by starting a tap briefly.
    static func requestAccess() async {
        let tap = SystemAudioTap()
        guard (try? tap.start(onBuffer: { _, _ in })) != nil else { return }
        try? await Task.sleep(for: .seconds(1))
        tap.stop()
    }

    func stop() {
        if let aggregate, let ioProcID {
            try? aggregate.stop(IOProcID: ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        // Let any buffer already dispatched to the queue finish.
        queue.sync {}
        if let aggregate { try? system.destroyAggregateDevice(aggregate) }
        if let tap { try? system.destroyProcessTap(tap) }
        ioProcID = nil
        aggregate = nil
        tap = nil
    }

    private func startTap(onBuffer: @escaping AudioBufferHandler) throws {
        // Yapd plays no audio of its own, so nothing needs excluding.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Yapd"
        description.isPrivate = true
        guard let tap = try system.makeProcessTap(description: description) else {
            throw SystemAudioTapError.unavailable("Couldn't create the computer audio tap.")
        }
        self.tap = tap

        var streamDescription = try tap.format
        let tapUID = try tap.uid
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw SystemAudioTapError.unavailable("Computer audio uses an unsupported format.")
        }

        // The default output device drives the aggregate's clock.
        guard let outputUID = try system.defaultOutputDevice?.uid else {
            throw SystemAudioTapError.unavailable("No audio output device is available.")
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Yapd Computer Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: aggregateDescription) else {
            throw SystemAudioTapError.unavailable("Couldn't set up computer audio capture.")
        }
        self.aggregate = aggregate

        let ioProcID = try Self.makeIOProc(device: aggregate.id, queue: queue, format: format, onBuffer: onBuffer)
        self.ioProcID = ioProcID
        try aggregate.start(IOProcID: ioProcID)
    }

    /// False when the user has turned computer audio access off, without
    /// prompting. There's no API to query the permission; changing a tap's
    /// description fails with `kAudioDevicePermissionsError` once access is
    /// denied. It can't tell "never asked" from "allowed" (both return true),
    /// so callers track separately whether Yapd has asked yet. Returns nil if
    /// the check itself couldn't run.
    nonisolated static func hasAccess() -> Bool? {
        let system = AudioHardwareSystem.shared
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        guard let tap = try? system.makeProcessTap(description: description) else { return nil }
        defer { try? system.destroyProcessTap(tap) }
        do {
            try tap.setDescription(description)
            return true
        } catch let error as AudioHardwareError where error.error == kAudioDevicePermissionsError {
            return false
        } catch {
            return nil
        }
    }

    /// Nonisolated so the IO block isn't inferred as main-actor isolated:
    /// Core Audio calls it on `queue`, and a main-actor block would trap.
    private nonisolated static func makeIOProc(
        device: AudioObjectID,
        queue: DispatchQueue,
        format: AVAudioFormat,
        onBuffer: @escaping AudioBufferHandler
    ) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                return
            }
            onBuffer(buffer, AVAudioTime(audioTimeStamp: inputTime, sampleRate: format.sampleRate))
        }
        guard status == noErr, let procID else { throw AudioHardwareError(status) }
        return procID
    }
}
