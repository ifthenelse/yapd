import AVFoundation
import CoreAudio

/// A selectable microphone. `id` is the Core Audio device UID, which is
/// what `AVCaptureDevice.uniqueID` reports on macOS.
struct MicrophoneDevice: Identifiable, Equatable {
    var id: String
    var name: String

    /// Listing devices doesn't require microphone permission.
    static func all() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum MicrophoneInputError: LocalizedError {
    case deviceUnavailable

    var errorDescription: String? { "The selected microphone isn't available." }
}

/// Captures the user's microphone with AVAudioEngine.
@MainActor
final class MicrophoneInput: AudioCaptureSource {
    /// nil records from the system default input.
    private let deviceUID: String?
    private var engine: AVAudioEngine?

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    /// The name of the device that will actually be used.
    var deviceName: String? {
        let system = AudioHardwareSystem.shared
        let device: AudioHardwareDevice?
        if let deviceUID {
            device = try? system.device(forUID: deviceUID)
        } else {
            device = try? system.defaultInputDevice
        }
        return try? device?.name
    }

    func start(onBuffer: @escaping AudioBufferHandler) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            guard let device = try AudioHardwareSystem.shared.device(forUID: deviceUID) else {
                throw MicrophoneInputError.deviceUnavailable
            }
            try input.auAudioUnit.setDeviceID(device.id)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneInputError.deviceUnavailable
        }
        Self.installTap(on: input, format: format, onBuffer: onBuffer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Nonisolated so the tap block isn't inferred as main-actor isolated:
    /// AVAudioEngine calls it on a background thread.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        onBuffer: @escaping AudioBufferHandler
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            onBuffer(buffer, time)
        }
    }
}
