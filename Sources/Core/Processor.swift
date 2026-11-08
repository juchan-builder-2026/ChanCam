import CoreImage
import Foundation
import Metal
import Photos
import SwiftUI
import UIKit
import Vision

enum ExportSize: Int, CaseIterable, Identifiable {
    case mp12 = 12
    case mp24 = 24
    case mp48 = 48

    var id: Int { rawValue }
    var title: String { "\(rawValue)MP" }
    var detail: String {
        switch self {
        case .mp12: return "가볍게 · 약 4MB"
        case .mp24: return "a7 III 와 같은 화소 · 약 9MB"
        case .mp48: return "센서 최대 · 약 25MB"
        }
    }
    /// 긴 변 목표 픽셀 (3:4 비율 기준)
    var longSide: Int {
        switch self {
        case .mp12: return 4032
        case .mp24: return 5712
        case .mp48: return 8064
        }
    }
}

/// RAW 디코드 + 백그라운드 현상 큐.
@MainActor
final class Processor: ObservableObject {
    static let shared = Processor()

    @Published private(set) var jobs: [UUID: JobState] = [:]
    @Published private(set) var queueCount = 0
    @Published var lastError: String?

    @AppStorage("exportSize") private var exportSizeRaw = ExportSize.mp24.rawValue
    var exportSize: ExportSize {
        get { ExportSize(rawValue: exportSizeRaw) ?? .mp24 }
        set { exportSizeRaw = newValue.rawValue }
    }

    private let renderer = Renderer.shared
    private let work = DispatchQueue(label: "com.chan.cam.develop", qos: .userInitiated)
    private var pending: [UUID] = []
    private var isRunning = false

    /// 편집 화면용 디코드 캐시. 슬라이더를 움직일 때마다 RAW 를 다시 디코드하면
    /// 1~2초씩 걸린다. 한 번 디코드해 두면 이후엔 GPU 현상만 돌아 즉각 반응한다.
    private let cache = InputCache()

    final class InputCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var value: Renderer.Input?

        func lookup(_ k: String) -> Renderer.Input? {
            lock.lock(); defer { lock.unlock() }
            return key == k ? value : nil
        }
        func store(_ k: String, _ v: Renderer.Input) {
            lock.lock(); defer { lock.unlock() }
            key = k; value = v
        }
        func clear() {
            lock.lock(); defer { lock.unlock() }
            key = nil; value = nil
        }
    }

    func dropCache() { cache.clear() }

    // MARK: - 인물 분리 (Vision)

    /// 48MP ProRAW 와 사진 깊이 전달을 같이 못 쓰기 때문에 애플 인물 매트는 안 온다.
    /// 대신 현상할 때 Vision 으로 사람 영역을 뽑는다. 머리카락 경계가 깊이맵보다 훨씬 정확해서
    /// 보케 경계를 다듬는 데 쓴다. 결과는 파일로 캐시한다.
    nonisolated static func personMatte(previewURL: URL, cacheURL: URL) -> CIImage? {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return CIImage(contentsOf: cacheURL)
        }
        guard let source = CIImage(contentsOf: previewURL, options: [.applyOrientationProperty: true])
        else { return nil }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let context = CIContext(options: [.cacheIntermediates: false])
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        guard (try? handler.perform([request])) != nil,
              let buffer = (request.results as [VNPixelBufferObservation]?)?.first?.pixelBuffer
        else { return nil }

        // 사람이 없으면 전부 0 이 나온다 — 그럴 땐 쓰지 않는다
        guard Processor.hasContent(buffer) else { return nil }

        var matte = CIImage(cvPixelBuffer: buffer)
        // 원본 비율에 맞춰 늘린다
        let sx = source.extent.width / max(matte.extent.width, 1)
        let sy = source.extent.height / max(matte.extent.height, 1)
        matte = matte.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if let data = context.jpegRepresentation(of: matte,
                                                 colorSpace: CGColorSpaceCreateDeviceGray(),
                                                 options: [:]) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return matte
    }

    /// 매트가 전부 검정인지 (= 사람 없음) 빠르게 확인
    nonisolated static func hasContent(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var lit = 0
        let step = max(min(w, h) / 48, 1)
        for y in stride(from: 0, to: h, by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: step) where row[x] > 140 { lit += 1 }
        }
        return lit > 12
    }

    /// ISO 에 따른 자동 노이즈 제거 하한. 사용자가 더 높게 잡으면 그 값을 쓴다.
    nonisolated static func autoNoise(iso: Float) -> Float {
        guard iso > 0 else { return 0.08 }
        let stops = log2(max(iso, 50) / 100)          // ISO100 기준 스톱 수
        return min(max(0.05 + stops * 0.085, 0.05), 0.62)
    }

    // MARK: - 디코드

    /// ProRAW DNG 를 '보정 전 선형' 상태로 디코드한다.
    /// 애플 기본 보정(부스트/톤맵/샤프닝/NR)을 전부 끄는 게 핵심 —
    /// 그래야 우리 파이프라인이 처음부터 제대로 현상할 수 있다.
    nonisolated func decode(url: URL, scale: Float) throws -> CIImage {
        if let filter = CIRAWFilter(imageURL: url) {
            filter.boostAmount = 0                    // 애플 톤 커브 off
            filter.boostShadowAmount = 0
            filter.localToneMapAmount = 0             // 로컬 톤맵 off (우리가 한다)
            filter.contrastAmount = 0
            filter.sharpnessAmount = 0                // 샤프닝 off
            filter.detailAmount = 0
            filter.luminanceNoiseReductionAmount = 0  // NR 도 우리가
            filter.colorNoiseReductionAmount = 0
            filter.extendedDynamicRangeAmount = 1.0   // 1.0 위 하이라이트 보존 (보케 블룸에 필수)
            filter.isGamutMappingEnabled = false
            if scale < 0.999 {
                filter.scaleFactor = max(scale, 0.05)
                filter.isDraftModeEnabled = scale <= 0.3
            }
            if let output = filter.outputImage { return output }
        }
        // ProRAW 가 아닌 경우 (HEIC 폴백) — 감마를 풀어 선형으로
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw RenderError.decode(url.lastPathComponent)
        }
        if let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            return image.matchedToWorkingSpace(from: linearSpace) ?? image
        }
        return image
    }

    /// 현상에 필요한 입력 일체를 준비
    nonisolated func makeInput(shot: Shot, rawURL: URL, depth: DepthMap?, matteImage: CIImage?,
                               targetLongSide: Int) throws -> Renderer.Input {
        let fullLong = max(shot.pixelWidth, shot.pixelHeight)
        let scale = fullLong > 0 ? min(Float(targetLongSide) / Float(fullLong), 1) : 1
        let image = try decode(url: rawURL, scale: scale)

        let extent = image.extent
        var width = Int(extent.width.rounded())
        var height = Int(extent.height.rounded())
        if width <= 0 || height <= 0 { throw RenderError.decode("빈 이미지") }
        // 지나치게 큰 경우 한 번 더 줄임
        let long = max(width, height)
        if long > targetLongSide {
            let k = Double(targetLongSide) / Double(long)
            width = Int((Double(width) * k).rounded())
            height = Int((Double(height) * k).rounded())
        }

        guard let linear = renderer?.linearTexture(image, width: width, height: height) else {
            throw RenderError.allocation
        }
        var depthTexture: MTLTexture?
        if let depth { depthTexture = renderer?.depthTexture(depth) }
        var matteTexture: MTLTexture?
        if let matteImage {
            // 매트는 보케 작업 해상도 정도면 충분하다 (uv 로 샘플링하므로 크기 자유)
            let long = max(width, height)
            let k = min(Double(Renderer.bokehLongSide) / Double(max(long, 1)), 1)
            let mw = max(Int(Double(width) * k), 64), mh = max(Int(Double(height) * k), 64)
            matteTexture = renderer?.grayTexture(matteImage, width: mw, height: mh)
        }
        var focus = shot.focusDistance
        if focus <= 0.02, let depth { focus = depth.centerDistance() }
        if focus <= 0.02 { focus = 2.0 }

        var input = Renderer.Input(linear: linear, depth: depthTexture, matte: matteTexture,
                                   focusDistance: focus)
        // 장면 분석 — 사진마다 노출·블랙·화이트를 따로 잡는다
        input.auto = renderer?.analyze(linear) ?? .neutral
        input.autoNR = Processor.autoNoise(iso: shot.iso)
        return input
    }

    /// 현상에 쓸 입력 한 벌 (매트 생성 포함). work 큐에서만 부른다.
    nonisolated private func prepare(shot: Shot, paths: Paths, targetLongSide: Int,
                                     needsMatte: Bool) throws -> Renderer.Input {
        let depth = paths.depth.flatMap { try? Data(contentsOf: $0) }.flatMap(DepthMap.decode)
        var matte: CIImage?
        if needsMatte, depth != nil, let preview = paths.preview {
            matte = Processor.personMatte(previewURL: preview, cacheURL: paths.matteCache)
        }
        return try makeInput(shot: shot, rawURL: paths.raw, depth: depth,
                             matteImage: matte, targetLongSide: targetLongSide)
    }

    /// MainActor 에서 미리 뽑아 두는 경로 묶음 (work 큐는 ShotStore 를 못 만진다)
    struct Paths: Sendable {
        var raw: URL
        var preview: URL?
        var depth: URL?
        var matteCache: URL
        var folder: URL
    }

    func paths(for shot: Shot, useExportAsSource: Bool = false) -> Paths? {
        let store = ShotStore.shared
        let source = store.rawURL(shot) ?? (useExportAsSource ? store.exportURL(shot) : nil)
        guard let source else { return nil }
        return Paths(raw: source,
                     preview: store.previewURL(shot),
                     depth: store.url(shot, shot.depthFile),
                     matteCache: store.folder(shot).appendingPathComponent("matte.jpg"),
                     folder: store.folder(shot))
    }

    // MARK: - 미리보기 (편집 화면용, 즉시)

    func preview(shot: Shot, settings: DevelopSettings, longSide: Int = 2000) async -> CGImage? {
        guard let renderer, let paths = paths(for: shot, useExportAsSource: true) else { return nil }
        let key = "\(shot.id.uuidString)-\(longSide)"
        let wantsMatte = settings.bokehEnabled
        return await withCheckedContinuation { continuation in
            work.async {
                do {
                    var input = self.cache.lookup(key)
                    if input == nil || (wantsMatte && input?.matte == nil) {
                        input = try self.prepare(shot: shot, paths: paths,
                                                 targetLongSide: longSide, needsMatte: wantsMatte)
                        self.cache.store(key, input!)
                    }
                    let result = try renderer.develop(input!, settings)
                    continuation.resume(returning: renderer.cgImage(from: result))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 백그라운드 현상 큐

    func enqueue(_ shot: Shot) {
        guard jobs[shot.id]?.isActive != true else { return }
        jobs[shot.id] = .queued
        pending.append(shot.id)
        queueCount = pending.count
        runNext()
    }

    func cancelAll() {
        pending.removeAll()
        queueCount = 0
        for (key, value) in jobs where value == .queued {
            jobs[key] = nil
        }
    }

    private func runNext() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        let id = pending.removeFirst()
        queueCount = pending.count
        Task {
            await export(id)
            self.isRunning = false
            self.runNext()
        }
    }

    private func export(_ id: UUID) async {
        let store = ShotStore.shared
        guard let shot = store.shots.first(where: { $0.id == id }) else {
            jobs[id] = nil
            return
        }
        guard let renderer else {
            jobs[id] = .failed("GPU를 쓸 수 없어요")
            return
        }
        guard store.rawURL(shot) != nil, let paths = paths(for: shot) else {
            jobs[id] = .failed("원본이 없어요")
            return
        }

        jobs[id] = .running(stage: "RAW 디코드", progress: 0.05)
        let settings = shot.develop
        let target = exportSize.longSide
        let quality = store.jpegQuality
        let folder = paths.folder

        let result: Result<(String, Int, Int), Error> = await withCheckedContinuation { continuation in
            work.async {
                do {
                    let input = try self.prepare(shot: shot, paths: paths, targetLongSide: target,
                                                 needsMatte: settings.bokehEnabled)
                    Task { @MainActor in
                        self.jobs[id] = .running(stage: settings.bokehEnabled ? "보케 계산" : "현상",
                                                 progress: 0.35)
                    }
                    let texture = try renderer.develop(input, settings)
                    Task { @MainActor in
                        self.jobs[id] = .running(stage: "저장", progress: 0.85)
                    }
                    guard let data = renderer.jpegData(from: texture, quality: CGFloat(quality)) else {
                        throw RenderError.decode("JPEG 인코딩 실패")
                    }
                    let name = "export.jpg"
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    continuation.resume(returning: .success((name, texture.width, texture.height)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch result {
        case .success(let (name, _, _)):
            store.markExported(id, file: name)
            jobs[id] = .done
            if store.saveToPhotos, let url = store.exportURL(shot) {
                await saveToPhotos(url)
            }
        case .failure(let error):
            jobs[id] = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    // MARK: - 사진 앱 저장

    func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    func state(_ id: UUID) -> JobState? { jobs[id] }
}
