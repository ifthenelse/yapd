import AVFoundation
import Accelerate

/// Writes one capture source to 16-bit PCM CAF files. Uncompressed PCM stays
/// readable if Yapd crashes mid-recording, unlike a compressed file that is
/// only finalised on close; it's converted to AAC once recording stops.
///
/// Audio devices can change format mid-recording (a Bluetooth headset
/// switching between music and call mode changes its sample rate), and a
/// file can't change format, so a new segment file starts whenever the
/// incoming format changes.
///
/// `write` is called on the source's audio thread; everything else on the
/// main thread. A lock guards the shared state.
final class TrackWriter: @unchecked Sendable {
    /// One file of uniform format, and when its first sample arrived.
    struct Segment: Sendable {
        let url: URL
        let startHostTime: UInt64
    }

    private let baseURL: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var segments: [Segment] = []
    private var heardAudio = false
    private var writeError: Error?
    private var isFinished = false

    init(url: URL) {
        baseURL = url
    }

    func write(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let peak = Self.peak(of: buffer)
        lock.withLock {
            guard !isFinished, writeError == nil else { return }
            do {
                if file == nil || fileFormat != buffer.format {
                    file?.close()
                    let url = segmentURL(index: segments.count)
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: Self.fileSettings(for: buffer.format),
                        commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved
                    )
                    fileFormat = buffer.format
                    segments.append(Segment(
                        url: url,
                        startHostTime: time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                    ))
                }
                try file?.write(from: buffer)
                if peak > 0 { heardAudio = true }
            } catch {
                writeError = error
            }
        }
    }

    /// The first error hit while writing, e.g. a full or removed disk.
    var error: Error? {
        lock.withLock { writeError }
    }

    /// Whether any sample so far was non-zero. A computer-audio tap without
    /// permission delivers exact digital silence, so this is how Yapd tells
    /// the tap is really working.
    var hasHeardAudio: Bool {
        lock.withLock { heardAudio }
    }

    /// Closes the files and returns them; empty if nothing was ever written.
    func finish() -> [Segment] {
        lock.withLock {
            isFinished = true
            file?.close()
            file = nil
            return segments
        }
    }

    /// Closes and deletes every file, for tracks that only ever held silence.
    func discard() {
        for segment in finish() {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    private func segmentURL(index: Int) -> URL {
        guard index > 0 else { return baseURL }
        let name = baseURL.deletingPathExtension().lastPathComponent
        return baseURL.deletingLastPathComponent().appending(path: "\(name)-\(index + 1).caf")
    }

    private static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let format = buffer.format
        let samplesPerChannel = vDSP_Length(buffer.frameLength)
        var peak: Float = 0
        if format.isInterleaved {
            vDSP_maxmgv(channels[0], 1, &peak, samplesPerChannel * vDSP_Length(format.channelCount))
        } else {
            for channel in 0..<Int(format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, samplesPerChannel)
                peak = max(peak, channelPeak)
            }
        }
        return peak
    }
}
