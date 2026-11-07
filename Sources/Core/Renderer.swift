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
    var pad0: Float = 0
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

    /// 보케는 1/4 해상도에서 계산한다. 흐린 영역이라 해상도가 필요 없고,
    /// 같은 샘플 수로 4배 넓은 반경을 감당할 수 있다.
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

    private func run(_ name: String, _ command: MTLCommandBuffer,
                     textures: [MTLTexture?], bytes: [(UnsafeRawPointer, Int)] = [],
                     size: (Int, Int)) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw RenderError.encoder }
        let state = try pipeline(name)
        encoder.setComputePipelineState(state)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        for (index, item) in bytes.enumerated() {
            encoder.setBytes(item.0, length: item.1, index: index)
        }
        dispatch(encoder, state, size.0, size.1)
        encoder.endEncoding()
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

        var detailParams = DetailParams(
            sharpness: settings.sharpness / 100,
            radius: settings.sharpenRadius,
            texture: settings.texture / 100,
            clarity: settings.clarity / 100,
            lumaNR: settings.luminanceNR / 100,
            colorNR: settings.colorNR / 100)

        // 1) 노이즈 제거 (선형) — 원본은 건드리지 않는다
        try run("denoise", command, textures: [input.linear, front],
                bytes: [(&detailParams, MemoryLayout<DetailParams>.stride)], size: (width, height))

        // 2) 보케 — 선형 HDR, 1/4 해상도에서 계산 후 풀해상도로 합성
        if settings.bokehEnabled, let depth = input.depth {
            if try applyBokeh(command, source: front, destination: back, depth: depth,
                              matte: input.matte, settings: settings,
                              focusDistance: input.focusDistance) {
                swap(&front, &back)
            }
        }

        // 3) 로컬 톤 마스크 (1/8 해상도 휘도 블러)
        let maskRatio = 8
        let maskW = max(width / maskRatio, 32), maskH = max(height / maskRatio, 32)
        guard let maskA = texture(maskW, maskH, format: .r16Float),
              let maskB = texture(maskW, maskH, format: .r16Float) else { throw RenderError.allocation }
        var ratio = Float(maskRatio)
        try run("luma_downsample", command, textures: [front, maskA],
                bytes: [(&ratio, MemoryLayout<Float>.stride)], size: (maskW, maskH))
        var maskRadius = Float(max(3, min(maskW, maskH) / 12))
        try run("luma_blur_h", command, textures: [maskA, maskB],
                bytes: [(&maskRadius, MemoryLayout<Float>.stride)], size: (maskW, maskH))
        try run("luma_blur_v", command, textures: [maskB, maskA],
                bytes: [(&maskRadius, MemoryLayout<Float>.stride)], size: (maskW, maskH))

        // 4) 톤 + 컬러 → 디스플레이 공간
        let wb = Renderer.whiteBalanceGain(settings.temperature, settings.tint, input.asShotNeutral)
        var toneParams = ToneParams(
            exposure: settings.exposure,
            contrast: settings.contrast / 100,
            highlights: settings.highlights / 100,
            shadows: settings.shadows / 100,
            whites: settings.whites / 100,
            blacks: settings.blacks / 100,
            vibrance: settings.vibrance / 100,
            saturation: settings.saturation / 100,
            tempScaleR: wb.x, tempScaleG: wb.y, tempScaleB: wb.z)
        try run("tone_color", command, textures: [front, maskA, back],
                bytes: [(&toneParams, MemoryLayout<ToneParams>.stride)], size: (width, height))
        swap(&front, &back)

        // 5) 디테일 (클래리티용 대반경 휘도 블러도 1/8 에서)
        guard let clarityA = texture(maskW, maskH, format: .r16Float),
              let clarityB = texture(maskW, maskH, format: .r16Float) else { throw RenderError.allocation }
        try run("luma_downsample", command, textures: [front, clarityA],
                bytes: [(&ratio, MemoryLayout<Float>.stride)], size: (maskW, maskH))
        var clarityRadius = Float(max(4, min(maskW, maskH) / 8))
        try run("luma_blur_h", command, textures: [clarityA, clarityB],
                bytes: [(&clarityRadius, MemoryLayout<Float>.stride)], size: (maskW, maskH))
        try run("luma_blur_v", command, textures: [clarityB, clarityA],
                bytes: [(&clarityRadius, MemoryLayout<Float>.stride)], size: (maskW, maskH))
        try run("detail", command, textures: [front, clarityA, back],
                bytes: [(&detailParams, MemoryLayout<DetailParams>.stride)], size: (width, height))
        swap(&front, &back)

        // 6) 마무리
        var finishParams = FinishParams(
            vignette: settings.vignette / 100,
            grain: settings.grain / 100,
            grainSize: settings.grainSize,
            chroma: settings.chromaticAberration / 100,
            seed: 7)
        try run("finish", command, textures: [front, back],
                bytes: [(&finishParams, MemoryLayout<FinishParams>.stride)], size: (width, height))

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

        let scale = Renderer.bokehDownscale
        let smallW = max(width / scale, 32), smallH = max(height / scale, 32)

        // 1/4 해상도 작업본
        guard let smallSrc = texture(smallW, smallH),
              let smallOut = texture(smallW, smallH),
              let depthHi = texture(smallW, smallH, format: .r32Float),
              let cocRaw = texture(smallW, smallH, format: .r16Float),
              let cocSmooth = texture(smallW, smallH, format: .r16Float) else {
            throw RenderError.allocation
        }
        var ratio = Float(scale)
        try run("downsample_box", command, textures: [source, smallSrc],
                bytes: [(&ratio, MemoryLayout<Float>.stride)], size: (smallW, smallH))

        // 깊이를 색상 가이드로 업샘플 (LiDAR 해상도 → 1/4 해상도)
        var sigmaColor: Float = 0.12
        try run("depth_upsample", command, textures: [smallSrc, depth, depthHi],
                bytes: [(&sigmaColor, MemoryLayout<Float>.stride)], size: (smallW, smallH))

        var depthFinal = depthHi
        if let matte {
            guard let refined = texture(smallW, smallH, format: .r32Float) else { throw RenderError.allocation }
            var subject = focus
            try run("depth_refine_matte", command, textures: [depthHi, matte, refined],
                    bytes: [(&subject, MemoryLayout<Float>.stride)], size: (smallW, smallH))
            depthFinal = refined
        }

        // 착란원 — 1/4 해상도 픽셀 단위로 바로 계산
        var cocParams = CoCParams(
            focusDistance: focus,
            focalLength: settings.focalLength,
            fNumber: settings.fNumber,
            sensorWidth: 36,
            imageWidth: Float(smallW),
            maxCoC: 110)
        try run("coc_from_depth", command, textures: [depthFinal, cocRaw],
                bytes: [(&cocParams, MemoryLayout<CoCParams>.stride)], size: (smallW, smallH))
        try run("coc_smooth", command, textures: [cocRaw, cocSmooth], size: (smallW, smallH))

        let maxRadius = min(Renderer.maxCoCPixels(settings: settings, focus: focus,
                                                  imageWidth: Float(smallW)), 110)
        guard maxRadius >= 1 else { return false }

        var bokehParams = BokehParams(
            maxRadius: maxRadius,
            rings: Float(maxRadius > 40 ? 12 : (maxRadius > 16 ? 9 : 6)),
            blades: Float(settings.apertureBlades),
            curvature: settings.bladeCurvature,
            bloom: settings.highlightBloom,
            catsEye: settings.catsEye,
            ring: settings.bokehRing,
            rotation: 0.21)
        try run("bokeh_gather", command, textures: [smallSrc, cocSmooth, smallOut],
                bytes: [(&bokehParams, MemoryLayout<BokehParams>.stride)], size: (smallW, smallH))

        // 풀해상도 합성 — CoC 는 1/4 텍스처를 정규화 좌표로 샘플링하므로 그대로 쓴다.
        // 다만 블러/선명 판정은 풀해상도 픽셀 기준이어야 하니 스케일을 맞춘 사본을 쓴다.
        guard let cocForComposite = texture(smallW, smallH, format: .r16Float) else {
            throw RenderError.allocation
        }
        var upScale = Float(scale)
        try run("downsample_coc", command, textures: [cocSmooth, cocForComposite],
                bytes: [(&upScale, MemoryLayout<Float>.stride)], size: (smallW, smallH))
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

    func cgImage(from texture: MTLTexture) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard var image = CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
        ]) else { return nil }
        // Metal 텍스처는 위아래가 뒤집혀 있다
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    func jpegData(from texture: MTLTexture, quality: CGFloat = 0.95) -> Data? {
        guard var image = CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
        ]) else { return nil }
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.jpegRepresentation(of: image, colorSpace: space,
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
