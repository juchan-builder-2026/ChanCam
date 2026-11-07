import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import SwiftUI
import UIKit

/// 촬영 담당. 48MP Apple ProRAW + LiDAR 깊이 + 인물 매트를 한 번에 받는다.
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

    /// 촬영 직후 셔터 피드백용
    @Published private(set) var flashOverlay = false

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.chan.cam.session")
    private var device: AVCaptureDevice?
    private var proRAWFormat: OSType?
    private var supportsDepth = false
    private var supportsMatte = false
    private var pendingCaptures: [Int64: CaptureBundle] = [:]
    private var latestDepthDistance: Float = 0

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

        if withDepth, output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }
        if output.isDepthDataDeliveryEnabled, output.isPortraitEffectsMatteDeliverySupported {
            output.isPortraitEffectsMatteDeliveryEnabled = true
            supportsMatte = true
        }

        output.connection(with: .video)?.videoRotationAngle = 90

        session.commitConfiguration()

        let dims = output.maxPhotoDimensions
        let mp = Double(dims.width) * Double(dims.height) / 1_000_000
        let raw = output.isAppleProRAWEnabled ? "ProRAW" : (proRAWFormat != nil ? "RAW" : "압축")
        let depthText = output.isDepthDataDeliveryEnabled ? " · LiDAR 깊이" : " · 깊이 없음"
        let matteText = supportsMatte ? " · 인물 매트" : ""
        Task { @MainActor in
            self.isReady = true
            self.modeLabel = String(format: "%.0fMP %@", mp.rounded(), raw)
            self.detailLabel = "\(dims.width)×\(dims.height)\(depthText)\(matteText)"
        }
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
        let focusNow = latestDepthDistance
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
            if self.output.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = false
            }
            let bundle = CaptureBundle()
            bundle.focusDistance = focusNow
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
