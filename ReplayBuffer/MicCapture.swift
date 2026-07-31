import AVFoundation

/// Captures microphone audio as its own stream so it can be muxed/mixed
/// with system audio separately. Requires NSMicrophoneUsageDescription in Info.plist.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated static let shared = MicCapture()

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "mic.capture.sample.queue")
    private let sessionQueue = DispatchQueue(label: "mic.capture.session.queue")
    private var currentInput: AVCaptureDeviceInput?
    private var isRunning = false
    private var isStarting = false

    private override init() { super.init() }

    /// Lists available microphone/audio input devices for the picker.
    static func listAvailableDevices() -> [MicDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { MicDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    nonisolated func start(completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async {
            guard !self.isRunning && !self.isStarting else {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            self.isStarting = true

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                // requestAccess's completion runs on an arbitrary background
                // queue, not guaranteed to be any particular thread — hop back
                // onto our own dedicated session queue before touching the
                // AVCaptureSession, rather than configuring it from whatever
                // random thread this happened to land on.
                self.sessionQueue.async {
                    guard granted else {
                        self.isStarting = false
                        DispatchQueue.main.async {
                            completion(.failure(NSError(
                                domain: "MicCapture", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."]
                            )))
                        }
                        return
                    }
                    do {
                        try self.configureAndStart()
                        self.isStarting = false
                        DispatchQueue.main.async { completion(.success(())) }
                    } catch {
                        self.isStarting = false
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            }
        }
    }

    /// Must only be called on sessionQueue.
    private func configureAndStart() throws {
        // Tear down any leftover input from a previous start/stop cycle first —
        // otherwise repeated toggling accumulates stale session state.
        teardownLocked()

        session.beginConfiguration()

        let device: AVCaptureDevice
        if let selectedID = AppState.shared.selectedMicDeviceID,
           let match = AVCaptureDevice(uniqueID: selectedID) {
            device = match
        } else if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            device = defaultDevice
        } else {
            session.commitConfiguration()
            throw NSError(domain: "MicCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        // commitConfiguration MUST happen before startRunning — startRunning
        // while configuration is still open throws exactly the crash we hit.
        session.commitConfiguration()

        session.startRunning()
        isRunning = true
    }

    nonisolated func stop() {
        sessionQueue.async {
            guard self.isRunning else { return }
            self.session.stopRunning()
            self.teardownLocked()
            self.isRunning = false
        }
    }

    /// Must only be called on sessionQueue. Removes input/output so the next
    /// start() begins from a clean slate instead of accumulating stale state.
    private func teardownLocked() {
        session.beginConfiguration()
        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        if session.outputs.contains(output) {
            session.removeOutput(output)
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        BufferManager.shared.ingest(sampleBuffer: sampleBuffer, track: .mic)
    }
}
