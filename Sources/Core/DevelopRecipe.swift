import Foundation

/// 현상 품질 등급. 사용자가 "얼마나 빡세게 현상할지" 고르는 다이얼.
///
/// 등급이 바꾸는 것은 전부 '적분을 몇 번 하느냐'다. 결과의 성격이 바뀌는 게 아니라
/// 노이즈(샘플링 분산)가 줄어든다. 그래서 극한으로 올려도 그림이 달라지지 않고
/// 보케 디스크의 얼룩과 깊이 경계의 계단만 사라진다.
enum DevelopTier: Int, Codable, CaseIterable, Identifiable {
    case draft = 0
    case standard = 1
    case advanced = 2
    case extreme = 3

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .draft: return "초안"
        case .standard: return "표준"
        case .advanced: return "고급"
        case .extreme: return "극한"
        }
    }

    var symbol: String {
        switch self {
        case .draft: return "hare.fill"
        case .standard: return "gauge.medium"
        case .advanced: return "gauge.high"
        case .extreme: return "flame.fill"
        }
    }

    var detail: String {
        switch self {
        case .draft: return "레이트레이싱 없이 빠르게. 구도 확인용"
        case .standard: return "조리개 24샘플 · 2밴드 톤 · 신경망 2스케일"
        case .advanced: return "조리개 48샘플 · 3밴드 톤 · 광원 추적"
        case .extreme: return "조리개 112샘플 · 32스텝 마칭 · 전부 최대"
        }
    }

    /// 조리개 위에서 쏘는 광선 수. 보케 디스크의 매끄러움을 결정한다.
    var apertureSamples: Int {
        switch self {
        case .draft: return 0            // 레이트레이싱 끔
        case .standard: return 24
        case .advanced: return 48
        case .extreme: return 112
        }
    }

    /// 광선 하나가 깊이 버퍼를 훑는 스텝 수. 가려짐 정확도를 결정한다.
    var marchSteps: Int {
        switch self {
        case .draft: return 8
        case .standard: return 14
        case .advanced: return 22
        case .extreme: return 32
        }
    }

    /// 보케 계산 해상도 (긴 변)
    var bokehSide: Int {
        switch self {
        case .draft: return 900
        case .standard: return 1200
        case .advanced: return 1600
        case .extreme: return 2200
        }
    }

    var neuralScales: Int {
        switch self {
        case .draft: return 1
        case .standard: return 2
        default: return 3
        }
    }

    var toneBands: Int { self == .draft ? 2 : 3 }

    /// 한 장 현상에 걸리는 대략적인 시간 배수 (표준 = 1.0)
    var costFactor: Double {
        switch self {
        case .draft: return 0.25
        case .standard: return 1.0
        case .advanced: return 2.8
        case .extreme: return 9.0
        }
    }
}

/// 현상 한 번의 전체 지시서. 사진마다가 아니라 '현상 실행' 단위로 고른다.
struct DevelopRecipe: Codable, Equatable {
    var tier: DevelopTier = .advanced

    // MARK: 출력
    var outputSize: Int = 24          // MP
    var jpegQuality: Double = 0.95
    var saveToPhotos = true
    var keepRaw = true

    // MARK: 광학 시뮬레이션
    /// 레이트레이싱 피사계심도 — 조리개 광선을 깊이 버퍼에 마칭한다
    var rayTracedDoF = true
    var apertureSamples = 48
    var marchSteps = 22
    /// 하이라이트 산란 — 점광원을 조리개 모양으로 실제로 흩뿌린다
    var highlightScatter = true
    var scatterThreshold: Float = 1.6
    /// 광원 추적 — 고스트·회절·글레어 (세기는 사진별 현상 설정에서)
    var lightTransport = true
    /// 광원으로 인정할 밝기 임계 (디스플레이 백색 = 1.0)
    var lightThreshold: Float = 2.4

    // MARK: 신경망
    var neuralDetail = true
    var neuralScales = 3
    var neuralStrength: Float = 0.55
    var neuralDenoise: Float = 0.5
    var neuralInhibition: Float = 0.6
    var neuralEdgeBoost: Float = 0.25

    // MARK: 톤
    var toneBands = 3
    var sceneAnalysis = true

    // MARK: 피사체
    /// Vision 피사체 분리로 깊이 경계를 다듬는다 (머리카락까지)
    var subjectMask = true

    static let `default` = DevelopRecipe()

    /// 등급을 고르면 세부 값들이 그 등급 기본으로 맞춰진다
    mutating func applyTier(_ tier: DevelopTier) {
        self.tier = tier
        rayTracedDoF = tier != .draft
        apertureSamples = max(tier.apertureSamples, 8)
        marchSteps = tier.marchSteps
        neuralScales = tier.neuralScales
        toneBands = tier.toneBands
        highlightScatter = tier != .draft
        lightTransport = tier.rawValue >= DevelopTier.advanced.rawValue
    }

    /// 사용자가 세부 값을 만져 등급 기본과 달라졌는지
    var isCustom: Bool {
        var base = DevelopRecipe()
        base.applyTier(tier)
        base.outputSize = outputSize
        base.jpegQuality = jpegQuality
        base.saveToPhotos = saveToPhotos
        base.keepRaw = keepRaw
        base.scatterThreshold = scatterThreshold
        base.lightThreshold = lightThreshold
        base.neuralStrength = neuralStrength
        base.neuralDenoise = neuralDenoise
        base.neuralInhibition = neuralInhibition
        base.neuralEdgeBoost = neuralEdgeBoost
        base.sceneAnalysis = sceneAnalysis
        base.subjectMask = subjectMask
        return base != self
    }

    var longSide: Int {
        switch outputSize {
        case 12: return 4032
        case 48: return 8064
        default: return 5712
        }
    }

    var bokehSide: Int { tier.bokehSide }

    /// 광선 하나당 텍스처 탭 수 × 조리개 샘플 = 픽셀당 작업량
    var tapsPerPixel: Int {
        guard rayTracedDoF else { return 470 }
        return apertureSamples * (marchSteps + 2)
    }

    /// 아주 거친 예상 시간(초). 기기별로 많이 다르다 — 어디까지나 눈금이다.
    func estimatedSeconds(gpuScore: Double) -> Double {
        let bokehPixels = Double(bokehSide * bokehSide) * 0.75
        let outPixels = Double(longSide * longSide) * 0.75
        // 보케(레이트레이싱) + 신경망 + 나머지 풀해상도 패스
        var work = bokehPixels * Double(tapsPerPixel)
        work += outPixels * Double(12 + neuralScales * 9)
        if highlightScatter { work += bokehPixels * 60 }
        if lightTransport { work += bokehPixels * 30 }
        let score = max(gpuScore, 1e6)      // 탭/초
        return work / score + 1.2           // +디코드/인코딩 고정비
    }

    /// 중간 버퍼가 차지하는 대략적인 최대 메모리 (바이트)
    var estimatedBytes: Int64 {
        let out = Int64(Double(longSide * longSide) * 0.75)
        let bok = Int64(Double(bokehSide * bokehSide) * 0.75)
        // 풀해상도 RGBA16F 2장 + 1/2, 1/4 보조 + 보케 작업 버퍼 5장 + 산란 빈
        var total = out * 8 * 2
        total += out * 8 / 4 + out * 8 / 16
        total += bok * 8 * 5
        if highlightScatter { total += bok * 12 }
        return total
    }

    var summary: String {
        var parts: [String] = [tier.name, "\(outputSize)MP"]
        if rayTracedDoF { parts.append("RT \(apertureSamples)×\(marchSteps)") }
        if highlightScatter { parts.append("산란") }
        if lightTransport { parts.append("광원추적") }
        if neuralDetail { parts.append("신경망 \(neuralScales)스케일") }
        return parts.joined(separator: " · ")
    }
}

/// 현상 단계 — 진행률 표시용. weight 는 전체에서 차지하는 비중.
struct DevelopStage {
    let key: String
    let name: String
    let weight: Double

    static func plan(_ recipe: DevelopRecipe, hasDepth: Bool) -> [DevelopStage] {
        // 순서는 실제 실행 순서와 같아야 한다 (진행률이 뒤로 가지 않도록).
        // prepare() 는 피사체 분리 → RAW 디코드 → 장면 분석 순으로 돈다.
        var stages: [DevelopStage] = []
        if recipe.subjectMask && hasDepth {
            stages.append(DevelopStage(key: "mask", name: "피사체 분리", weight: 8))
        }
        stages.append(DevelopStage(key: "decode", name: "RAW 디코드", weight: 12))
        stages.append(DevelopStage(key: "analyze", name: "장면 분석", weight: 3))
        stages.append(DevelopStage(key: "denoise", name: "노이즈 제거", weight: 6))
        if recipe.neuralDetail {
            stages.append(DevelopStage(key: "neural", name: "신경망 디테일", weight: 8))
        }
        if hasDepth {
            stages.append(DevelopStage(key: "depth", name: "깊이 업샘플 · 착란원", weight: 4))
            if recipe.rayTracedDoF {
                stages.append(DevelopStage(key: "rt", name: "광선 추적",
                                           weight: 22 * recipe.tier.costFactor))
            } else {
                stages.append(DevelopStage(key: "rt", name: "보케 게더", weight: 10))
            }
            if recipe.highlightScatter {
                stages.append(DevelopStage(key: "scatter", name: "하이라이트 산란", weight: 6))
            }
        }
        if recipe.lightTransport {
            stages.append(DevelopStage(key: "flare", name: "광원 추적 · 플레어", weight: 5))
        }
        stages.append(DevelopStage(key: "tone", name: "다중 스케일 톤매핑", weight: 8))
        stages.append(DevelopStage(key: "detail", name: "디테일 · 샤프닝", weight: 5))
        stages.append(DevelopStage(key: "finish", name: "마무리", weight: 4))
        stages.append(DevelopStage(key: "encode", name: "JPEG 인코딩 · 저장", weight: 9))
        return stages
    }
}
