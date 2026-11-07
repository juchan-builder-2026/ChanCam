import CoreImage
import Foundation
import Metal
import Photos
import SwiftUI
import UIKit

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
    private let work = DispatchQueue(label: "com.chan.cam.develop", qos: .utility)
    private var pending: [UUID] = []
    private var isRunning = false

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
            let mw = max(width / Renderer.bokehDownscale, 32)
            let mh = max(height / Renderer.bokehDownscale, 32)
            matteTexture = renderer?.grayTexture(matteImage, width: mw, height: mh)
        }
        var focus = shot.focusDistance
        if focus <= 0.02, let depth { focus = depth.centerDistance() }
        if focus <= 0.02 { focus = 2.0 }

        return Renderer.Input(linear: linear, depth: depthTexture, matte: matteTexture,
                              focusDistance: focus)
    }

    // MARK: - 미리보기 (편집 화면용, 즉시)

    func preview(shot: Shot, settings: DevelopSettings, longSide: Int = 2200) async -> CGImage? {
        guard let renderer else { return nil }
        let store = ShotStore.shared
        guard let rawURL = store.rawURL(shot) ?? store.exportURL(shot) else { return nil }
        let depth = store.depthMap(shot)
        let matte = store.matteImage(shot)
        return await withCheckedContinuation { continuation in
            work.async {
                do {
                    let input = try self.makeInput(shot: shot, rawURL: rawURL, depth: depth,
                                                   matteImage: matte, targetLongSide: longSide)
                    let result = try renderer.develop(input, settings)
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
        guard let rawURL = store.rawURL(shot) else {
            jobs[id] = .failed("원본이 없어요")
            return
        }

        jobs[id] = .running(stage: "RAW 디코드", progress: 0.05)
        let depth = store.depthMap(shot)
        let matte = store.matteImage(shot)
        let settings = shot.develop
        let target = exportSize.longSide
        let quality = store.jpegQuality
        let folder = store.folder(shot)

        let result: Result<(String, Int, Int), Error> = await withCheckedContinuation { continuation in
            work.async {
                do {
                    let input = try self.makeInput(shot: shot, rawURL: rawURL, depth: depth,
                                                   matteImage: matte, targetLongSide: target)
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
