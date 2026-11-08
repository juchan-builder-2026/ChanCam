import CoreImage
import Foundation
import Metal
import MetalKit
import simd

// Metal 쪽 구조체와 메모리 배치가 같아야 한다 (전부 Float)
struct ToneParams {
    var exposure: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var vibrance: Float = 0
    var saturation: Float = 0
    var tempScaleR: Float = 1
    var tempScaleG: Float = 1
    var tempScaleB: Float = 1
    var wbLuma: Float = 1
    var white: Float = 1.6
    var blackPoint: Float = 0
    var detailGain: Float = 1
    var pad0: Float = 0
}

struct BlurParams {
    var radius: Float = 4
    var sigmaStops: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
}

/// 장면 분석 결과. 고정된 프리셋 숫자만으로는 못 하는 일을 여기서 한다 —
/// 노출을 맞추고, 뿌연 플레어를 걷어내고, 하이라이트를 어디서 눕힐지 정한다.
struct AutoTone: Equatable {
    /// 로그2 휘도 평균 (장면 키)
    var logAverage: Float = -2.47
    /// 0.3 퍼센타일 선형 휘도 — 진짜 검정이 어디인지
    var blackRaw: Float = 0
    /// 99.8 퍼센타일 선형 휘도 — 장면의 최대 밝기
    var whiteRaw: Float = 1
    /// 장면 다이내믹 레인지 (스톱)
    var dynamicRange: Float = 8

    /// 자동 노출 보정 (EV). 과하게 밀지 않도록 0.7 배 감쇠 + 클램프
    var autoExposure: Float {
        let key = log2(Float(0.18)) - logAverage
        return min(max(key * 0.7, -1.3), 2.0)
    }

    static let neutral = AutoTone()
}

struct DetailParams {
    var sharpness: Float = 0
    var radius: Float = 1
    var texture: Float = 0
    var clarity: Float = 0
    var lumaNR: Float = 0
    var colorNR: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
}

struct BokehParams {
    var maxRadius: Float = 0
    var rings: Float = 8
    var blades: Float = 7
    var curvature: Float = 0.75
    var bloom: Float = 1
    var catsEye: Float = 0.6
    var ring: Float = 0.15
    var rotation: Float = 0
}

struct CoCParams {
    var focusDistance: Float = 2
    var focalLength: Float = 50
    var fNumber: Float = 1.8
    var sensorWidth: Float = 36
    var imageWidth: Float = 4032
    var maxCoC: Float = 120
    var pad0: Float = 0
    var pad1: Float = 0
}

struct FinishParams {
    var vignette: Float = 0
    var grain: Float = 0
    var grainSize: Float = 1
    var chroma: Float = 0
    var seed: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// 현상 파이프라인 실행기. 모든 무거운 연산은 GPU(Metal)에서 한다.
final class Renderer {
    static let shared = Renderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let ciContext: CIContext

    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    /// 보케 계산 해상도 (긴 변). 출력 크기와 무관하게 고정해서
    /// 48MP 라고 시간이 폭발하지 않게 하고, 미리보기와 결과를 일치시킨다.
    static let bokehLongSide = 1200
    /// 매트·마스크용 축소 비율
    static let bokehDownscale = 4

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ])
    }

    // MARK: - 파이프라인

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = pipelines[name] { return existing }
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: name) else {
            throw RenderError.missingKernel(name)
        }
        let state = try device.makeComputePipelineState(function: function)
        pipelines[name] = state
        return state
    }

    func texture(_ width: Int, _ height: Int, format: MTLPixelFormat = .rgba16Float,
                 shared: Bool = false) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: desc)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState,
                          _ width: Int, _ height: Int) {
        encoder.setComputePipelineState(state)
        let w = min(state.threadExecutionWidth, 16)
        let h = min(max(state.maxTotalThreadsPerThreadgroup / w, 1), 16)
        let group = MTLSize(width: w, height: h, depth: 1)
        let count = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(count, threadsPerThreadgroup: group)
    }

    private func encoder(_ name: String, _ command: MTLCommandBuffer,
                         _ textures: [MTLTexture?]) throws -> (MTLComputeCommandEncoder, MTLComputePipelineState) {
        guard let encoder = command.makeComputeCommandEncoder() else { throw RenderError.encoder }
        let state = try pipeline(name)
        encoder.setComputePipelineState(state)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        return (encoder, state)
    }

    private func run(_ name: String, _ command: MTLCommandBuffer,
                     textures: [MTLTexture?], size: (Int, Int)) throws {
        let (enc, state) = try encoder(name, command, textures)
        dispatch(enc, state, size.0, size.1)
        enc.endEncoding()
    }

    private func run<P>(_ name: String, _ command: MTLCommandBuffer,
                        textures: [MTLTexture?], params: P, size: (Int, Int)) throws {
        let (enc, state) = try encoder(name, command, textures)
        var value = params
        enc.setBytes(&value, length: MemoryLayout<P>.stride, index: 0)
        dispatch(enc, state, size.0, size.1)
        enc.endEncoding()
    }

    // MARK: - 입력 준비

    /// 깊이맵(미터)을 R32Float 텍스처로
    func depthTexture(_ map: DepthMap) -> MTLTexture? {
        guard let texture = texture(map.width, map.height, format: .r32Float, shared: true) else { return nil }
        map.values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, map.width, map.height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: map.width * 4)
        }
        return texture
    }

    func grayTexture(_ image: CIImage, width: Int, height: Int) -> MTLTexture? {
        guard let target = texture(width, height, format: .r16Float) else { return nil }
        guard let command = queue.makeCommandBuffer() else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / image.extent.width,
            y: CGFloat(height) / image.extent.height))
        ciContext.render(scaled, to: target, commandBuffer: command,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpaceCreateDeviceGray())
        command.commit()
        command.waitUntilCompleted()
        return target
    }

    /// CIImage(선형) → RGBA16Float 텍스처
    func linearTexture(_ image: CIImage, width: Int, height: Int) -> MTLTexture? {
        guard let target = texture(width, height) else { return nil }
        guard let command = queue.makeCommandBuffer() else { return nil }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()
        var source = image
        let extent = image.extent
        if extent.width > 0, Int(extent.width.rounded()) != width || Int(extent.height.rounded()) != height {
            source = image.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        }
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.origin.x,
                                                          y: -source.extent.origin.y))
        ciContext.render(source, to: target, commandBuffer: command,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: space)
        command.commit()
        command.waitUntilCompleted()
        return target
    }

    // MARK: - 현상

    struct Input {
        var linear: MTLTexture                 // 선형 장면 참조 RGB
        var depth: MTLTexture?                 // LiDAR 깊이 (저해상, 미터)
        var matte: MTLTexture?                 // 인물 매트 (0~1)
        var focusDistance: Float               // m
        var asShotNeutral: SIMD3<Float> = SIMD3(1, 1, 1)
        var auto: AutoTone = .neutral
        /// ISO 기반 자동 노이즈 제거 하한 (0~1)
        var autoNR: Float = 0
    }

    // MARK: - 장면 분석

    /// 선형 이미지를 작게 줄여 CPU 로 읽고 로그 휘도 분포를 낸다.
    /// 이게 "기본 사진 앱보다 잘 나오게"의 핵심 — 사진마다 커브가 달라진다.
    func analyze(_ source: MTLTexture) -> AutoTone {
        let long = max(source.width, source.height)
        guard long > 0 else { return .neutral }
        let scale = min(192, long)
        let w = max(Int(Double(source.width) / Double(long) * Double(scale)), 8)
        let h = max(Int(Double(source.height) / Double(long) * Double(scale)), 8)
        guard let small = texture(w, h, format: .r32Float, shared: true),
              let command = queue.makeCommandBuffer() else { return .neutral }
        do {
            try run("analyze_luma", command, textures: [source, small], size: (w, h))
        } catch {
            return .neutral
        }
        command.commit()
        command.waitUntilCompleted()

        var values = [Float](repeating: 0, count: w * h)
        values.withUnsafeMutableBytes { buffer in
            small.getBytes(buffer.baseAddress!, bytesPerRow: w * 4,
                           from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        values = values.filter { $0.isFinite }
        guard values.count > 16 else { return .neutral }
        values.sort()

        func percentile(_ p: Double) -> Float {
            let index = Int((Double(values.count - 1) * p).rounded())
            return values[min(max(index, 0), values.count - 1)]
        }
        // 극단값 제거 후 평균 (죽은 픽셀·센서 핫픽셀 방어)
        let lo = Int(Double(values.count) * 0.02)
        let hi = Int(Double(values.count) * 0.98)
        let trimmed = values[lo..<max(hi, lo + 1)]
        let mean = trimmed.reduce(0, +) / Float(trimmed.count)

        var auto = AutoTone()
        auto.logAverage = mean
        auto.blackRaw = exp2(percentile(0.003))
        auto.whiteRaw = exp2(percentile(0.998))
        auto.dynamicRange = percentile(0.998) - percentile(0.003)
        return auto
    }

    /// 전체 체인을 돌려 디스플레이 공간 RGBA16Float 결과를 돌려준다.
    ///
    /// 메모리 전략: 풀해상도 버퍼는 두 개만 두고 번갈아 쓴다.
    /// 깊이·보케는 1/4, 로컬 톤 마스크는 1/8 해상도에서 계산한 뒤
    /// 셰이더가 정규화 좌표로 샘플링해 자연스럽게 업샘플된다.
    /// (48MP: 풀버퍼 2개 = 780MB, 24MP: 195MB)
    func develop(_ input: Input, _ settings: DevelopSettings) throws -> MTLTexture {
        let width = input.linear.width
        let height = input.linear.height
        guard let command = queue.makeCommandBuffer() else { throw RenderError.encoder }
        guard var front = texture(width, height), var back = texture(width, height) else {
            throw RenderError.allocation
        }

        let detailParams = DetailParams(
            sharpness: settings.sharpness / 100,
            radius: settings.sharpenRadius,
            texture: settings.texture / 100,
            clarity: settings.clarity / 100,
            lumaNR: max(settings.luminanceNR / 100, input.autoNR),
            colorNR: max(settings.colorNR / 100, input.autoNR * 1.4))

        // 1) 노이즈 제거 — 휘도는 풀해상도 3x3, 색도는 1/4 해상도에서 넓게.
        //    색 노이즈는 저주파라 이쪽이 더 깨끗하면서 16배 빠르다.
        let chW = max(width / 4, 24), chH = max(height / 4, 24)
        guard let chromaSmall = texture(chW, chH), let chromaBlur = texture(chW, chH) else {
            throw RenderError.allocation
        }
        try run("downsample_box", command, textures: [input.linear, chromaSmall],
                params: Float(4), size: (chW, chH))
        try run("chroma_blur", command, textures: [chromaSmall, chromaBlur],
                params: detailParams, size: (chW, chH))
        try run("denoise", command, textures: [input.linear, chromaBlur, front],
                params: detailParams, size: (width, height))

        // 2) 보케 — 선형 HDR, 1/4 해상도에서 계산 후 풀해상도로 합성
        if settings.bokehEnabled, let depth = input.depth {
            if try applyBokeh(command, source: front, destination: back, depth: depth,
                              matte: input.matte, settings: settings,
                              focusDistance: input.focusDistance) {
                swap(&front, &back)
            }
        }

        // 3) 로컬 톤 베이스 — 1/8 해상도 로그 휘도 + 바이래터럴 블러.
        //    로그 공간 + 경계 보존이라서 섀도우를 크게 올려도 할로가 안 생긴다.
        let maskRatio = 8
        let maskW = max(width / maskRatio, 32), maskH = max(height / maskRatio, 32)
        guard let maskA = texture(maskW, maskH, format: .r16Float),
              let maskB = texture(maskW, maskH, format: .r16Float) else { throw RenderError.allocation }
        let ratio = Float(maskRatio)
        try run("log_downsample", command, textures: [front, maskA],
                params: ratio, size: (maskW, maskH))
        let maskBlur = BlurParams(radius: Float(max(4, min(maskW, maskH) / 10)), sigmaStops: 0.6)
        try run("luma_blur_h", command, textures: [maskA, maskB],
                params: maskBlur, size: (maskW, maskH))
        try run("luma_blur_v", command, textures: [maskB, maskA],
                params: maskBlur, size: (maskW, maskH))

        // 4) 톤 + 컬러 → 디스플레이 공간 (감마 인코딩은 여기서 딱 한 번)
        let wb = Renderer.whiteBalanceGain(settings.temperature, settings.tint, input.asShotNeutral)
        let wbLuma = max(0.2126 * wb.x + 0.7152 * wb.y + 0.0722 * wb.z, 1e-3)
        let auto = input.auto
        let totalGain = exp2(settings.exposure + auto.autoExposure) * wbLuma

        // 블랙 포인트: 장면의 가장 어두운 곳을 진짜 검정으로. 베일링 플레어 제거.
        let blackPoint = min(max(auto.blackRaw * totalGain * 0.85, 0), 0.055)
        let invBlack = 1 / max(1 - blackPoint, 1e-3)
        // 화이트: 장면의 실제 최대 휘도를 숄더가 1.0 으로 눕힌다
        var white = (auto.whiteRaw * totalGain - blackPoint) * invBlack
        white *= exp2(-settings.whites / 100 * 0.8)
        white = min(max(white, 1.02), 10)
        // 많이 압축할수록 국소 디테일을 더 살린다
        let detailGain = 1 + min(max(log2(white) / 3, 0), 1) * 0.3

        let toneParams = ToneParams(
            exposure: settings.exposure + auto.autoExposure,
            contrast: settings.contrast / 100,
            highlights: settings.highlights / 100,
            shadows: settings.shadows / 100,
            whites: settings.whites / 100,
            blacks: settings.blacks / 100,
            vibrance: settings.vibrance / 100,
            saturation: settings.saturation / 100,
            tempScaleR: wb.x, tempScaleG: wb.y, tempScaleB: wb.z,
            wbLuma: wbLuma,
            white: white,
            blackPoint: blackPoint,
            detailGain: detailGain)
        try run("tone_color", command, textures: [front, maskA, back],
                params: toneParams, size: (width, height))
        swap(&front, &back)

        // 5) 디테일 (클래리티용 대반경 휘도 블러도 1/8 에서)
        guard let clarityA = texture(maskW, maskH, format: .r16Float),
              let clarityB = texture(maskW, maskH, format: .r16Float) else { throw RenderError.allocation }
        try run("luma_downsample", command, textures: [front, clarityA],
                params: ratio, size: (maskW, maskH))
        let clarityBlur = BlurParams(radius: Float(max(4, min(maskW, maskH) / 8)), sigmaStops: 0)
        try run("luma_blur_h", command, textures: [clarityA, clarityB],
                params: clarityBlur, size: (maskW, maskH))
        try run("luma_blur_v", command, textures: [clarityB, clarityA],
                params: clarityBlur, size: (maskW, maskH))
        try run("detail", command, textures: [front, clarityA, back],
                params: detailParams, size: (width, height))
        swap(&front, &back)

        // 6) 마무리
        let finishParams = FinishParams(
            vignette: settings.vignette / 100,
            grain: settings.grain / 100,
            grainSize: settings.grainSize,
            chroma: settings.chromaticAberration / 100,
            seed: 7)
        try run("finish", command, textures: [front, back],
                params: finishParams, size: (width, height))

        command.commit()
        command.waitUntilCompleted()
        return back
    }

    // MARK: - 보케

    /// 보케를 계산해 `destination` 에 합성한다. 적용했으면 true.
    /// 깊이·CoC·게더는 전부 1/4 해상도에서 끝내고, 마지막 합성만 풀해상도다.
    @discardableResult
    private func applyBokeh(_ command: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                            depth: MTLTexture, matte: MTLTexture?, settings: DevelopSettings,
                            focusDistance: Float) throws -> Bool {
        let width = source.width, height = source.height
        let focus = settings.focusDistance > 0.02 ? settings.focusDistance : focusDistance
        guard focus > 0.02 else { return false }

        // 보케는 해상도와 무관하게 늘 같은 작업 해상도에서 계산한다.
        //  · 흐린 영역이라 해상도가 필요 없다
        //  · 미리보기와 최종 결과의 보케가 정확히 같아진다
        //  · 48MP 라고 해서 시간이 16배 들지 않는다
        let longSide = max(width, height)
        let k = min(Double(Renderer.bokehLongSide) / Double(longSide), 1)
        let smallW = max(Int((Double(width) * k).rounded()), 64)
        let smallH = max(Int((Double(height) * k).rounded()), 64)

        // 보케 작업 해상도 버퍼
        guard let smallSrc = texture(smallW, smallH),
              let smallOut = texture(smallW, smallH),
              let depthHi = texture(smallW, smallH, format: .r32Float),
              let cocRaw = texture(smallW, smallH, format: .r16Float),
              let cocSmooth = texture(smallW, smallH, format: .r16Float) else {
            throw RenderError.allocation
        }
        let ratio = Float(width) / Float(smallW)
        try run("downsample_box", command, textures: [source, smallSrc],
                params: ratio, size: (smallW, smallH))

        // 깊이를 색상 가이드로 업샘플 (LiDAR 해상도 → 1/4 해상도)
        var sigmaColor: Float = 0.12
        try run("depth_upsample", command, textures: [smallSrc, depth, depthHi],
                params: sigmaColor, size: (smallW, smallH))

        var depthFinal = depthHi
        if let matte {
            guard let refined = texture(smallW, smallH, format: .r32Float) else { throw RenderError.allocation }
            let subject = focus
            try run("depth_refine_matte", command, textures: [depthHi, matte, refined],
                    params: subject, size: (smallW, smallH))
            depthFinal = refined
        }

        // 착란원 — 1/4 해상도 픽셀 단위로 바로 계산
        let cocParams = CoCParams(
            focusDistance: focus,
            focalLength: settings.focalLength,
            fNumber: settings.fNumber,
            sensorWidth: 36,
            imageWidth: Float(smallW),
            maxCoC: 110)
        try run("coc_from_depth", command, textures: [depthFinal, cocRaw],
                params: cocParams, size: (smallW, smallH))
        try run("coc_smooth", command, textures: [cocRaw, cocSmooth], size: (smallW, smallH))

        let maxRadius = min(Renderer.maxCoCPixels(settings: settings, focus: focus,
                                                  imageWidth: Float(smallW)), 110)
        guard maxRadius >= 1 else { return false }

        let bokehParams = BokehParams(
            maxRadius: maxRadius,
            rings: Float(maxRadius > 45 ? 9 : (maxRadius > 18 ? 7 : 5)),
            blades: Float(settings.apertureBlades),
            curvature: settings.bladeCurvature,
            bloom: settings.highlightBloom,
            catsEye: settings.catsEye,
            ring: settings.bokehRing,
            rotation: 0.21)
        try run("bokeh_gather", command, textures: [smallSrc, cocSmooth, smallOut],
                params: bokehParams, size: (smallW, smallH))

        // 풀해상도 합성 — CoC 는 1/4 텍스처를 정규화 좌표로 샘플링하므로 그대로 쓴다.
        // 다만 블러/선명 판정은 풀해상도 픽셀 기준이어야 하니 스케일을 맞춘 사본을 쓴다.
        guard let cocForComposite = texture(smallW, smallH, format: .r16Float) else {
            throw RenderError.allocation
        }
        try run("downsample_coc", command, textures: [cocSmooth, cocForComposite],
                params: ratio, size: (smallW, smallH))
        try run("bokeh_composite", command, textures: [source, smallOut, cocForComposite, destination],
                size: (width, height))
        return true
    }

    /// 장면에서 나올 수 있는 최대 착란원(px). 게더 반경을 정하는 데 쓴다.
    static func maxCoCPixels(settings: DevelopSettings, focus: Float, imageWidth: Float) -> Float {
        let f = settings.focalLength
        let s1 = focus * 1000
        // 무한대 배경이 가장 크게 흐려진다
        let cocMM = (f * f / max(settings.fNumber, 0.7)) / max(s1 - f, 1)
        return min(cocMM / 36 * imageWidth, 460)
    }

    /// 켈빈/틴트 → 선형 채널 게인. temperature == 0 이면 촬영 당시 값 유지.
    static func whiteBalanceGain(_ kelvin: Float, _ tint: Float, _ asShot: SIMD3<Float>) -> SIMD3<Float> {
        guard kelvin > 1000 else {
            // 색조만 적용
            let t = tint / 150
            return SIMD3(1, 1 - t * 0.18, 1) * SIMD3(1 + t * 0.06, 1, 1 + t * 0.06)
        }
        let target = Renderer.kelvinToRGB(kelvin)
        let base = Renderer.kelvinToRGB(5500)
        var gain = SIMD3(base.x / max(target.x, 1e-3),
                         base.y / max(target.y, 1e-3),
                         base.z / max(target.z, 1e-3))
        let t = tint / 150
        gain.y *= (1 - t * 0.18)
        gain.x *= (1 + t * 0.06)
        gain.z *= (1 + t * 0.06)
        let mid = max((gain.x + gain.y + gain.z) / 3, 1e-3)
        return gain / mid
    }

    /// 흑체 복사 근사 (Tanner Helland)
    static func kelvinToRGB(_ kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 1000), 40000) / 100
        var r: Float, g: Float, b: Float
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(max(t, 1)) - 161.1195681661
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
        }
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }
        let v = SIMD3(min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255)) / 255
        // 대략적인 선형화
        return SIMD3(pow(v.x, 2.2), pow(v.y, 2.2), pow(v.z, 2.2))
    }

    // MARK: - 출력

    /// 파이프라인 결과는 **이미 sRGB 감마로 인코딩된 Display P3** 값이다.
    /// 여기서 선형이라고 태그하면 감마가 두 번 먹어 사진이 뿌옇게 뜬다. (v1.0 의 버그)
    private var outputSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func flipped(_ texture: MTLTexture) -> CIImage? {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: outputSpace]) else {
            return nil
        }
        // Metal 텍스처는 위아래가 뒤집혀 있다
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
    }

    func cgImage(from texture: MTLTexture) -> CGImage? {
        guard let image = flipped(texture) else { return nil }
        return ciContext.createCGImage(image, from: image.extent,
                                       format: .RGBA8, colorSpace: outputSpace)
    }

    func jpegData(from texture: MTLTexture, quality: CGFloat = 0.95) -> Data? {
        guard let image = flipped(texture) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: outputSpace,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}

enum RenderError: LocalizedError {
    case missingKernel(String)
    case encoder
    case allocation
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingKernel(let n): return "셰이더를 찾을 수 없어요 (\(n))"
        case .encoder: return "GPU 명령을 만들지 못했어요"
        case .allocation: return "메모리가 부족해요"
        case .decode(let m): return "RAW 디코드 실패 — \(m)"
        }
    }
}
