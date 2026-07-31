import AVFoundation

/// Video-only counterpart to BufferManager, for the separate camera file.
/// Same rolling-segment approach, just no audio tracks and a fixed
/// resolution/frame rate matching the camera session.
final class CameraBufferManager {
    static let shared = CameraBufferManager()

    private let segmentDuration: TimeInterval = 10.0
    private let prewarmMargin: TimeInterval = 1.0
    private var segments: [SegmentWriter] = []
    private var currentSegment: SegmentWriter?
    private var nextSegment: SegmentWriter?
    private let workDir: URL
    private let queue = DispatchQueue(label: "camera.buffer.manager.queue", qos: .userInteractive)

    private let width = 1280
    private let height = 720
    private let frameRateHint = 30

    private init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayBufferCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.workDir = base
        cleanupOldFiles()
    }

    private func cleanupOldFiles() {
        if let files = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
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
            includeSystemAudio: false,
            includeMic: false,
            frameRateHint: frameRateHint
        )
    }

    func ingest(sampleBuffer: CMSampleBuffer) {
        queue.async {
            if self.currentSegment == nil {
                self.currentSegment = self.nextSegment ?? self.makeSegmentWriter()
                self.nextSegment = nil
            }
            self.currentSegment?.append(sampleBuffer: sampleBuffer, track: .video)

            if let seg = self.currentSegment {
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

    /// Same trailing-window trim + export approach as BufferManager, just
    /// without any audio tracks. Saves to the same directory as the screen
    /// clip, with a "-camera" filename suffix so the timestamp lines them up.
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

            self.buildCompositionAndExport(from: allSegments, bufferSeconds: bufferSeconds, completion: mainThreadCompletion)
        }
    }

    private func buildCompositionAndExport(from segs: [SegmentWriter], bufferSeconds: Double, completion: @escaping (URL?) -> Void) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        Task {
            var totalInserted: TimeInterval = 0
            var insertedSegments: [(AVURLAsset, CMTimeRange)] = []

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

            insertedSegments.reverse()

            var cursor = CMTime.zero
            for (asset, range) in insertedSegments {
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                if let vTrack = videoTracks.first {
                    try? videoTrack.insertTimeRange(range, of: vTrack, at: cursor)
                }
                cursor = CMTimeAdd(cursor, range.duration)
            }

            let outDir = AppState.shared.saveDirectory
            if !FileManager.default.fileExists(atPath: outDir.path) {
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let outURL = outDir.appendingPathComponent("Replay-\(formatter.string(from: Date()))-camera.mov")

            SegmentExporter.export(composition: composition, to: outURL) { result in
                switch result {
                case .success(let url):
                    completion(url)
                case .failure(let error):
                    print("Camera export failed: \(error)")
                    completion(nil)
                }
            }
        }
    }
}
