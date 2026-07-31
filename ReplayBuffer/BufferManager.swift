import AVFoundation
import AppKit

/// Keeps a rolling window of segment files on disk covering the last `bufferSeconds`.
/// When asked to save, stitches the relevant segments (trimming the oldest one) into
/// a composition, then hands off to SegmentExporter to mix audio down and write the
/// final clip.
final class BufferManager {
    static let shared = BufferManager()

    private let segmentDuration: TimeInterval = 10.0
    private let prewarmMargin: TimeInterval = 1.0
    private var segments: [SegmentWriter] = []
    private var currentSegment: SegmentWriter?
    private var nextSegment: SegmentWriter?
    private let workDir: URL
    private let queue = DispatchQueue(label: "buffer.manager.queue", qos: .userInteractive)

    private var width = 1920
    private var height = 1080
    private var includeSystemAudio = false
    private var includeMic = false
    private var frameRateHint = 60

    private init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayBuffer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.workDir = base
        cleanupOldFiles()
    }

    private func cleanupOldFiles() {
        if let files = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    func configure(width: Int, height: Int, includeSystemAudio: Bool, includeMic: Bool, frameRateHint: Int) {
        queue.async {
            self.width = width
            self.height = height
            self.includeSystemAudio = includeSystemAudio
            self.includeMic = includeMic
            self.frameRateHint = frameRateHint
        }
    }

    func reset() {
        queue.async {
            self.currentSegment?.finish {}
            self.currentSegment = nil
            self.nextSegment?.finish {}
            self.nextSegment = nil
            for s in self.segments { try? FileManager.default.removeItem(at: s.url) }
            self.segments.removeAll()
        }
    }

    private func makeSegmentWriter() -> SegmentWriter? {
        SegmentWriter(
            directory: workDir,
            width: width,
            height: height,
            includeSystemAudio: includeSystemAudio,
            includeMic: includeMic,
            frameRateHint: frameRateHint
        )
    }

    func ingest(sampleBuffer: CMSampleBuffer, track: TrackKind) {
        queue.async {
            if self.currentSegment == nil {
                // Use the pre-warmed writer if one's ready; only pay the
                // (cheap but non-zero) AVAssetWriter setup cost inline here on
                // the very first segment of a recording session.
                self.currentSegment = self.nextSegment ?? self.makeSegmentWriter()
                self.nextSegment = nil
            }
            self.currentSegment?.append(sampleBuffer: sampleBuffer, track: track)

            if let seg = self.currentSegment {
                // Prepare the NEXT writer a little before we actually need it,
                // while still appending normally to the current one. By the
                // time rotation actually happens below, the new writer already
                // exists — rotation becomes a pointer swap, not a construction
                // happening on the critical frame, which is what could cause a
                // visible stall/flash right at the rotation boundary.
                if self.nextSegment == nil && seg.duration >= self.segmentDuration - self.prewarmMargin {
                    self.nextSegment = self.makeSegmentWriter()
                }

                if seg.duration >= self.segmentDuration {
                    let finished = seg
                    self.currentSegment = self.nextSegment
                    self.nextSegment = nil
                    finished.finish {
                        self.queue.async {
                            self.segments.append(finished)
                            self.trimOldSegments(maxBufferSeconds: AppState.shared.bufferSeconds)
                        }
                    }
                }
            }
        }
    }

    private func trimOldSegments(maxBufferSeconds: Double) {
        var total: TimeInterval = 0
        var keep: [SegmentWriter] = []
        for seg in segments.reversed() {
            keep.append(seg)
            total += seg.duration
            if total >= maxBufferSeconds + segmentDuration { break }
        }
        keep.reverse()
        let keepURLs = Set(keep.map { $0.url })
        let toRemove = segments.filter { !keepURLs.contains($0.url) }
        for r in toRemove { try? FileManager.default.removeItem(at: r.url) }
        segments = keep
    }

    /// Finalizes the in-progress segment, then exports the trailing `bufferSeconds`
    /// of footage to a file on the Desktop, mixing system audio + mic into one track.
    /// The completion is always invoked on the main thread, since AVAssetWriter's
    /// finishWriting callback (and thus our export pipeline) can land on an
    /// arbitrary background queue, and callers update @Published UI state from it.
    func saveClip(bufferSeconds: Double, completion: @escaping (URL?) -> Void) {
        let mainThreadCompletion: (URL?) -> Void = { url in
            DispatchQueue.main.async { completion(url) }
        }
        queue.async {
            var allSegments = self.segments
            if let current = self.currentSegment {
                let finished = current
                self.currentSegment = nil
                let semaphore = DispatchSemaphore(value: 0)
                finished.finish { semaphore.signal() }
                semaphore.wait()
                if finished.duration > 0 {
                    allSegments.append(finished)
                }
            }

            guard !allSegments.isEmpty else {
                mainThreadCompletion(nil)
                return
            }

            Task {
                let url = await self.buildCompositionAndExport(from: allSegments, bufferSeconds: bufferSeconds)
                mainThreadCompletion(url)
            }
        }
    }

    private func buildCompositionAndExport(from segs: [SegmentWriter], bufferSeconds: Double) async -> URL? {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        var systemAudioTrack: AVMutableCompositionTrack?
        var micTrack: AVMutableCompositionTrack?
        if includeSystemAudio {
            systemAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        if includeMic {
            micTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var totalInserted: TimeInterval = 0
        var insertedSegments: [(AVURLAsset, CMTimeRange)] = []

        // Walk newest -> oldest, collecting whole segments until we'd exceed the window,
        // then trim just the oldest one to fit exactly.
        for seg in segs.reversed() {
            let asset = AVURLAsset(url: seg.url)
            guard let assetDurationCM = try? await asset.load(.duration) else { continue }
            let assetDuration = assetDurationCM.seconds
            guard assetDuration.isFinite, assetDuration > 0 else { continue }

            let remaining = bufferSeconds - totalInserted
            if remaining <= 0 { break }

            if remaining >= assetDuration {
                insertedSegments.append((asset, CMTimeRange(start: .zero, duration: assetDurationCM)))
                totalInserted += assetDuration
            } else {
                let startSeconds = assetDuration - remaining
                let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
                let range = CMTimeRange(start: start, duration: CMTimeSubtract(assetDurationCM, start))
                insertedSegments.append((asset, range))
                totalInserted += remaining
                break
            }
        }

        insertedSegments.reverse() // back to chronological order

        var cursor = CMTime.zero
        for (asset, range) in insertedSegments {
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if let vTrack = videoTracks.first {
                try? videoTrack.insertTimeRange(range, of: vTrack, at: cursor)
            }
            let assetAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            // Segment audio tracks were added in order: system audio (if any), then mic (if any).
            var idx = 0
            if includeSystemAudio, let sysTrack = systemAudioTrack {
                if idx < assetAudioTracks.count {
                    try? sysTrack.insertTimeRange(range, of: assetAudioTracks[idx], at: cursor)
                }
                idx += 1
            }
            if includeMic, let mTrack = micTrack {
                if idx < assetAudioTracks.count {
                    try? mTrack.insertTimeRange(range, of: assetAudioTracks[idx], at: cursor)
                }
                idx += 1
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        let outDir = AppState.shared.saveDirectory
        if !FileManager.default.fileExists(atPath: outDir.path) {
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let outURL = outDir.appendingPathComponent("Replay-\(formatter.string(from: Date())).mov")

        return await withCheckedContinuation { continuation in
            SegmentExporter.export(composition: composition, to: outURL) { result in
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    print("Export failed: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
