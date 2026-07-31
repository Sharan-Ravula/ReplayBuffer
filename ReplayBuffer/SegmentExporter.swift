import AVFoundation

/// Reads a composition (1 video track + 0-2 audio tracks) and writes a final file.
/// Video is passed through byte-for-byte (no decode, no re-encode) to avoid a
/// second lossy generation on top of the live capture encode. Audio tracks
/// (system audio + mic, or just one) are mixed down into a single AAC track via
/// AVAssetReaderAudioMixOutput, which requires decoding — there's no way to mix
/// two compressed streams without it.
///
/// IMPORTANT: `reader` must be kept alive (see [reader] capture below) for the
/// duration of the async read/write loop. Neither closure references `reader`
/// directly (only the outputs it owns), so without an explicit capture it has no
/// strong references once this function returns and gets deallocated by ARC
/// almost immediately — AVAssetReaderTrackOutput only holds a WEAK back-reference
/// to its parent reader, so copyNextSampleBuffer() then throws "never added to a
/// reader" even though it clearly was; the reader just no longer exists by the
/// time the async callback fires. This was the actual cause of the export crash,
/// not anything to do with passthrough vs. decode.
enum SegmentExporter {
    enum ExportError: Error { case setupFailed, readFailed, writeFailed }

    static func export(composition: AVComposition, to outputURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            completion(.failure(ExportError.setupFailed))
            return
        }

        guard let reader = try? AVAssetReader(asset: composition),
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            completion(.failure(ExportError.setupFailed))
            return
        }

        // Video: true passthrough, no decode/re-encode — preserves exact quality
        // and color from the live capture encode.
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            completion(.failure(ExportError.setupFailed))
            return
        }
        reader.add(videoReaderOutput)

        let formatHint = videoTrack.formatDescriptions.first as! CMFormatDescription?
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        videoWriterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoWriterInput) else {
            completion(.failure(ExportError.setupFailed))
            return
        }
        writer.add(videoWriterInput)

        // Audio: mix all present tracks (system audio + mic, or just one) down to one AAC track.
        let audioTracks = composition.tracks(withMediaType: .audio)
        var audioReaderOutput: AVAssetReaderAudioMixOutput?
        var audioWriterInput: AVAssetWriterInput?

        if !audioTracks.isEmpty {
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            mixOutput.alwaysCopiesSampleData = false
            if reader.canAdd(mixOutput) {
                reader.add(mixOutput)
                audioReaderOutput = mixOutput
            }

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioWriterInput = aInput
            }
        }

        guard reader.startReading() else {
            completion(.failure(ExportError.readFailed))
            return
        }
        guard writer.startWriting() else {
            completion(.failure(ExportError.writeFailed))
            return
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()

        group.enter()
        videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "export.video.queue")) { [reader] in
            _ = reader // keep the reader alive — see doc comment above
            while videoWriterInput.isReadyForMoreMediaData {
                if let sample = videoReaderOutput.copyNextSampleBuffer() {
                    videoWriterInput.append(sample)
                } else {
                    videoWriterInput.markAsFinished()
                    group.leave()
                    break
                }
            }
        }

        if let audioReaderOutput = audioReaderOutput, let audioWriterInput = audioWriterInput {
            group.enter()
            audioWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "export.audio.queue")) { [reader] in
                _ = reader // keep the reader alive — see doc comment above
                while audioWriterInput.isReadyForMoreMediaData {
                    if let sample = audioReaderOutput.copyNextSampleBuffer() {
                        audioWriterInput.append(sample)
                    } else {
                        audioWriterInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }

        group.notify(queue: .main) {
            writer.finishWriting {
                if writer.status == .completed {
                    completion(.success(outputURL))
                } else {
                    completion(.failure(writer.error ?? ExportError.writeFailed))
                }
            }
        }
    }
}
