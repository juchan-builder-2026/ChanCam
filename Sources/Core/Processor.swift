import CoreImage
import Foundation
import Metal
import Photos
import QuartzCore
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

/// 취소 플래그 — 메인에서 올리고 작업 큐에서 읽는다
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func raise() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

/// 단계별 실제 소요 시간 — 어디서 시간이 갔는지 끝나고 보여준다
struct StageTime: Equatable, Identifiable {
    var name: String
    var seconds: Double
    var id: String { name }
}

/// 현상 한 번(한 장 또는 여러 장)의 진행 상태
struct BatchProgress: Equatable {
    var stageTimes: [StageTime] = []
    var total = 0
    var finished = 0
    var failed = 0
    var stage = "준비"
    /// 지금 장의 진행률 0...1
    var fraction: Double = 0
    var startedAt = Date()
    var endedAt: Date?
    var isRunning = true
    var cancelled = false
    var currentName = ""
    /// 끝난 장들의 실제 소요 시간 (남은 시간 추정용)
    var completedSeconds: [Double] = []

    var overall: Double {
        guard total > 0 else { return 0 }
        return min((Double(finished) + fraction) / Double(total), 1)
    }

    var elapsed: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// 남은 시간 — 실제로 끝난 장들의 평균으로 추정한다 (추측이 아니라 실측 기반)
    var remaining: TimeInterval? {
        guard isRunning, total > 0 else { return nil }
        let done = Double(finished) + fraction
        guard done > 0.08 else { return nil }
        let perUnit = elapsed / done
        return max(perUnit * (Double(total) - done), 0)
    }

    var isComplete: Bool { !isRunning && !cancelled }
}

/// RAW 디코드 + 현상 실행기.
///
/// v1.2 부터 현상은 **자동으로 돌지 않는다**. 사용자가 현상 화면에서 품질과 옵션을
/// 고르고 시작을 누를 때만 돈다. 진행률은 가짜 애니메이션이 아니라 단계마다
/// 실제로 끊어 쏘는 GPU 명령 버퍼의 완료를 세어서 올린다.
@MainActor
final class Processor: ObservableObject {
    static let shared = Processor()

    @Published private(set) var jobs: [UUID: JobState] = [:]
    @Published private(set) var batch: BatchProgress?
    @Published var lastError: String?

    /// 현상 지시서 — UserDefaults 에 JSON 으로 저장된다
    @Published var recipe: DevelopRecipe {
        didSet { saveRecipe() }
    }

    /// 벤치마크로 실측한 GPU 점수 (탭/초). 예상 시간 계산에 쓴다.
    @AppStorage("gpuScore") var gpuScore: Double = 0

    var exportSize: ExportSize {
        get { ExportSize(rawValue: recipe.outputSize) ?? .mp24 }
        set { recipe.outputSize = newValue.rawValue }
    }

    private let renderer = Renderer.shared
    private let work = DispatchQueue(label: "com.chan.cam.develop", qos: .userInitiated)
    private let flag = CancelFlag()
    private var running = false

    /// 편집 화면용 디코드 캐시. 슬라이더를 움직일 때마다 RAW 를 다시 디코드하면
    /// 1~2초씩 걸린다. 한 번 디코드해 두면 이후엔 GPU 현상만 돌아 즉각 반응한다.
    private let cache = InputCache()

    private static let recipeKey = "developRecipe"

    init() {
        if let data = UserDefaults.standard.data(forKey: Processor.recipeKey),
           let saved = try? JSONDecoder().decode(DevelopRecipe.self, from: data) {
            recipe = saved
        } else {
            recipe = .default
        }
    }

    private func saveRecipe() {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        UserDefaults.standard.set(data, forKey: Processor.recipeKey)
    }

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

    // MARK: - 피사체 분리 (Vision)

    /// 48MP ProRAW 와 사진 깊이 전달을 같이 못 쓰기 때문에 애플 인물 매트는 안 온다.
    /// 대신 현상할 때 Vision 으로 피사체를 뽑는다. iOS 17 의 전경 인스턴스 분리는
    /// 사람뿐 아니라 물체도 잡고, 머리카락 경계가 깊이맵보다 훨씬 정확하다.
    /// 결과는 파일로 캐시한다.
    nonisolated static func personMatte(previewURL: URL, cacheURL: URL) -> CIImage? {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return CIImage(contentsOf: cacheURL)
        }
        guard let source = CIImage(contentsOf: previewURL, options: [.applyOrientationProperty: true])
        else { return nil }

        let context = CIContext(options: [.cacheIntermediates: false])
        var matte: CIImage?

        // 1순위 — 전경 인스턴스 분리 (애플이 학습시킨 피사체 분리 모델)
        if #available(iOS 17.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: source, options: [:])
            if (try? handler.perform([request])) != nil,
               let observation = request.results?.first,
               !observation.allInstances.isEmpty,
               let buffer = try? observation.generateScaledMaskForImage(
                    forInstances: observation.allInstances, from: handler),
               Processor.hasContent(buffer, floatMask: true) {
                matte = CIImage(cvPixelBuffer: buffer)
            }
        }

        // 2순위 — 사람 분리
        if matte == nil {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(ciImage: source, options: [:])
            if (try? handler.perform([request])) != nil,
               let buffer = (request.results as [VNPixelBufferObservation]?)?.first?.pixelBuffer,
               Processor.hasContent(buffer, floatMask: false) {
                matte = CIImage(cvPixelBuffer: buffer)
            }
        }

        guard var result = matte else { return nil }
        // 원본 비율에 맞춰 늘린다
        let sx = source.extent.width / max(result.extent.width, 1)
        let sy = source.extent.height / max(result.extent.height, 1)
        result = result.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if let data = context.jpegRepresentation(of: result,
                                                 colorSpace: CGColorSpaceCreateDeviceGray(),
                                                 options: [:]) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return result
    }

    /// 매트가 전부 비어 있는지 (= 피사체 없음) 빠르게 확인
    nonisolated static func hasContent(_ buffer: CVPixelBuffer, floatMask: Bool) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 4, h > 4 else { return false }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isFloat = floatMask && format == kCVPixelFormatType_OneComponent32Float
        var lit = 0
        let step = max(min(w, h) / 48, 1)
        for y in stride(from: 0, to: h, by: step) {
            let row = base.advanced(by: y * rowBytes)
            if isFloat {
                let values = row.assumingMemoryBound(to: Float.self)
                for x in stride(from: 0, to: w, by: step) where values[x] > 0.55 { lit += 1 }
            } else {
                let values = row.assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: w, by: step) where values[x] > 140 { lit += 1 }
            }
        }
        return lit > 12
    }

    /// ISO 에 따른 자동 노이즈 제거 하한. 사용자가 더 높게 잡으면 그 값을 쓴다.
    nonisolated static func autoNoise(iso: Float) -> Float {
        guard iso > 0 else { return 0.08 }
        let stops = log2(max(iso, 50) / 100)          // ISO100 기준 스톱 수
        return min(max(0.05 + stops * 0.085, 0.05), 0.62)
    }

    /// 선형 장면값 기준 노이즈 바닥 추정. 신경망 블록의 셰이프 임계가 된다.
    /// 읽기 노이즈는 신호의 제곱근에 비례하므로 ISO 의 제곱근으로 올린다.
    nonisolated static func noiseFloor(iso: Float) -> Float {
        let base: Float = 0.0022
        let scale = sqrt(max(iso, 50) / 100)
        return min(max(base * scale, 0.0015), 0.06)
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
    nonisolated func makeInput(shot: Shot, settings: DevelopSettings, rawURL: URL,
                               depth: DepthMap?, matteImage: CIImage?,
                               targetLongSide: Int, bokehSide: Int,
                               analyze: Bool,
                               publish: (String, Double) -> Void = { _, _ in }) throws -> Renderer.Input {
        let fullLong = max(shot.pixelWidth, shot.pixelHeight)
        let zoom = max(min(settings.zoom, 8), 1)
        // 잘라낸 뒤의 크기가 목표 해상도가 되도록, 디코드는 확대 배율만큼 더 크게
        let scale = fullLong > 0
            ? min(Float(targetLongSide) * zoom / Float(fullLong), 1)
            : 1
        publish("decode", 0.15)
        var image = try decode(url: rawURL, scale: scale)
        publish("decode", 0.6)

        // 확대 = 크롭. 크롭한 만큼 환산 화각이 올라가서 얇은 렌즈 공식이 앞뒤가 맞는다.
        let region = settings.cropRegion
        if region.width < 0.999 || region.height < 0.999 {
            let e = image.extent
            // CIImage 는 좌하단 원점이라 y 를 뒤집어 센다
            let rect = CGRect(x: e.minX + region.origin.x * e.width,
                              y: e.minY + (1 - region.origin.y - region.height) * e.height,
                              width: region.width * e.width,
                              height: region.height * e.height)
            image = image.cropped(to: rect.integral)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                            y: -image.extent.origin.y))
        }
        publish("decode", 0.78)

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
        publish("decode", 1)
        var depthTexture: MTLTexture?
        if let depth { depthTexture = renderer?.depthTexture(depth) }
        var matteTexture: MTLTexture?
        if let matteImage {
            // 매트는 보케 작업 해상도 정도면 충분하다 (uv 로 샘플링하므로 크기 자유)
            let long = max(width, height)
            let k = min(Double(bokehSide) / Double(max(long, 1)), 1)
            let mw = max(Int(Double(width) * k), 64), mh = max(Int(Double(height) * k), 64)
            matteTexture = renderer?.grayTexture(matteImage, width: mw, height: mh)
        }
        var focus = shot.focusDistance
        if focus <= 0.02, let depth { focus = depth.centerDistance() }
        if focus <= 0.02 { focus = 2.0 }

        var input = Renderer.Input(linear: linear, depth: depthTexture, matte: matteTexture,
                                   focusDistance: focus)
        // 장면 분석 — 사진마다 노출·블랙·화이트를 따로 잡는다
        publish("analyze", 0)
        input.auto = analyze ? (renderer?.analyze(linear) ?? .neutral) : .neutral
        input.autoNR = Processor.autoNoise(iso: shot.iso)
        input.noiseFloor = Processor.noiseFloor(iso: shot.iso)
        // EXIF 가 알려준 실제 화각. 아이폰 광각은 24mm 다.
        input.capturedFocal = shot.focalLength35 > 1 ? shot.focalLength35 : 24
        publish("analyze", 1)
        return input
    }

    /// 현상에 쓸 입력 한 벌 (매트 생성 포함). work 큐에서만 부른다.
    nonisolated private func prepare(shot: Shot, settings: DevelopSettings, paths: Paths,
                                     recipe: DevelopRecipe,
                                     targetLongSide: Int, needsMatte: Bool,
                                     publish: (String, Double) -> Void = { _, _ in })
        throws -> Renderer.Input {
        let depth = paths.depth.flatMap { try? Data(contentsOf: $0) }.flatMap(DepthMap.decode)
        var matte: CIImage?
        if needsMatte, depth != nil, let preview = paths.preview {
            publish("mask", 0)
            matte = Processor.personMatte(previewURL: preview, cacheURL: paths.matteCache)
            publish("mask", 1)
        }
        return try makeInput(shot: shot, settings: settings, rawURL: paths.raw, depth: depth,
                             matteImage: matte, targetLongSide: targetLongSide,
                             bokehSide: recipe.bokehSide, analyze: recipe.sceneAnalysis,
                             publish: publish)
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

    /// 편집 화면은 반응 속도가 생명이라 샘플 수를 줄인 가벼운 지시서를 쓴다.
    /// 그림의 성격은 같고 보케 디스크만 조금 거칠다.
    private var previewRecipe: DevelopRecipe {
        var light = recipe
        if light.tier == .extreme { light.tier = .advanced }
        light.apertureSamples = min(recipe.apertureSamples, 16)
        light.marchSteps = min(recipe.marchSteps, 12)
        light.neuralScales = min(recipe.neuralScales, 2)
        return light
    }

    // MARK: - 단계 시간 기록

    private var stageStart = Date()

    private func noteStage(_ name: String) {
        guard var current = batch else { return }
        if current.stage != name {
            let elapsed = Date().timeIntervalSince(stageStart)
            if elapsed > 0.005, !current.stage.isEmpty, current.stage != "시작" {
                if let index = current.stageTimes.firstIndex(where: { $0.name == current.stage }) {
                    current.stageTimes[index].seconds += elapsed
                } else {
                    current.stageTimes.append(StageTime(name: current.stage, seconds: elapsed))
                }
            }
            stageStart = Date()
            current.stage = name
        }
        batch = current
    }

    func preview(shot: Shot, settings: DevelopSettings, longSide: Int = 2000) async -> CGImage? {
        guard let renderer, let paths = paths(for: shot, useExportAsSource: true) else { return nil }
        let light = previewRecipe
        // 확대 배율이 바뀌면 다시 디코드해야 한다 — 캐시 키에 넣는다
        let zoomKey = Int((settings.zoom * 20).rounded())
        let key = "\(shot.id.uuidString)-\(longSide)-\(zoomKey)"
        let wantsMatte = settings.bokehEnabled && light.subjectMask
        return await withCheckedContinuation { continuation in
            work.async {
                do {
                    var input = self.cache.lookup(key)
                    if input == nil || (wantsMatte && input?.matte == nil) {
                        input = try self.prepare(shot: shot, settings: settings, paths: paths,
                                                 recipe: light,
                                                 targetLongSide: longSide, needsMatte: wantsMatte)
                        self.cache.store(key, input!)
                    }
                    let result = try renderer.develop(input!, settings, recipe: light)
                    continuation.resume(returning: renderer.cgImage(from: result))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 현상 실행 (수동 시작)

    var isDeveloping: Bool { batch?.isRunning == true }

    /// 현상 화면의 '시작' 버튼이 부르는 유일한 입구.
    func start(_ shots: [Shot]) {
        guard !running, !shots.isEmpty else { return }
        guard renderer != nil else {
            lastError = "GPU를 쓸 수 없어요"
            return
        }
        flag.clear()
        running = true
        var progress = BatchProgress()
        progress.total = shots.count
        progress.stage = "시작"
        batch = progress
        stageStart = Date()
        for shot in shots { jobs[shot.id] = .queued }
        SystemMonitor.shared.reset()
        SystemMonitor.shared.start()

        Task { await runBatch(shots) }
    }

    func cancel() {
        flag.raise()
        batch?.cancelled = true
        batch?.stage = "취소 중"
    }

    /// 현상이 끝난 뒤 결과 화면을 닫을 때
    func clearBatch() {
        guard batch?.isRunning != true else { return }
        batch = nil
        SystemMonitor.shared.stop()
    }

    private func runBatch(_ shots: [Shot]) async {
        for shot in shots {
            if flag.isSet { break }
            batch?.currentName = shot.date.formatted(date: .omitted, time: .standard)
            batch?.fraction = 0
            let began = Date()
            let ok = await develop(shot)
            if flag.isSet { break }
            batch?.completedSeconds.append(Date().timeIntervalSince(began))
            batch?.finished += 1
            batch?.fraction = 0
            if !ok { batch?.failed += 1 }
        }
        noteStage(flag.isSet ? "취소됨" : "완료")
        running = false
        batch?.isRunning = false
        batch?.endedAt = Date()
        batch?.fraction = flag.isSet ? 0 : 1
        if flag.isSet {
            for (id, state) in jobs where state == .queued { jobs[id] = nil }
        }
        SystemMonitor.shared.stop()
    }

    @discardableResult
    private func develop(_ shot: Shot) async -> Bool {
        let store = ShotStore.shared
        guard let renderer else { return false }
        let current = store.shots.first(where: { $0.id == shot.id }) ?? shot
        guard store.rawURL(current) != nil, let paths = paths(for: current) else {
            jobs[shot.id] = .failed("원본이 없어요")
            return false
        }

        let id = current.id
        let settings = current.develop
        let activeRecipe = recipe
        let hasDepth = paths.depth != nil && settings.bokehEnabled
        let plan = DevelopStage.plan(activeRecipe, hasDepth: hasDepth)
        let target = activeRecipe.longSide
        let quality = activeRecipe.jpegQuality
        let folder = paths.folder
        let needsMatte = hasDepth && activeRecipe.subjectMask
        let cancelFlag = flag

        jobs[id] = .running(stage: "RAW 디코드", progress: 0.01)

        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            work.async {
                // 단계 키 → 전체 진행률. 이 지시서에 없는 단계는 보고하지 않는다
                // (모르는 키를 1.0 으로 처리하면 진행률이 튄다)
                let totalWeight = plan.reduce(0.0) { $0 + $1.weight }
                func globalFraction(_ key: String, _ local: Double) -> (String, Double)? {
                    var before = 0.0
                    for stage in plan {
                        if stage.key == key {
                            let clamped = min(max(local, 0), 1)
                            return (stage.name, (before + stage.weight * clamped) / totalWeight)
                        }
                        before += stage.weight
                    }
                    return nil
                }
                var lastPublished = CACurrentMediaTime() - 1
                func publish(_ key: String, _ local: Double) {
                    guard let (name, fraction) = globalFraction(key, local) else { return }
                    let now = CACurrentMediaTime()
                    guard local >= 1 || local <= 0 || now - lastPublished > 0.07 else { return }
                    lastPublished = now
                    Task { @MainActor in
                        self.jobs[id] = .running(stage: name, progress: fraction)
                        self.noteStage(name)
                        self.batch?.fraction = fraction
                    }
                }

                do {
                    let input = try self.prepare(shot: current, settings: settings, paths: paths,
                                                 recipe: activeRecipe,
                                                 targetLongSide: target, needsMatte: needsMatte,
                                                 publish: { key, local in publish(key, local) })
                    if cancelFlag.isSet { throw RenderError.cancelled }

                    let texture = try renderer.develop(input, settings, recipe: activeRecipe,
                                                       report: { key, local in publish(key, local) },
                                                       cancelled: { cancelFlag.isSet })
                    publish("encode", 0.1)
                    guard let data = renderer.jpegData(from: texture, quality: CGFloat(quality)) else {
                        throw RenderError.decode("JPEG 인코딩 실패")
                    }
                    let name = "export.jpg"
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    publish("encode", 1)
                    continuation.resume(returning: .success(name))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch result {
        case .success(let name):
            store.markExported(id, file: name, keepRaw: activeRecipe.keepRaw)
            jobs[id] = .done
            ThumbCache.shared.drop(id)
            if activeRecipe.saveToPhotos, let shot = store.shots.first(where: { $0.id == id }),
               let url = store.exportURL(shot) {
                await saveToPhotos(url)
            }
            return true
        case .failure(let error):
            if case RenderError.cancelled = error {
                jobs[id] = nil
            } else {
                jobs[id] = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
            return false
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

    /// 아직 현상하지 않은 사진들
    func pending(_ shots: [Shot]) -> [Shot] {
        shots.filter { $0.exportedAt == nil && ShotStore.shared.hasRaw($0) }
    }
}
