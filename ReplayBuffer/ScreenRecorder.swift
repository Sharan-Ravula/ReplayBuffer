import ScreenCaptureKit
import AVFoundation
import AppKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenRecorder()

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "screen.recorder.sample.queue")

    private override init() { super.init() }

    /// Fetches the current list of capturable displays (for the picker). Call this
    /// when the menu opens; ScreenCaptureKit needs Screen Recording permission granted
    /// for this to return anything.
    func refreshAvailableDisplays() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let options = content.displays.map { display -> DisplayOption in
            let matchingScreen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            let name = matchingScreen?.localizedName ?? "Display \(display.displayID)"
            return DisplayOption(id: display.displayID, name: name)
        }
        await MainActor.run {
            AppState.shared.availableDisplays = options
            if AppState.shared.selectedDisplayID == nil {
                AppState.shared.selectedDisplayID = options.first?.id
            }
        }
    }

    func start(displayID: CGDirectDisplayID?, fpsOption: FPSOption, scale: ScaleOption, showCursor: Bool, includeSystemAudio: Bool, includeMic: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let display: SCDisplay
        if let displayID = displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
            display = match
        } else if let first = content.displays.first {
            display = first
        } else {
            throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // SCDisplay.width/height are in POINTS, not physical pixels. On any Retina
        // display (2x backing scale, which is virtually every modern Mac screen),
        // using these directly captures at HALF the linear resolution — a quarter
        // of the actual pixel count — even with "Native" selected. That's almost
        // certainly why recordings looked like a much lower resolution than the
        // real display. Multiply by the matching NSScreen's backingScaleFactor to
        // get the true native pixel dimensions before applying any user downscale.
        let matchingScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        let backingScaleFactor = matchingScreen?.backingScaleFactor ?? 2.0
        let nativePixelWidth = Double(display.width) * backingScaleFactor
        let nativePixelHeight = Double(display.height) * backingScaleFactor
        // Keep dimensions even (required by the H.264 encoder).
        config.width = max(2, Int(nativePixelWidth * scale.rawValue)) & ~1
        config.height = max(2, Int(nativePixelHeight * scale.rawValue)) & ~1

        let frameRateHint: Int
        switch fpsOption {
        case .fps30:
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            frameRateHint = 30
        case .fps60:
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            frameRateHint = 60
        case .unlimited:
            // Effectively uncapped: ScreenCaptureKit will still only deliver as fast
            // as the display refreshes, this just removes our own throttle.
            config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            frameRateHint = 60
        }

        // More headroom for ScreenCaptureKit to buffer frames if our processing
        // momentarily falls behind (e.g. during fast-motion content like
        // gameplay), instead of dropping/stalling frames outright.
        config.queueDepth = 16
        config.showsCursor = showCursor
        config.capturesAudio = includeSystemAudio
        config.sampleRate = 48000
        config.channelCount = 2
        // Force standard-gamut capture. Without this, ScreenCaptureKit captures in
        // the display's native wide gamut (Display P3 on virtually every modern
        // Mac), while our encoder tags output as the narrower Rec.709 — that
        // mismatch (wide-gamut pixel values interpreted under a narrower gamut
        // assumption) is what produced the faded/washed look. Pinning both ends
        // to the same standard gamut keeps them consistent.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        BufferManager.shared.configure(
            width: config.width,
            height: config.height,
            includeSystemAudio: includeSystemAudio,
            includeMic: includeMic,
            frameRateHint: frameRateHint
        )
        BufferManager.shared.reset()
        expectedFrameGap = 1.0 / Double(max(1, frameRateHint))
        lastVideoPTS = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if includeSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        try await stream.startCapture()
        self.stream = stream

        if includeMic {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                MicCapture.shared.start { result in
                    cont.resume(with: result)
                }
            }
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        MicCapture.shared.stop()
    }

    private var lastVideoPTS: CMTime?
    private var expectedFrameGap: Double = 1.0 / 60.0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRawValue = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue) else { return }

            guard status == .complete else {
                // Diagnostic: this tells us definitively whether ScreenCaptureKit
                // itself is delivering non-complete frames (idle/blank/suspended),
                // which we already skip — if this fires around when a flash is
                // seen, the cause is upstream of our code entirely.
                print("[ReplayBuffer] Non-complete frame status: \(status.rawValue) at \(Date())")
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let last = lastVideoPTS {
                let gap = CMTimeSubtract(pts, last).seconds
                // Flag any gap more than ~3x what we'd expect at the current
                // frame rate — a real stall in frame delivery, not just normal
                // jitter. If this correlates with an observed flash, the cause
                // is a genuine capture-side delivery gap (outside our control),
                // not our segment rotation or encoding.
                if gap > expectedFrameGap * 3 {
                    print("[ReplayBuffer] Frame gap: \(String(format: "%.3f", gap))s (expected ~\(String(format: "%.3f", expectedFrameGap))s) at \(Date())")
                }
            }
            lastVideoPTS = pts

            BufferManager.shared.ingest(sampleBuffer: sampleBuffer, track: .video)
        case .audio:
            BufferManager.shared.ingest(sampleBuffer: sampleBuffer, track: .systemAudio)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            AppState.shared.isRecording = false
            AppState.shared.statusMessage = "Stopped: \(error.localizedDescription)"
        }
    }
}
