import CoreImage
import Foundation
import Metal
import MetalKit
import simd

// Metal(Common.h) 쪽 구조체와 메모리 배치가 같아야 한다 — 전부 Float, 순서도 동일.

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
    var localGain: Float = 1
    var dehaze: Float = 0
    var airLight: Float = 1
    var splitShadowR: Float = 0
    var splitShadowG: Float = 0
    var splitShadowB: Float = 0
    var splitHighR: Float = 0
    var splitHighG: Float = 0
    var splitHighB: Float = 0
    var splitBalance: Float = 0
    var skinProtect: Float = 1
    var toneBands: Float = 3
    var pad0: Float = 0
}

struct BlurParams {
    var radius: Float = 4
    var sigmaStops: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
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
    var scale: Float = 1
    var pad1: Float = 0
}

struct UpsampleParams {
    var sigmaColor: Float = 0.12
    var scaleX: Float = 1
    var scaleY: Float = 1
    var offsetX: Float = 0
    var offsetY: Float = 0
    var rotation: Float = 0
    var mirror: Float = 0
    var pad0: Float = 0
}

struct CompositeParams {
    var upscale: Float = 1
    var nearLimit: Float = 8
    var blades: Float = 7
    var curvature: Float = 0.75
    var rotation: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

struct DebugParams {
    var lo: Float = 0
    var hi: Float = 1
    var mode: Float = 0
    var pad0: Float = 0
}

struct FinishParams {
    var vignette: Float = 0
    var grain: Float = 0
    var grainSize: Float = 1
    var chroma: Float = 0
    var seed: Float = 0
    var coma: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

struct MarchParams {
    var maxRadius: Float = 0
    var samples: Float = 8
    var sampleOffset: Float = 0
    var totalSamples: Float = 48
    var steps: Float = 20
    var blades: Float = 7
    var curvature: Float = 0.75
    var catsEye: Float = 0.6
    var ring: Float = 0.15
    var apodization: Float = 0.18
    var caScale: Float = 0.06
    var rotation: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var pad3: Float = 0
}

struct ScatterParams {
    var width: Float = 0
    var height: Float = 0
    var maxRadius: Float = 0
    var blades: Float = 7
    var curvature: Float = 0.75
    var catsEye: Float = 0.6
    var ring: Float = 0.15
    var apodization: Float = 0.18
    var gain: Float = 1
    var rotation: Float = 0
    var threshold: Float = 1.6
    var pad0: Float = 0
}

struct LightSource {
    var u: Float = 0
    var v: Float = 0
    var intensity: Float = 0
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
    var radius: Float = 0.012
    var pad0: Float = 0
}

struct FlareParams {
    var count: Float = 0
    var ghosts: Float = 5
    var ghostStrength: Float = 0.55
    var haloStrength: Float = 0.35
    var glareStrength: Float = 0.4
    var spikeStrength: Float = 0.6
    var spikes: Float = 14
    var blades: Float = 7
    var curvature: Float = 0.75
    var rotation: Float = 0
    var aspect: Float = 0.75
    var fNumber: Float = 1.8
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var pad3: Float = 0
}

struct NeuralParams {
    var strength: Float = 0.55
    var denoise: Float = 0.5
    var threshold: Float = 0.01
    var scale: Float = 3
    var inhibition: Float = 0.6
    var edgeBoost: Float = 0.25
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

/// 현상 파이프라인 실행기. 모든 무거운 연산은 GPU(Metal)에서 한다.
///
/// 파이프라인 캐시는 락으로 지키고 나머지는 불변이라 어느 큐에서나 쓸 수 있다.
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let ciContext: CIContext

    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    /// 미리보기용 보케 계산 해상도 (긴 변)
    static let bokehLongSide = 1200
    /// 깊이·착란원 계산 해상도 상한. 깊이는 저주파라 여기서 끝내도 손해가 없고,
    /// 구멍 메우기 피라미드 메모리가 폭발하지 않는다.
    static let depthWorkingSide = 1400
    /// 레이트레이싱 한 번에 몰아 쏘는 조리개 샘플 수.
    /// 이 단위로 명령 버퍼를 끊어서 진행률이 실제로 움직인다.
    static let marchChunk = 8

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

    /// 파라미터(index 0) 뒤로 추가 버퍼를 붙이는 변형 — 원자 누산 빈용
    private func run<P>(_ name: String, _ command: MTLCommandBuffer,
                        textures: [MTLTexture?], params: P, buffers: [MTLBuffer],
                        size: (Int, Int)) throws {
        let (enc, state) = try encoder(name, command, textures)
        var value = params
        enc.setBytes(&value, length: MemoryLayout<P>.stride, index: 0)
        for (index, buffer) in buffers.enumerated() {
            enc.setBuffer(buffer, offset: 0, index: index + 1)
        }
        dispatch(enc, state, size.0, size.1)
        enc.endEncoding()
    }

    /// 명령 버퍼를 끝까지 돌리고 GPU 가 실제로 일한 시간을 기록한다.
    private func finish(_ command: MTLCommandBuffer) {
        command.commit()
        command.waitUntilCompleted()
        GPUClock.shared.add(command.gpuEndTime - command.gpuStartTime)
    }

    private func newCommand() throws -> MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw RenderError.encoder }
        return command
    }

    // MARK: - 방향 (추측하지 않고 실제로 재 본다)

    /// CoreImage 는 좌하단 원점, Metal 텍스처는 좌상단 원점이다.
    /// 두 세계를 오갈 때 세로가 뒤집히는데, 그 규칙이 OS 버전과 경로에 따라
    /// 달라서 코드로 가정하면 반드시 틀린다. (v1.0~v1.2 에서 사진이 거꾸로
    /// 나오고 깊이맵이 어긋나 보케가 엉뚱한 데 걸린 이유가 정확히 이거다.)
    ///
    /// 그래서 가정하지 않고, 앱이 시작될 때 알려진 그림을 한 번 통과시켜
    /// 어디로 나오는지 직접 읽는다. 두 가지를 따로 잰다:
    ///   · textureOriginIsBottom — 렌더한 텍스처의 0번 행이 이미지의 아래인가?
    ///     (그렇다면 깊이맵도 같은 방향으로 뒤집어 올려야 한다)
    ///   · outputNeedsFlip      — 최종 출력 경로에서 세로를 되돌려야 하는가?
    private struct Orientation {
        var textureOriginIsBottom = false
        var outputNeedsFlip = false
    }

    private var orientationCache: Orientation?
    private let orientationLock = NSLock()

    /// 0 = 자동(실측), 1 = 강제로 뒤집기, 2 = 강제로 안 뒤집기
    var outputFlipOverride = 0

    private var orientation: Orientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        if let cached = orientationCache { return cached }
        let measured = measureOrientation()
        orientationCache = measured
        return measured
    }

    var textureOriginIsBottom: Bool { orientation.textureOriginIsBottom }

    var outputNeedsFlip: Bool {
        switch outputFlipOverride {
        case 1: return true
        case 2: return false
        default: return orientation.outputNeedsFlip
        }
    }

    /// 방향 진단 결과를 사람이 읽을 수 있게 (센서 테스터에 표시)
    var orientationReport: (texture: String, output: String) {
        let o = orientation
        return (o.textureOriginIsBottom ? "0번 행 = 아래 (뒤집힘)" : "0번 행 = 위 (그대로)",
                o.outputNeedsFlip ? "되돌림 필요" : "그대로")
    }

    private func measureOrientation() -> Orientation {
        var result = Orientation()
        // 위 절반 검정 / 아래 절반 흰색. CIImage 좌표는 좌하단 원점이라
        // y가 큰 쪽(2...4)이 '위'다.
        let size: CGFloat = 4
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size / 2))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        let probe = black.composited(over: white)

        // (1) 텍스처의 0번 행 직접 읽기
        if let target = texture(4, 4, format: .rgba8Unorm, shared: true),
           let command = queue.makeCommandBuffer() {
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            ciContext.render(probe, to: target, commandBuffer: command,
                             bounds: CGRect(x: 0, y: 0, width: 4, height: 4), colorSpace: space)
            command.commit()
            command.waitUntilCompleted()
            var row = [UInt8](repeating: 0, count: 4 * 4)
            row.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: 16,
                                from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
            }
            // 0번 행이 밝으면 그 행은 '아래'(흰색)다 → 텍스처가 뒤집혀 있다
            result.textureOriginIsBottom = Int(row[0]) + Int(row[1]) + Int(row[2]) > 384
        }

        // (2) 출력 경로 왕복 — 플립 없이 돌려서 위가 검정으로 나오는지 본다
        if let target = texture(4, 4, shared: false),
           let command = queue.makeCommandBuffer() {
            let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ?? CGColorSpaceCreateDeviceRGB()
            ciContext.render(probe, to: target, commandBuffer: command,
                             bounds: CGRect(x: 0, y: 0, width: 4, height: 4), colorSpace: space)
            command.commit()
            command.waitUntilCompleted()
            if let image = makeCGImage(target, flip: false),
               let topLuma = Renderer.pixelLuma(image, x: 1, y: 1) {
                // 위가 흰색으로 나왔다 = 거꾸로 = 되돌려야 한다
                result.outputNeedsFlip = topLuma > 0.5
            }
        }
        return result
    }

    /// CGImage 의 한 픽셀을 읽는다 (좌상단 기준 좌표)
    private static func pixelLuma(_ image: CGImage, x: Int, y: Int) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let luma: Double? = bytes.withUnsafeMutableBytes { buffer -> Double? in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: info) else { return nil }
            // CGContext 는 좌하단 원점 — 위에서 y번째 행이 원점에 오도록 민다
            context.draw(image, in: CGRect(x: -CGFloat(x),
                                           y: -CGFloat(image.height - 1 - y),
                                           width: CGFloat(image.width),
                                           height: CGFloat(image.height)))
            let p = buffer.bindMemory(to: UInt8.self)
            return (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
        }
        return luma
    }

    // MARK: - 입력 준비

    /// 깊이맵(미터)을 R32Float 텍스처로.
    ///
    /// 색 이미지는 CoreImage 가 렌더하면서 세로가 뒤집힐 수 있는데, 깊이는
    /// 바이트를 그대로 올리니까 그 변환을 안 탄다. 맞춰주지 않으면 가까운 바닥이
    /// '먼 깊이'를 읽어 선명하게 남고 먼 배경이 '가까운 깊이'를 읽어 뭉개진다.
    func depthTexture(_ map: DepthMap) -> MTLTexture? {
        guard let texture = texture(map.width, map.height, format: .r32Float, shared: true) else { return nil }
        var values = map.values
        if textureOriginIsBottom {
            var flipped = [Float](repeating: 0, count: values.count)
            for y in 0..<map.height {
                let source = (map.height - 1 - y) * map.width
                let target = y * map.width
                for x in 0..<map.width { flipped[target + x] = values[source + x] }
            }
            values = flipped
        }
        values.withUnsafeBytes { raw in
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
        finish(command)
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
        finish(command)
        return target
    }

    // MARK: - 현상 입력

    struct Input {
        var linear: MTLTexture                 // 선형 장면 참조 RGB
        var depth: MTLTexture?                 // LiDAR 깊이 (저해상, 미터)
        var matte: MTLTexture?                 // 피사체 매트 (0~1)
        var focusDistance: Float               // m
        var asShotNeutral: SIMD3<Float> = SIMD3(1, 1, 1)
        var auto: AutoTone = .neutral
        /// ISO 기반 자동 노이즈 제거 하한 (0~1)
        var autoNR: Float = 0
        /// ISO 기반 노이즈 레벨 추정 (신경망 셰이프 임계)
        var noiseFloor: Float = 0.01
        /// CPU 쪽 깊이맵 원본. 초점 지점을 바꿀 때 RAW 를 다시 디코드하지 않고
        /// 거리만 다시 재려고 들고 있는다.
        var depthMap: DepthMap?
        /// EXIF 가 알려준 35mm 환산 초점거리 × 확대 배율.
        /// 자동 화각을 켜면 이 값으로 착란원을 계산한다 — 아이폰 광각은 24mm 라서
        /// 50mm 로 가정하면 원근과 흐림이 따로 놀아 가짜처럼 보인다.
        var capturedFocal: Float = 24
    }

    /// 단계 진행 보고 — (단계 키, 그 단계 안에서의 0...1)
    typealias StageReport = (String, Double) -> Void

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
        finish(command)

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

    /// 화면에서 가장 밝은 점광원들을 찾아낸다 (렌즈 플레어의 출발점).
    func lightSources(_ source: MTLTexture, threshold: Float, maxCount: Int = 8) -> [LightSource] {
        let aspect = Double(source.width) / Double(max(source.height, 1))
        let tilesY = 34
        let tilesX = max(Int(Double(tilesY) * aspect), 8)
        guard let colorTex = texture(tilesX, tilesY, format: .rgba32Float, shared: true),
              let placeTex = texture(tilesX, tilesY, format: .rgba32Float, shared: true),
              let command = queue.makeCommandBuffer() else { return [] }
        do {
            try run("light_scan", command, textures: [source, colorTex, placeTex],
                    size: (tilesX, tilesY))
        } catch {
            return []
        }
        finish(command)

        let count = tilesX * tilesY
        var colors = [SIMD4<Float>](repeating: .zero, count: count)
        var places = [SIMD4<Float>](repeating: .zero, count: count)
        colors.withUnsafeMutableBytes { buffer in
            colorTex.getBytes(buffer.baseAddress!, bytesPerRow: tilesX * 16,
                              from: MTLRegionMake2D(0, 0, tilesX, tilesY), mipmapLevel: 0)
        }
        places.withUnsafeMutableBytes { buffer in
            placeTex.getBytes(buffer.baseAddress!, bytesPerRow: tilesX * 16,
                              from: MTLRegionMake2D(0, 0, tilesX, tilesY), mipmapLevel: 0)
        }

        var candidates: [LightSource] = []
        for index in 0..<count {
            let intensity = colors[index].w
            guard intensity.isFinite, intensity > threshold else { continue }
            var source = LightSource()
            source.intensity = min(intensity, 400)
            source.r = max(colors[index].x, 0)
            source.g = max(colors[index].y, 0)
            source.b = max(colors[index].z, 0)
            source.u = min(max(places[index].x, 0), 1)
            source.v = min(max(places[index].y, 0), 1)
            // 밝을수록 광원 자체가 크다 (블루밍)
            source.radius = 0.009 + 0.016 * min(log2(1 + intensity) / 7, 1)
            candidates.append(source)
        }
        candidates.sort { $0.intensity > $1.intensity }

        // 가까이 붙은 타일들은 같은 광원이다 — 하나만 남긴다
        var picked: [LightSource] = []
        for candidate in candidates {
            if picked.count >= maxCount { break }
            let tooClose = picked.contains { existing in
                let dx = existing.u - candidate.u, dy = existing.v - candidate.v
                return dx * dx + dy * dy < 0.012
            }
            if !tooClose { picked.append(candidate) }
        }
        return picked
    }

    // MARK: - 현상 본체

    /// 전체 체인을 돌려 디스플레이 공간 RGBA16Float 결과를 돌려준다.
    ///
    /// 단계마다 명령 버퍼를 끊어서 (a) 진행률이 실제로 움직이고
    /// (b) 중간 버퍼가 바로 해제돼 메모리 최고점이 낮아진다.
    func develop(_ input: Input, _ settings: DevelopSettings,
                 recipe: DevelopRecipe = .default,
                 report: StageReport? = nil,
                 cancelled: (() -> Bool)? = nil) throws -> MTLTexture {
        let width = input.linear.width
        let height = input.linear.height
        let tell: StageReport = report ?? { _, _ in }
        let check: () throws -> Void = {
            if cancelled?() == true { throw RenderError.cancelled }
        }
        try check()

        guard var front = texture(width, height), var back = texture(width, height) else {
            throw RenderError.allocation
        }

        let detailParams = DetailParams(
            sharpness: settings.sharpness / 100,
            radius: settings.sharpenRadius,
            texture: settings.texture / 100,
            clarity: settings.clarity / 100,
            lumaNR: max(settings.luminanceNR / 100, input.autoNR),
            colorNR: min(max(settings.colorNR / 100, input.autoNR * 1.2), 0.7))

        // ── 1) 노이즈 제거 ──────────────────────────────────────────────
        //    휘도는 풀해상도 3x3 바이래터럴, 색도는 1/4 해상도에서 넓게.
        //    색 노이즈는 저주파라 이쪽이 더 깨끗하면서 16배 빠르다.
        tell("denoise", 0)
        do {
            let command = try newCommand()
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
            finish(command)
        }
        tell("denoise", 1)

        try check()

        // ── 2) 신경망 디테일 블록 ────────────────────────────────────────
        if recipe.neuralDetail && recipe.neuralStrength > 0.01 {
            tell("neural", 0)
            try applyNeural(source: front, destination: back, recipe: recipe,
                            noiseFloor: input.noiseFloor, report: tell)
            swap(&front, &back)
            tell("neural", 1)
        }
        try check()

        // ── 3) 피사계심도 ──────────────────────────────────────────────
        if settings.bokehEnabled, let depth = input.depth {
            if try applyDepthOfField(source: front, destination: back, depth: depth,
                                     matte: input.matte, settings: settings, recipe: recipe,
                                     focusDistance: input.focusDistance,
                                     capturedFocal: input.capturedFocal,
                                     report: tell, check: check) {
                swap(&front, &back)
            }
        }
        try check()

        // ── 4) 광원 추적 (렌즈 플레어) ──────────────────────────────────
        if recipe.lightTransport && settings.flare > 0.5 {
            tell("flare", 0)
            let lights = lightSources(front, threshold: recipe.lightThreshold)
            tell("flare", 0.5)
            if !lights.isEmpty,
               let buffer = device.makeBuffer(length: MemoryLayout<LightSource>.stride * lights.count,
                                              options: .storageModeShared) {
                buffer.contents().withMemoryRebound(to: LightSource.self, capacity: lights.count) {
                    for (index, light) in lights.enumerated() { $0[index] = light }
                }
                let overall = settings.flare / 100
                let blades = max(settings.apertureBlades, 0)
                let params = FlareParams(
                    count: Float(lights.count),
                    ghosts: min(max(settings.ghostCount.rounded(), 0), 8),
                    ghostStrength: settings.ghostStrength / 100 * overall,
                    haloStrength: settings.haloStrength / 100 * overall,
                    glareStrength: settings.glareStrength / 100 * overall,
                    spikeStrength: settings.spikeStrength / 100 * overall,
                    spikes: Float(blades < 3 ? 6 : (blades % 2 == 0 ? blades : blades * 2)),
                    blades: Float(blades),
                    curvature: settings.bladeCurvature,
                    rotation: settings.apertureRotation * .pi / 180,
                    aspect: Float(width) / Float(max(height, 1)),
                    fNumber: settings.fNumber)
                let command = try newCommand()
                try run("flare_render", command, textures: [front, back],
                        params: params, buffers: [buffer], size: (width, height))
                finish(command)
                swap(&front, &back)
            }
            tell("flare", 1)
        }

        try check()

        // ── 5) 톤 피라미드 ─────────────────────────────────────────────
        //    로그 휘도를 두 단계로 (1/8, 1/32) 바이래터럴 블러해서
        //    coarse / mid / fine 세 밴드로 나눈다. 로컬 라플라시안과 같은 분해다.
        tell("tone", 0)
        let maskRatio = 8
        let maskW = max(width / maskRatio, 32), maskH = max(height / maskRatio, 32)
        let coarseW = max(maskW / 4, 16), coarseH = max(maskH / 4, 16)
        guard let fineMask = texture(maskW, maskH, format: .r16Float),
              let scratch = texture(maskW, maskH, format: .r16Float),
              let coarseMask = texture(coarseW, coarseH, format: .r16Float),
              let coarseScratch = texture(coarseW, coarseH, format: .r16Float),
              let darkMask = texture(maskW, maskH, format: .r16Float),
              let darkScratch = texture(maskW, maskH, format: .r16Float) else {
            throw RenderError.allocation
        }
        do {
            let command = try newCommand()
            let ratio = Float(maskRatio)
            try run("log_downsample", command, textures: [front, fineMask],
                    params: ratio, size: (maskW, maskH))
            let fineBlur = BlurParams(radius: Float(max(3, min(maskW, maskH) / 18)), sigmaStops: 0.55)
            try run("luma_blur_h", command, textures: [fineMask, scratch],
                    params: fineBlur, size: (maskW, maskH))
            try run("luma_blur_v", command, textures: [scratch, fineMask],
                    params: fineBlur, size: (maskW, maskH))

            if recipe.toneBands > 2 {
                try run("downsample_box", command, textures: [fineMask, coarseMask],
                        params: Float(4), size: (coarseW, coarseH))
                let coarseBlur = BlurParams(radius: Float(max(4, min(coarseW, coarseH) / 5)),
                                            sigmaStops: 0.85)
                try run("luma_blur_h", command, textures: [coarseMask, coarseScratch],
                        params: coarseBlur, size: (coarseW, coarseH))
                try run("luma_blur_v", command, textures: [coarseScratch, coarseMask],
                        params: coarseBlur, size: (coarseW, coarseH))
            }

            if abs(settings.dehaze) > 0.5 {
                try run("dark_downsample", command, textures: [front, darkMask],
                        params: ratio, size: (maskW, maskH))
                let darkBlur = BlurParams(radius: Float(max(3, min(maskW, maskH) / 14)), sigmaStops: 0)
                try run("linear_blur_h", command, textures: [darkMask, darkScratch],
                        params: darkBlur, size: (maskW, maskH))
                try run("linear_blur_v", command, textures: [darkScratch, darkMask],
                        params: darkBlur, size: (maskW, maskH))
            }
            finish(command)
        }

        // ── 6) 톤 + 컬러 → 디스플레이 공간 (감마 인코딩은 여기서 딱 한 번) ──
        let wb = Renderer.whiteBalanceGain(settings.temperature, settings.tint, input.asShotNeutral)
        let wbLuma = max(0.2126 * wb.x + 0.7152 * wb.y + 0.0722 * wb.z, 1e-3)
        let auto = recipe.sceneAnalysis ? input.auto : .neutral
        let totalGain = exp2(settings.exposure + auto.autoExposure) * wbLuma

        // 블랙 포인트: 장면의 가장 어두운 곳을 진짜 검정으로. 베일링 플레어 제거.
        // 흐린 날·역광처럼 가장 어두운 곳조차 떠 있는 장면이 있어서, 상한을
        // 장면의 실제 다이내믹 레인지에 맞춰 늘린다 (좁을수록 더 과감하게).
        let blackCeiling = auto.dynamicRange < 7
            ? min(0.055 + (7 - auto.dynamicRange) * 0.035, 0.16)
            : 0.055
        let blackPoint = min(max(auto.blackRaw * totalGain * 0.9, 0), blackCeiling)
        let invBlack = 1 / max(1 - blackPoint, 1e-3)
        // 화이트: 장면의 실제 최대 휘도를 숄더가 1.0 으로 눕힌다
        var white = (auto.whiteRaw * totalGain - blackPoint) * invBlack
        white *= exp2(-settings.whites / 100 * 0.8)
        white = min(max(white, 1.02), 10)
        // 많이 압축할수록 국소 디테일을 더 살린다
        let detailGain = 1 + min(max(log2(white) / 3, 0), 1) * 0.3
        let localGain = 1 + settings.localContrast / 100 * 0.55
        // 대기광 — 장면의 밝은 쪽 값. 디헤이즈의 기준점이다.
        let airLight = min(max(auto.whiteRaw * totalGain * 0.75, 0.05), 4)

        let shadowTint = Renderer.splitTint(hue: settings.splitShadowHue,
                                            amount: settings.splitShadowSat / 100 * 0.16)
        let highTint = Renderer.splitTint(hue: settings.splitHighHue,
                                          amount: settings.splitHighSat / 100 * 0.16)

        // 장면 대비 보정: 다이내믹 레인지가 좁은 장면(흐린 날, 안개, 실내 평광)은
        // 그대로 두면 회색 죽이 된다. 필름 현상에서 인화지 호수를 올리는 것과 같다.
        let autoContrast: Float = recipe.sceneAnalysis
            ? min(max((8.2 - auto.dynamicRange) * 0.055, -0.05), 0.32)
            : 0

        let toneParams = ToneParams(
            exposure: settings.exposure + auto.autoExposure,
            contrast: settings.contrast / 100 + autoContrast,
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
            detailGain: detailGain,
            localGain: localGain,
            dehaze: settings.dehaze / 100,
            airLight: airLight,
            splitShadowR: shadowTint.x, splitShadowG: shadowTint.y, splitShadowB: shadowTint.z,
            splitHighR: highTint.x, splitHighG: highTint.y, splitHighB: highTint.z,
            splitBalance: settings.splitBalance / 100,
            skinProtect: settings.skinProtect / 100,
            toneBands: Float(recipe.toneBands))

        do {
            let command = try newCommand()
            try run("tone_color", command,
                    textures: [front, fineMask, recipe.toneBands > 2 ? coarseMask : fineMask,
                               darkMask, back],
                    params: toneParams, size: (width, height))
            finish(command)
        }
        swap(&front, &back)
        tell("tone", 1)

        // ── 7) 디테일 (클래리티용 대반경 휘도 블러도 1/8 에서) ───────────
        tell("detail", 0)
        do {
            let command = try newCommand()
            try run("luma_downsample", command, textures: [front, fineMask],
                    params: Float(maskRatio), size: (maskW, maskH))
            let clarityBlur = BlurParams(radius: Float(max(4, min(maskW, maskH) / 8)), sigmaStops: 0)
            try run("luma_blur_h", command, textures: [fineMask, scratch],
                    params: clarityBlur, size: (maskW, maskH))
            try run("luma_blur_v", command, textures: [scratch, fineMask],
                    params: clarityBlur, size: (maskW, maskH))
            try run("detail", command, textures: [front, fineMask, back],
                    params: detailParams, size: (width, height))
            finish(command)
        }
        swap(&front, &back)
        tell("detail", 1)

        // ── 8) 마무리 ─────────────────────────────────────────────────
        tell("finish", 0)
        do {
            let command = try newCommand()
            let finishParams = FinishParams(
                vignette: settings.vignette / 100,
                grain: settings.grain / 100,
                grainSize: settings.grainSize,
                chroma: settings.chromaticAberration / 100,
                seed: 7,
                coma: settings.coma / 100)
            try run("finish", command, textures: [front, back],
                    params: finishParams, size: (width, height))
            finish(command)
        }
        tell("finish", 1)
        return back
    }

    // MARK: - 신경망 블록

    /// 1/4 · 1/2 스케일 잔차를 먼저 만들고, 풀해상도 잔차는 적용 커널에서
    /// 즉석 계산해 더한다 (풀해상도 잔차 텍스처를 안 만들어 메모리를 아낀다).
    private func applyNeural(source: MTLTexture, destination: MTLTexture,
                             recipe: DevelopRecipe, noiseFloor: Float,
                             report: StageReport) throws {
        let width = source.width, height = source.height
        let scales = min(max(recipe.neuralScales, 1), 3)

        var params = NeuralParams(
            strength: recipe.neuralStrength,
            denoise: recipe.neuralDenoise,
            threshold: max(noiseFloor, 1e-4),
            scale: Float(scales),
            inhibition: recipe.neuralInhibition,
            edgeBoost: recipe.neuralEdgeBoost)

        let halfW = max(width / 2, 16), halfH = max(height / 2, 16)
        let quarterW = max(width / 4, 8), quarterH = max(height / 4, 8)
        guard let halfSrc = texture(halfW, halfH),
              let halfRes = texture(halfW, halfH, format: .r16Float),
              let quarterSrc = texture(quarterW, quarterH),
              let quarterRes = texture(quarterW, quarterH, format: .r16Float) else {
            throw RenderError.allocation
        }

        if scales >= 2 {
            let command = try newCommand()
            try run("downsample_box", command, textures: [source, halfSrc],
                    params: Float(2), size: (halfW, halfH))
            var halfParams = params
            // 저주파 밴드는 노이즈 바닥도 낮아진다 (평균이 돼서)
            halfParams.threshold = params.threshold * 0.6
            try run("neural_residual", command, textures: [halfSrc, halfRes],
                    params: halfParams, size: (halfW, halfH))
            finish(command)
            report("neural", 0.35)
        }
        if scales >= 3 {
            let command = try newCommand()
            try run("downsample_box", command, textures: [halfSrc, quarterSrc],
                    params: Float(2), size: (quarterW, quarterH))
            var quarterParams = params
            quarterParams.threshold = params.threshold * 0.35
            try run("neural_residual", command, textures: [quarterSrc, quarterRes],
                    params: quarterParams, size: (quarterW, quarterH))
            finish(command)
            report("neural", 0.6)
        }

        params.scale = Float(scales)
        let command = try newCommand()
        try run("neural_apply", command,
                textures: [source, halfRes, quarterRes, destination],
                params: params, size: (width, height))
        finish(command)
    }

    // MARK: - 피사계심도

    /// 깊이로 흐림을 만들어 `destination` 에 합성한다. 적용했으면 true.
    ///
    /// 전부 고정된 작업 해상도에서 끝내고 마지막 합성만 풀해상도다.
    ///  · 흐린 영역이라 해상도가 필요 없다
    ///  · 미리보기와 최종 결과의 보케가 정확히 같아진다
    ///  · 48MP 라고 해서 시간이 16배 들지 않는다
    @discardableResult
    private func applyDepthOfField(source: MTLTexture, destination: MTLTexture,
                                   depth: MTLTexture, matte: MTLTexture?,
                                   settings: DevelopSettings, recipe: DevelopRecipe,
                                   focusDistance: Float, capturedFocal: Float,
                                   report: StageReport,
                                   check: () throws -> Void) throws -> Bool {
        let width = source.width, height = source.height
        let focus = settings.focusDistance > 0.02 ? settings.focusDistance : focusDistance
        guard focus > 0.02 else { return false }

        report("depth", 0)
        let longSide = max(width, height)
        let target = recipe.bokehSide(outputLong: longSide)
        let k = min(Double(target) / Double(longSide), 1)
        let smallW = max(Int((Double(width) * k).rounded()), 64)
        let smallH = max(Int((Double(height) * k).rounded()), 64)

        // 깊이는 본질적으로 저주파라 보케 작업 해상도까지 올릴 필요가 없다.
        // 구멍 메우기 피라미드도 여기서 돌려 메모리를 아낀다.
        let depthLong = min(max(smallW, smallH), Renderer.depthWorkingSide)
        let dk = Double(depthLong) / Double(max(smallW, smallH))
        let depthW = max(Int((Double(smallW) * dk).rounded()), 48)
        let depthH = max(Int((Double(smallH) * dk).rounded()), 48)

        guard let smallSrc = texture(smallW, smallH),
              let depthGuide = texture(depthW, depthH),
              let depthHi = texture(depthW, depthH, format: .r32Float),
              let cocRaw = texture(depthW, depthH, format: .r16Float),
              let cocSmooth = texture(depthW, depthH, format: .r16Float) else {
            throw RenderError.allocation
        }
        let ratio = Float(width) / Float(smallW)
        let rotation = settings.apertureRotation * .pi / 180
        let focal = settings.effectiveFocalLength(captured: capturedFocal)

        var maxRadius: Float = 0
        do {
            let command = try newCommand()
            try run("downsample_box", command, textures: [source, smallSrc],
                    params: ratio, size: (smallW, smallH))
            try run("downsample_box", command, textures: [smallSrc, depthGuide],
                    params: Float(smallW) / Float(depthW), size: (depthW, depthH))

            // 깊이를 색상 가이드로 업샘플 (LiDAR 해상도 → 깊이 작업 해상도).
            // 못 읽은 곳은 0(구멍)으로 남는다.
            // 확대(크롭)한 만큼 깊이도 같은 영역만 봐야 한다.
            // 텍스처가 아래부터 채워졌으면 y 는 아래 기준으로 센다.
            let region = settings.cropRegion
            let originY = textureOriginIsBottom
                ? (1 - Float(region.origin.y) - Float(region.height))
                : Float(region.origin.y)
            let upsample = UpsampleParams(
                sigmaColor: 0.12,
                scaleX: Float(region.width), scaleY: Float(region.height),
                offsetX: Float(region.origin.x), offsetY: originY,
                rotation: Float(settings.depthRotation),
                mirror: settings.depthMirror ? 1 : 0)
            try run("depth_upsample", command, textures: [depthGuide, depth, depthHi],
                    params: upsample, size: (depthW, depthH))
            finish(command)
        }
        report("depth", 0.35)

        // LiDAR 사거리 밖은 전부 구멍이다 — push-pull 로 메운다
        guard let filled = try fillDepthHoles(depthHi) else { throw RenderError.allocation }
        report("depth", 0.7)

        do {
            let command = try newCommand()
            var depthFinal = filled
            if let matte, recipe.subjectMask {
                guard let refined = texture(depthW, depthH, format: .r32Float) else {
                    throw RenderError.allocation
                }
                try run("depth_refine_matte", command, textures: [filled, matte, refined],
                        params: focus, size: (depthW, depthH))
                depthFinal = refined
            }

            // 착란원은 '보케 작업 해상도 픽셀' 단위로 적는다. 텍스처 자체는 더
            // 작아도 되는데, 마칭/게더가 정규화 좌표로 읽기 때문이다.
            let cocParams = CoCParams(
                focusDistance: focus,
                focalLength: focal,
                fNumber: settings.fNumber,
                sensorWidth: 36,
                imageWidth: Float(smallW),
                maxCoC: 220,
                scale: settings.bokehScale)
            try run("coc_from_depth", command, textures: [depthFinal, cocRaw],
                    params: cocParams, size: (depthW, depthH))
            // 깊이맵이 이미지보다 거칠어서 생기는 계단을, 이미지를 가이드로
            // 삼아 다듬는다. 진짜 경계(피사체 윤곽)는 그대로 남는다.
            try run("coc_smooth", command, textures: [cocRaw, cocSmooth], size: (depthW, depthH))
            let guideRadius = Float(max(3, min(depthW, depthH) / 120))
            try run("coc_guided_h", command, textures: [cocSmooth, depthGuide, cocRaw],
                    params: guideRadius, size: (depthW, depthH))
            try run("coc_guided_v", command, textures: [cocRaw, depthGuide, cocSmooth],
                    params: guideRadius, size: (depthW, depthH))
            finish(command)

            maxRadius = min(Renderer.maxCoCPixels(settings: settings, focus: focus,
                                                  focalLength: focal,
                                                  imageWidth: Float(smallW)), 220)
        }
        report("depth", 1)
        guard maxRadius >= 1 else { return false }

        guard let blurred = texture(smallW, smallH) else { throw RenderError.allocation }

        if recipe.rayTracedDoF && recipe.apertureSamples >= 8 {
            try rayTracedDoF(source: smallSrc, coc: cocSmooth, destination: blurred,
                             settings: settings, recipe: recipe, maxRadius: maxRadius,
                             rotation: rotation, report: report, check: check)
        } else {
            report("rt", 0)
            let command = try newCommand()
            let bokehParams = BokehParams(
                maxRadius: maxRadius,
                rings: Float(maxRadius > 45 ? 9 : (maxRadius > 18 ? 7 : 5)),
                blades: Float(settings.apertureBlades),
                curvature: settings.bladeCurvature,
                bloom: settings.highlightBloom,
                catsEye: settings.catsEye,
                ring: settings.bokehRing,
                rotation: rotation + 0.21)
            try run("bokeh_gather", command, textures: [smallSrc, cocSmooth, blurred],
                    params: bokehParams, size: (smallW, smallH))
            finish(command)
            report("rt", 1)
        }

        // 풀해상도 합성 — CoC 를 풀해상도 픽셀 단위로 환산한 사본을 쓴다
        do {
            let command = try newCommand()
            guard let cocForComposite = texture(depthW, depthH, format: .r16Float) else {
                throw RenderError.allocation
            }
            try run("downsample_coc", command, textures: [cocSmooth, cocForComposite],
                    params: ratio, size: (depthW, depthH))
            // 저해상도 층은 확대한 만큼 못 믿는다. 그 아래 착란원은 풀해상도에서 직접 흐린다.
            let upscale = Float(width) / Float(smallW)
            let composite = CompositeParams(
                upscale: upscale,
                nearLimit: max(6, upscale * 5),
                blades: Float(settings.apertureBlades),
                curvature: settings.bladeCurvature,
                rotation: rotation)
            try run("bokeh_composite", command,
                    textures: [source, blurred, cocForComposite, destination],
                    params: composite, size: (width, height))
            finish(command)
        }
        return true
    }

    /// 구멍을 메울 수 있는 최대 반경 (깊이 작업 해상도 기준 픽셀).
    /// 이보다 큰 구멍은 '메울 근거가 없는 곳' = LiDAR 사거리 밖 = 무한대로 둔다.
    static let depthFillLevels = 5

    // MARK: - 진단

    /// 현상이 실제로 무엇을 보고 있는지 그림으로 뽑는다.
    /// 사진 결과만 보고 원인을 추리하는 건 느리고 자주 틀린다.
    struct Diagnostics {
        var depthRaw: CGImage?        // 업샘플 직후 (구멍이 빨갛게 보인다)
        var depthFilled: CGImage?     // 구멍 메운 뒤
        var coc: CGImage?             // 착란원 (초록=초점, 빨강=전경, 파랑=배경)
        var matte: CGImage?           // 피사체 마스크
        var focusDistance: Float = 0
        var effectiveFocal: Float = 0
        var maxRadius: Float = 0
        var nearLimit: Float = 0
        var validRatio: Float = 0
        var nearDepth: Float = 0
        var farDepth: Float = 0
        var autoNR: Float = 0
        var bokehSide: Int = 0
        var outputLong: Int = 0
    }

    func diagnose(_ input: Input, _ settings: DevelopSettings,
                  recipe: DevelopRecipe) -> Diagnostics {
        var out = Diagnostics()
        out.focusDistance = input.focusDistance
        out.autoNR = input.autoNR
        out.outputLong = max(input.linear.width, input.linear.height)
        out.bokehSide = recipe.bokehSide(outputLong: out.outputLong)
        let focal = settings.effectiveFocalLength(captured: input.capturedFocal)
        out.effectiveFocal = focal
        if let map = input.depthMap {
            let stats = map.stats()
            out.validRatio = stats.valid
            out.nearDepth = stats.near
            out.farDepth = stats.far
        }
        guard let depth = input.depth else { return out }

        // 진단은 작게 — 보려는 건 구조지 해상도가 아니다
        let long = 520
        let aspect = Double(input.linear.width) / Double(max(input.linear.height, 1))
        let dh = aspect >= 1 ? Int(Double(long) / aspect) : long
        let dw = aspect >= 1 ? long : Int(Double(long) * aspect)

        guard let guideTex = texture(dw, dh),
              let raw = texture(dw, dh, format: .r32Float),
              let rgba = texture(dw, dh, format: .rgba8Unorm),
              let cocTex = texture(dw, dh, format: .r16Float) else { return out }

        let region = settings.cropRegion
        let originY = textureOriginIsBottom
            ? (1 - Float(region.origin.y) - Float(region.height))
            : Float(region.origin.y)
        let upsample = UpsampleParams(
            sigmaColor: 0.12,
            scaleX: Float(region.width), scaleY: Float(region.height),
            offsetX: Float(region.origin.x), offsetY: originY,
            rotation: Float(settings.depthRotation),
            mirror: settings.depthMirror ? 1 : 0)
        let scale = Float(input.linear.width) / Float(dw)

        do {
            let command = try newCommand()
            try run("downsample_box", command, textures: [input.linear, guideTex],
                    params: scale, size: (dw, dh))
            try run("depth_upsample", command, textures: [guideTex, depth, raw],
                    params: upsample, size: (dw, dh))
            finish(command)

            let lo = log2(max(out.nearDepth, 0.05))
            let hi = log2(max(out.farDepth, out.nearDepth + 0.5))
            let debug = DebugParams(lo: lo, hi: hi)
            do {
                let command = try newCommand()
                try run("debug_depth", command, textures: [raw, rgba],
                        params: debug, size: (dw, dh))
                finish(command)
                out.depthRaw = makeCGImage(rgba, flip: outputNeedsFlip)
            }

            guard let filled = try fillDepthHoles(raw) else { return out }
            do {
                let command = try newCommand()
                try run("debug_depth", command, textures: [filled, rgba],
                        params: debug, size: (dw, dh))
                finish(command)
                out.depthFilled = makeCGImage(rgba, flip: outputNeedsFlip)
            }

            let smallW = max(Int(Double(out.bokehSide) * min(aspect, 1)), 64)
            out.maxRadius = min(Renderer.maxCoCPixels(settings: settings,
                                                      focus: input.focusDistance,
                                                      focalLength: focal,
                                                      imageWidth: Float(smallW)), 220)
            out.nearLimit = max(6, Float(input.linear.width) / Float(max(smallW, 1)) * 5)

            let cocParams = CoCParams(
                focusDistance: input.focusDistance,
                focalLength: focal,
                fNumber: settings.fNumber,
                sensorWidth: 36,
                imageWidth: Float(smallW),
                maxCoC: 220,
                scale: settings.bokehScale)
            let command2 = try newCommand()
            try run("coc_from_depth", command2, textures: [filled, cocTex],
                    params: cocParams, size: (dw, dh))
            try run("debug_coc", command2, textures: [cocTex, rgba],
                    params: DebugParams(lo: 0, hi: max(out.maxRadius, 1)), size: (dw, dh))
            finish(command2)
            out.coc = makeCGImage(rgba, flip: outputNeedsFlip)

            if let matte = input.matte {
                let command3 = try newCommand()
                try run("debug_gray", command3, textures: [matte, rgba], size: (dw, dh))
                finish(command3)
                out.matte = makeCGImage(rgba, flip: outputNeedsFlip)
            }
        } catch {
            return out
        }
        return out
    }

    /// LiDAR 가 못 읽은 구멍을 push-pull 피라미드로 메운다.
    /// 유효한 값만 모아 올리고(pull), 내려오면서 구멍만 채운다(push).
    ///
    /// **반드시 몇 단계에서 멈춰야 한다.** 끝까지 올리면 하늘처럼 화면의 절반을
    /// 차지하는 구멍이 '화면 전체 평균'으로 채워진다. 실내에서 창밖을 찍으면
    /// 유효한 깊이는 손과 가구뿐이라, 하늘에 "30cm"가 들어가 버린다.
    /// 그러면 능선에서 착란원 부호가 뒤집히며 계단 모양 하드 엣지가 생긴다.
    /// (v1.3 에서 실제로 그랬다.)
    private func fillDepthHoles(_ source: MTLTexture) throws -> MTLTexture? {
        let w = source.width, h = source.height
        guard let base = texture(w, h, format: .rg16Float) else { return nil }
        do {
            let command = try newCommand()
            try run("depth_pack", command, textures: [source, base], size: (w, h))
            finish(command)
        }

        // 피라미드 올리기 — 제한된 단계까지만
        var levels: [MTLTexture] = [base]
        var lw = w, lh = h
        while levels.count <= Renderer.depthFillLevels, lw > 8 || lh > 8 {
            lw = max(lw / 2, 1); lh = max(lh / 2, 1)
            guard let next = texture(lw, lh, format: .rg16Float) else { break }
            let command = try newCommand()
            try run("depth_pull", command, textures: [levels[levels.count - 1], next],
                    size: (lw, lh))
            finish(command)
            levels.append(next)
        }

        // 내려오면서 구멍 메우기
        var carried = levels[levels.count - 1]
        for index in stride(from: levels.count - 2, through: 0, by: -1) {
            let fine = levels[index]
            guard let merged = texture(fine.width, fine.height, format: .rg16Float) else { break }
            let command = try newCommand()
            try run("depth_push", command, textures: [fine, carried, merged],
                    size: (fine.width, fine.height))
            finish(command)
            carried = merged
        }

        guard let result = texture(w, h, format: .r32Float) else { return nil }
        let command = try newCommand()
        try run("depth_unpack", command, textures: [carried, result],
                params: Float(400), size: (w, h))
        finish(command)
        return result
    }

    /// 조리개 위의 광선을 깊이 버퍼에 마칭한다. 샘플을 조금씩 끊어 쏘면서
    /// 누산 텍스처에 쌓고, 하이라이트는 따로 산란시켜 더한다.
    private func rayTracedDoF(source: MTLTexture, coc: MTLTexture, destination: MTLTexture,
                              settings: DevelopSettings, recipe: DevelopRecipe,
                              maxRadius: Float, rotation: Float,
                              report: StageReport,
                              check: () throws -> Void) throws {
        let w = source.width, h = source.height
        let useScatter = recipe.highlightScatter

        guard var accA = texture(w, h), var accB = texture(w, h),
              let diffuse = texture(w, h), let highlight = texture(w, h) else {
            throw RenderError.allocation
        }

        // 하이라이트를 떼어내 분산을 줄인다 (split radiance estimator)
        do {
            let command = try newCommand()
            try run("zero_fill", command, textures: [accA], size: (w, h))
            if useScatter {
                try run("split_radiance", command, textures: [source, diffuse, highlight],
                        params: recipe.scatterThreshold, size: (w, h))
            } else {
                try run("blit", command, textures: [source, diffuse], size: (w, h))
            }
            finish(command)
        }

        let total = recipe.apertureSamples
        let chunk = Renderer.marchChunk
        let passes = max((total + chunk - 1) / chunk, 1)
        report("rt", 0)

        for pass in 0..<passes {
            try check()
            let offset = pass * chunk
            let count = min(chunk, total - offset)
            let params = MarchParams(
                maxRadius: maxRadius,
                samples: Float(count),
                sampleOffset: Float(offset),
                totalSamples: Float(total),
                steps: Float(recipe.marchSteps),
                blades: Float(settings.apertureBlades),
                curvature: settings.bladeCurvature,
                catsEye: settings.catsEye,
                ring: settings.bokehRing,
                apodization: settings.apodization,
                caScale: settings.longitudinalCA,
                rotation: rotation)
            let command = try newCommand()
            try run("dof_march", command, textures: [diffuse, coc, accA, accB],
                    params: params, size: (w, h))
            finish(command)
            swap(&accA, &accB)
            report("rt", Double(pass + 1) / Double(passes))
        }

        do {
            let command = try newCommand()
            try run("dof_resolve", command, textures: [diffuse, accA, destination], size: (w, h))
            finish(command)
        }

        guard useScatter else { return }

        // 하이라이트 산란 — 점광원을 조리개 모양대로 실제로 흩뿌린다
        report("scatter", 0)
        let binCount = w * h * 3
        guard let bins = device.makeBuffer(length: binCount * 4, options: .storageModePrivate),
              let scattered = texture(w, h) else {
            throw RenderError.allocation
        }
        let params = ScatterParams(
            width: Float(w), height: Float(h),
            maxRadius: maxRadius,
            blades: Float(settings.apertureBlades),
            curvature: settings.bladeCurvature,
            catsEye: settings.catsEye,
            ring: settings.bokehRing,
            apodization: settings.apodization,
            gain: max(settings.highlightBloom, 0),
            rotation: rotation,
            threshold: recipe.scatterThreshold)
        do {
            let command = try newCommand()
            try run("scatter_clear", command, textures: [], params: params,
                    buffers: [bins], size: (w, h))
            finish(command)
        }
        report("scatter", 0.3)
        do {
            let command = try newCommand()
            try run("scatter_splat", command, textures: [highlight, coc], params: params,
                    buffers: [bins], size: (w, h))
            finish(command)
        }
        report("scatter", 0.8)
        do {
            let command = try newCommand()
            try run("scatter_resolve", command, textures: [destination, scattered],
                    params: params, buffers: [bins], size: (w, h))
            try run("blit", command, textures: [scattered, destination], size: (w, h))
            finish(command)
        }
        report("scatter", 1)
    }

    /// 장면에서 나올 수 있는 최대 착란원(px). 게더/마칭 반경을 정하는 데 쓴다.
    static func maxCoCPixels(settings: DevelopSettings, focus: Float,
                             focalLength: Float, imageWidth: Float) -> Float {
        let f = focalLength
        let s1 = focus * 1000
        // 무한대 배경이 가장 크게 흐려진다
        let cocMM = (f * f / max(settings.fNumber, 0.7)) / max(s1 - f, 1)
        return min(cocMM / 36 * imageWidth * max(settings.bokehScale, 0), 700)
    }

    // MARK: - 벤치마크

    /// 현상에서 가장 무거운 연산을 같은 비율로 돌려 초당 텍스처 탭 수를 실측한다.
    func benchmark(side: Int, rounds: Int) -> SensorProbe.Benchmark? {
        guard let src = texture(side, side), let dst = texture(side, side) else { return nil }
        // 워밍업 — 셰이더 컴파일과 클럭 램프업을 측정에서 뺀다
        do {
            guard let warm = queue.makeCommandBuffer() else { return nil }
            try run("bench_load", warm, textures: [src, dst], params: Float(4), size: (side, side))
            warm.commit()
            warm.waitUntilCompleted()
        } catch {
            return nil
        }

        let start = CACurrentMediaTime()
        guard let command = queue.makeCommandBuffer() else { return nil }
        do {
            try run("bench_load", command, textures: [src, dst],
                    params: Float(rounds), size: (side, side))
        } catch {
            return nil
        }
        command.commit()
        command.waitUntilCompleted()
        let wall = CACurrentMediaTime() - start
        let gpu = command.gpuEndTime - command.gpuStartTime
        GPUClock.shared.add(gpu)

        let taps = Double(side) * Double(side) * Double(rounds)
        let seconds = max(gpu > 1e-6 ? gpu : wall, 1e-6)
        return SensorProbe.Benchmark(tapsPerSecond: taps / seconds,
                                     milliseconds: wall * 1000,
                                     gpuSeconds: gpu,
                                     pixels: side * side,
                                     rounds: rounds)
    }

    // MARK: - 색

    /// 색조(0~360) + 세기 → 디스플레이 공간에 더할 RGB 오프셋
    static func splitTint(hue: Float, amount: Float) -> SIMD3<Float> {
        guard amount > 1e-4 else { return .zero }
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        var rgb: SIMD3<Float>
        switch Int(h) {
        case 0: rgb = SIMD3(1, x, 0)
        case 1: rgb = SIMD3(x, 1, 0)
        case 2: rgb = SIMD3(0, 1, x)
        case 3: rgb = SIMD3(0, x, 1)
        case 4: rgb = SIMD3(x, 0, 1)
        default: rgb = SIMD3(1, 0, x)
        }
        // 휘도를 바꾸지 않도록 평균을 뺀다 — 색만 얹힌다
        let mean = (rgb.x + rgb.y + rgb.z) / 3
        return (rgb - SIMD3(repeating: mean)) * amount
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

    private func outputImage(_ texture: MTLTexture, flip: Bool) -> CIImage? {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: outputSpace]) else {
            return nil
        }
        guard flip else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
    }

    private func makeCGImage(_ texture: MTLTexture, flip: Bool) -> CGImage? {
        guard let image = outputImage(texture, flip: flip) else { return nil }
        return ciContext.createCGImage(image, from: image.extent,
                                       format: .RGBA8, colorSpace: outputSpace)
    }

    func cgImage(from texture: MTLTexture) -> CGImage? {
        makeCGImage(texture, flip: outputNeedsFlip)
    }

    func jpegData(from texture: MTLTexture, quality: CGFloat = 0.95) -> Data? {
        guard let image = outputImage(texture, flip: outputNeedsFlip) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: outputSpace,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}

enum RenderError: LocalizedError {
    case missingKernel(String)
    case encoder
    case allocation
    case decode(String)
    case tooLarge(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingKernel(let n): return "셰이더를 찾을 수 없어요 (\(n))"
        case .encoder: return "GPU 명령을 만들지 못했어요"
        case .allocation: return "메모리가 부족해요"
        case .decode(let m): return "RAW 디코드 실패 — \(m)"
        case .tooLarge(let m): return "설정이 이 기기에 너무 커요 — \(m)"
        case .cancelled: return "취소했어요"
        }
    }
}
