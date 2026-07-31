import AVFoundation

/// Captures webcam video as its own independent rolling buffer/file, separate
/// from the screen recording. Mirrors MicCapture's structure and lessons
/// learned there (proper session teardown, commitConfiguration before
/// startRunning, hopping off requestAccess's arbitrary callback queue).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated static let shared = CameraCapture()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "camera.capture.sample.queue")
    private let sessionQueue = DispatchQueue(label: "camera.capture.session.queue")
    private var currentInput: AVCaptureDeviceInput?
    private var isRunning = false
    private var isStarting = false

    private override init() { super.init() }

    /// Lists available camera devices for the picker.
    static func listAvailableDevices() -> [CameraDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    nonisolated func start(completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async {
            guard !self.isRunning && !self.isStarting else {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            self.isStarting = true

            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.sessionQueue.async {
                    guard granted else {
                        self.isStarting = false
                        DispatchQueue.main.async {
                            completion(.failure(NSError(
                                domain: "CameraCapture", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Camera access was denied. Enable it in System Settings > Privacy & Security > Camera."]
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
        teardownLocked()
        CameraBufferManager.shared.reset()

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let device: AVCaptureDevice
        if let selectedID = AppState.shared.selectedCameraID,
           let match = AVCaptureDevice(uniqueID: selectedID) {
            device = match
        } else if let defaultDevice = AVCaptureDevice.default(for: .video) {
            device = defaultDevice
        } else {
            session.commitConfiguration()
            throw NSError(domain: "CameraCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found"])
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

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        // commitConfiguration MUST happen before startRunning.
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

    /// Must only be called on sessionQueue.
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
        CameraBufferManager.shared.ingest(sampleBuffer: sampleBuffer)
    }
}
