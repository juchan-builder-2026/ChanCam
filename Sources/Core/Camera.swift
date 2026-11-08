import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import SwiftUI
import UIKit

/// 48MP ProRAW 와 사진 출력의 깊이 전달은 동시에 못 쓴다 — 48MP 가 조용히 떨어지거나
/// 깊이가 아예 안 온다 (v1.0 에서 LiDAR 가 안 찍힌 이유). 그래서 깊이는 전용 출력으로
/// 계속 흘려 받고 셔터 순간의 마지막 프레임을 붙인다. 해상도도 지키고 깊이도 얻는 길.
final class DepthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AVDepthData?
    private var distance: Float = 0
    private var publishedStamp = 0
    private var frames = 0
    private var coverage: Double = 0
    private var fps: Double = 0
    private var lastTimestamp: Double = 0

    func store(_ depth: AVDepthData, distance: Float, coverage: Double, timestamp: Double) {
        lock.lock(); defer { lock.unlock() }
        value = depth
        self.distance = distance
        self.coverage = coverage
        frames += 1
        if lastTimestamp > 0, timestamp > lastTimestamp {
            let instant = 1 / (timestamp - lastTimestamp)
            fps = fps > 0 ? fps * 0.8 + instant * 0.2 : instant
        }
        lastTimestamp = timestamp
    }
    var latest: AVDepthData? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    var latestDistance: Float {
        lock.lock(); defer { lock.unlock() }
        return distance
    }
    /// (fps, 유효 픽셀 비율, 받은 프레임 수) — 센서 테스터용
    var stats: (fps: Double, coverage: Double, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (fps, coverage, frames)
    }
    /// 화면 갱신 throttle — 같은 1/4초 구간이면 false
    func shouldPublish(_ stamp: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stamp != publishedStamp else { return false }
        publishedStamp = stamp
        return true
    }
}

/// 세션을 실제로 구성한 뒤 확정된 하드웨어 능력. 센서 테스터가 이걸 읽는다.
/// (세션에 붙기 전의 AVCapturePhotoOutput 은 전부 false 라서 의미가 없다.)
struct CameraCapabilities: Sendable {
    var configured = false
    var deviceName = "—"
    var proRAW = false
    var proRAWEnabled = false
    var depthDelivery = false
    var streamingDepth = false
    var portraitMatte = false
    var distortionCorrection = false
    var zeroShutterLag = false
    var responsiveCapture = false
    var rawFormats = 0
    var maxPhotoWidth = 0
    var maxPhotoHeight = 0
    var depthWidth = 0
    var depthHeight = 0
}

extension Camera {
    typealias Capabilities = CameraCapabilities
}

/// 촬영 담당. 48MP Apple ProRAW + LiDAR 깊이 + 인물 분리를 한 번에 받는다.
///
/// 기기가 어떤 조합을 지원하는지는 실행 시점에만 알 수 있어서,
/// 우선순위대로 시도하고 실제로 잡힌 구성을 `modeLabel` 로 보여준다.
///   1순위  LiDAR 카메라 + 최대 해상도 + 깊이
///   2순위  일반 광각 + 최대 해상도 (깊이 없음)
@MainActor
final class Camera: NSObject, ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var modeLabel = "준비 중"
    @Published private(set) var detailLabel = ""
    @Published private(set) var lastError: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var liveFocusDistance: Float = 0
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var depthFPS: Double = 0
    @Published private(set) var depthCoverage: Double = 0
    @Published private(set) var depthFrames = 0

    /// 촬영 직후 셔터 피드백용
    @Published private(set) var flashOverlay = false

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.chan.cam.session")
    private let depthQueue = DispatchQueue(label: "com.chan.cam.depth")
    private var device: AVCaptureDevice?
    private var proRAWFormat: OSType?
    private var supportsDepth = false
    private var streamingDepth = false
    private var pendingCaptures: [Int64: CaptureBundle] = [:]

    /// 스트리밍 깊이 보관함. 세션 큐·깊이 큐·메인 어디서나 읽어야 해서 락으로 지킨다.
    private let depthBox = DepthBox()

    var onShot: ((Shot) -> Void)?

    private final class CaptureBundle {
        var rawData: Data?
        var previewData: Data?
        var depth: AVDepthData?
        var matte: AVPortraitEffectsMatte?
        var metadata: [String: Any] = [:]
        var dimensions = CGSize.zero
        var focusDistance: Float = 0
    }

    // MARK: - 설정

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureAndRun() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configure()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // 1) 카메라 고르기 — LiDAR 우선
        var picked: (AVCaptureDevice, AVCaptureDevice.Format, Bool)?
        let candidates: [AVCaptureDevice.DeviceType] = [
            .builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInWideAngleCamera,
        ]
        for type in candidates {
            guard let candidate = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            if let best = Camera.bestFormat(candidate, requireDepth: true) {
                picked = (candidate, best, true)
                break
            }
            if picked == nil, let best = Camera.bestFormat(candidate, requireDepth: false) {
                picked = (candidate, best, false)
            }
        }
        guard let (device, format, withDepth) = picked else {
            session.commitConfiguration()
            Task { @MainActor in self.lastError = "뒷면 카메라를 찾지 못했어요" }
            return
        }
        self.device = device
        supportsDepth = withDepth

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            // 깊이 포맷을 직접 골라야 깊이가 흐른다 (기본값은 nil = 깊이 없음)
            if withDepth {
                let depthFormats = format.supportedDepthDataFormats.filter { candidate in
                    let type = CMFormatDescriptionGetMediaSubType(candidate.formatDescription)
                    return type == kCVPixelFormatType_DepthFloat32
                        || type == kCVPixelFormatType_DepthFloat16
                        || type == kCVPixelFormatType_DisparityFloat32
                        || type == kCVPixelFormatType_DisparityFloat16
                }
                let pool = depthFormats.isEmpty ? format.supportedDepthDataFormats : depthFormats
                if let best = pool.max(by: { a, b in
                    let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                    let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                    return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
                }) {
                    device.activeDepthDataFormat = best
                }
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch {
            Task { @MainActor in self.lastError = "카메라 설정 실패 — \(error.localizedDescription)" }
        }

        // 2) 입력
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }

        // 3) 사진 출력
        if session.outputs.contains(output) == false, session.canAddOutput(output) {
            session.addOutput(output)
        }
        output.maxPhotoQualityPrioritization = .quality
        let maxDim = format.supportedMaxPhotoDimensions.max { $0.width * $0.height < $1.width * $1.height }
        if let maxDim { output.maxPhotoDimensions = maxDim }

        if output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = true
            proRAWFormat = output.availableRawPhotoPixelFormatTypes.first(where: {
                AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
            })
        }
        if proRAWFormat == nil {
            proRAWFormat = output.availableRawPhotoPixelFormatTypes.first
        }

        // 4) 깊이 — 사진 출력의 깊이 전달이 아니라 전용 스트리밍 출력을 쓴다.
        //    (사진 깊이 전달을 켜면 48MP 를 못 쓰고, 실제로 깊이가 안 오는 경우도 있다)
        streamingDepth = false
        if withDepth {
            if session.outputs.contains(depthOutput) == false, session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
            }
            if session.outputs.contains(depthOutput) {
                depthOutput.isFilteringEnabled = true
                depthOutput.alwaysDiscardsLateDepthData = true
                depthOutput.setDelegate(self, callbackQueue: depthQueue)
                if let connection = depthOutput.connection(with: .depthData) {
                    connection.isEnabled = true
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90   // 사진과 같은 세로 방향으로
                    }
                    streamingDepth = connection.isEnabled
                }
            }
        }
        // 스트리밍이 안 되면 사진 깊이 전달로 폴백 (해상도를 양보하고 깊이를 얻는다)
        if !streamingDepth, withDepth, output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }

        output.connection(with: .video)?.videoRotationAngle = 90

        session.commitConfiguration()

        let dims = output.maxPhotoDimensions
        let mp = Double(dims.width) * Double(dims.height) / 1_000_000
        let raw = output.isAppleProRAWEnabled ? "ProRAW" : (proRAWFormat != nil ? "RAW" : "압축")
        let hasDepth = streamingDepth || output.isDepthDataDeliveryEnabled
        let depthText = streamingDepth ? " · LiDAR 깊이(스트림)"
            : (hasDepth ? " · 깊이" : " · 깊이 없음")
        let matteText = hasDepth ? " · 인물 분리" : ""

        var caps = CameraCapabilities()
        caps.configured = true
        caps.deviceName = device.localizedName
        caps.proRAW = output.isAppleProRAWSupported
        caps.proRAWEnabled = output.isAppleProRAWEnabled
        caps.depthDelivery = output.isDepthDataDeliverySupported
        caps.streamingDepth = streamingDepth
        caps.portraitMatte = output.isPortraitEffectsMatteDeliverySupported
        caps.distortionCorrection = output.isContentAwareDistortionCorrectionSupported
        caps.zeroShutterLag = output.isZeroShutterLagSupported
        caps.responsiveCapture = output.isResponsiveCaptureSupported
        caps.rawFormats = output.availableRawPhotoPixelFormatTypes.count
        caps.maxPhotoWidth = Int(dims.width)
        caps.maxPhotoHeight = Int(dims.height)
        if let activeDepth = device.activeDepthDataFormat {
            let d = CMVideoFormatDescriptionGetDimensions(activeDepth.formatDescription)
            caps.depthWidth = Int(d.width)
            caps.depthHeight = Int(d.height)
        }

        Task { @MainActor in
            self.isReady = true
            self.modeLabel = String(format: "%.0fMP %@", mp.rounded(.down), raw)
            self.detailLabel = "\(dims.width)×\(dims.height)\(depthText)\(matteText)"
            self.capabilities = caps
        }
    }

    /// 센서 테스터가 주기적으로 호출 — 깊이 스트림 통계를 화면으로 올린다
    func refreshDepthStats() {
        let stats = depthBox.stats
        depthFPS = stats.fps
        depthCoverage = stats.coverage
        depthFrames = stats.frames
    }

    /// 깊이를 지원하면서 가장 해상도가 높은 포맷
    private static func bestFormat(_ device: AVCaptureDevice, requireDepth: Bool) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { format in
            guard !format.supportedMaxPhotoDimensions.isEmpty else { return false }
            if requireDepth && format.supportedDepthDataFormats.isEmpty { return false }
            return true
        }
        return usable.max { a, b in
            let pa = a.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            let pb = b.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            return pa < pb
        }
    }

    // MARK: - 조작

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            device.unlockForConfiguration()
        }
    }

    func setExposureBias(_ ev: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            let clamped = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
            try? device.lockForConfiguration()
            device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()
        }
    }

    func capture() {
        guard isReady, !isCapturing else { return }
        isCapturing = true
        flashOverlay = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            self.flashOverlay = false
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings: AVCapturePhotoSettings
            if let rawFormat = self.proRAWFormat {
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawFormat,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if self.output.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = false
                settings.isDepthDataFiltered = true
            }
            let bundle = CaptureBundle()
            // 셔터 순간의 마지막 LiDAR 프레임을 붙인다
            bundle.depth = self.depthBox.latest
            bundle.focusDistance = self.depthBox.latestDistance
            self.pendingCaptures[settings.uniqueID] = bundle
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - 사진 콜백

extension Camera: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        if let error {
            Task { @MainActor in
                self.pendingCaptures[id] = nil
                self.isCapturing = false
                self.lastError = "촬영 실패 — \(error.localizedDescription)"
            }
            return
        }
        let data = photo.fileDataRepresentation()
        let isRaw = photo.isRawPhoto
        let meta = photo.metadata
        let width = photo.resolvedSettings.photoDimensions.width
        let height = photo.resolvedSettings.photoDimensions.height
        let depth = photo.depthData
        let matte = photo.portraitEffectsMatte

        Task { @MainActor in
            guard let bundle = self.pendingCaptures[id] else { return }
            if isRaw {
                bundle.rawData = data
                bundle.dimensions = CGSize(width: Int(width), height: Int(height))
            } else {
                bundle.previewData = data
                if bundle.dimensions == .zero {
                    bundle.dimensions = CGSize(width: Int(width), height: Int(height))
                }
            }
            if bundle.metadata.isEmpty { bundle.metadata = meta }
            if let depth { bundle.depth = depth }
            if let matte { bundle.matte = matte }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        let id = resolvedSettings.uniqueID
        Task { @MainActor in
            defer {
                self.pendingCaptures[id] = nil
                self.isCapturing = false
            }
            guard let bundle = self.pendingCaptures[id] else { return }
            if let error {
                self.lastError = "저장 실패 — \(error.localizedDescription)"
                return
            }
            do {
                let shot = try ShotStore.shared.save(
                    raw: bundle.rawData,
                    preview: bundle.previewData,
                    depth: bundle.depth,
                    matte: bundle.matte,
                    metadata: bundle.metadata,
                    dimensions: bundle.dimensions,
                    focusDistance: bundle.focusDistance,
                    isProRAW: output.isAppleProRAWEnabled)
                self.onShot?(shot)
            } catch {
                self.lastError = "저장 실패 — \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 깊이 스트림

extension Camera: AVCaptureDepthDataOutputDelegate {

    nonisolated func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                                     didOutput depthData: AVDepthData,
                                     timestamp: CMTime,
                                     connection: AVCaptureConnection) {
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let measured = Camera.measure(converted.depthDataMap)
        depthBox.store(converted, distance: measured.distance,
                       coverage: measured.coverage, timestamp: timestamp.seconds)

        // 화면 표시는 초당 몇 번이면 충분하다
        if depthBox.shouldPublish(Int(timestamp.seconds * 4)) {
            let stats = depthBox.stats
            Task { @MainActor in
                self.liveFocusDistance = measured.distance
                self.depthFPS = stats.fps
                self.depthCoverage = stats.coverage
                self.depthFrames = stats.frames
            }
        }
    }

    /// 중앙 1/3 영역의 유효 깊이 중앙값(m)과 화면 전체의 유효 픽셀 비율을 한 번에 센다.
    /// 유효 비율은 "LiDAR 가 정말 읽고 있나"를 보는 가장 직접적인 숫자다.
    nonisolated static func measure(_ buffer: CVPixelBuffer) -> (distance: Float, coverage: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 8, height > 8, let base = CVPixelBufferGetBaseAddress(buffer) else {
            return (0, 0)
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let isDisparity = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DisparityFloat32
        var samples: [Float] = []
        samples.reserveCapacity(512)
        var valid = 0, total = 0
        let step = max(min(width, height) / 32, 1)
        let cx0 = width / 3, cx1 = width * 2 / 3
        let cy0 = height / 3, cy1 = height * 2 / 3
        for y in stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in stride(from: 0, to: width, by: step) {
                var v = row[x]
                total += 1
                guard v.isFinite, v > 0 else { continue }
                if isDisparity { v = 1 / v }
                guard v > 0.05, v < 40 else { continue }
                valid += 1
                if x >= cx0, x < cx1, y >= cy0, y < cy1 { samples.append(v) }
            }
        }
        let coverage = total > 0 ? Double(valid) / Double(total) : 0
        guard !samples.isEmpty else { return (0, coverage) }
        samples.sort()
        return (samples[samples.count / 2], coverage)
    }
}

// MARK: - 미리보기

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTap = onTap
    }

    final class PreviewView: UIView {
        var onTap: ((CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            let device = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(device)
        }
    }
}
