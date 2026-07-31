import AVFoundation

enum TrackKind {
    case video
    case systemAudio
    case mic
}

/// Writes one short segment (e.g. ~4s) of captured video/audio to a temp .mov file.
/// The rolling buffer is made of many of these; old ones get deleted as the window slides.
/// System audio and mic are kept as separate tracks here; they get mixed down to one
/// track later at export time (see SegmentExporter).
final class SegmentWriter {
    let url: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var firstPTS: CMTime?
    private(set) var duration: TimeInterval = 0

    init?(directory: URL, width: Int, height: Int, includeSystemAudio: Bool, includeMic: Bool, frameRateHint: Int) {
        let name = "seg_\(Int(Date().timeIntervalSince1970 * 1000)).mov"
        self.url = directory.appendingPathComponent(name)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }

        let videoSettings: [String: Any] = [
            // HEVC's hardware encoder on Apple Silicon is meaningfully more
            // efficient than H.264 for equivalent quality — less GPU/media
            // engine load for the same visual result, which matters a lot
            // here since this runs continuously in real time. This is a
            // direct response to observed system-wide GPU contention
            // (cursor lag) while recording.
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Per Apple's TN2227: screen capture is automatically converted to the
            // HD (Rec.709) color space, and AVAssetWriter should be explicitly told
            // to tag output as Rec.709 to match — leaving it untagged is what Apple
            // warns can cause exactly the color mismatch we were seeing.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                // Quality-based rate control (like QuickTime Player's screen
                // recording) instead of a fixed bitrate cap. Was dropped to
                // 0.65 while chasing what turned out to be a cursor-compositing
                // bottleneck (fixed via the "Show cursor in recording" toggle,
                // not a quality/bitrate issue at all). Restored to 0.85 now
                // that the real cause is addressed — test that lag stays gone
                // at this level; if so we likely have room to go even higher.
                AVVideoQualityKey: 0.85,
                // NOTE: no AVVideoProfileLevelKey here — that constant
                // (AVVideoProfileLevelH264HighAutoLevel) is H.264-specific and
                // invalid for HEVC; the encoder picks an appropriate HEVC
                // profile automatically.
                AVVideoExpectedSourceFrameRateKey: frameRateHint
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }
        self.videoInput = vInput

        func makeAudioInput() -> AVAssetWriterInput {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            return aInput
        }

        if includeSystemAudio {
            let aInput = makeAudioInput()
            if writer.canAdd(aInput) { writer.add(aInput) }
            self.systemAudioInput = aInput
        }
        if includeMic {
            let mInput = makeAudioInput()
            if writer.canAdd(mInput) { writer.add(mInput) }
            self.micInput = mInput
        }

        self.writer = writer
    }

    func append(sampleBuffer: CMSampleBuffer, track: TrackKind) {
        guard let writer = writer else { return }

        if writer.status == .unknown {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            sessionStarted = true
        }

        guard writer.status == .writing else { return }

        switch track {
        case .video:
            if let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if let first = firstPTS {
                    duration = CMTimeSubtract(pts, first).seconds
                }
            }
        case .systemAudio:
            if let input = systemAudioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .mic:
            if let input = micInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    func finish(_ completion: @escaping () -> Void) {
        guard let writer = writer, sessionStarted else {
            completion()
            return
        }
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        writer.finishWriting {
            completion()
        }
    }
}
