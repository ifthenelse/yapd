import AVFoundation

enum RecordingMixerError: LocalizedError {
    case exportUnavailable

    var errorDescription: String? { "Couldn't create the audio file." }
}

/// Combines the per-source tracks into one AAC `.m4a`.
enum RecordingMixer {
    struct Track {
        var url: URL
        /// Host time of the track's first sample, used to line tracks up.
        var startHostTime: UInt64
    }

    static func mix(_ tracks: [Track], into output: URL) async throws {
        let composition = AVMutableComposition()
        let origin = tracks.map(\.startHostTime).min() ?? 0

        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            let offset = CMTime(
                seconds: AVAudioTime.seconds(forHostTime: track.startHostTime - origin),
                preferredTimescale: 48_000
            )
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try compositionTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: offset
            )
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingMixerError.exportUnavailable
        }
        try await session.export(to: output, as: .m4a)
    }
}
