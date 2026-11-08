import Foundation

/// 현상 설정. Lightroom 슬라이더와 같은 의미/범위를 쓴다.
/// 기본값 `.chan` 은 주찬님의 a7 III + FE 50mm F1.8 샘플 171장에서
/// 실제 Lightroom(XMP) 보정값을 평균 낸 값이다.
struct DevelopSettings: Codable, Equatable {

    // MARK: 노출과 톤 (Lightroom Basic)
    var exposure: Float = 0        // EV, -5 ... +5
    var contrast: Float = 7        // -100 ... +100
    var highlights: Float = -75    // -100 ... +100
    var shadows: Float = 55        // -100 ... +100
    var whites: Float = 25         // -100 ... +100
    var blacks: Float = -20        // -100 ... +100

    /// 디헤이즈 — 다크 채널 프라이어로 투과율을 추정해 대기광을 역산한다.
    /// 음수면 반대로 안개를 더한다. -100 ... +100
    var dehaze: Float = 0
    /// 중역 로컬 대비. 다중 스케일 분해의 중간 밴드 게인. -100 ... +100
    var localContrast: Float = 0

    // MARK: 색
    /// 켈빈. 0 이면 촬영 당시(As Shot) 값을 그대로 쓴다.
    var temperature: Float = 0     // 2000 ... 12000
    var tint: Float = 0            // -150 ... +150
    var vibrance: Float = 12       // -100 ... +100
    var saturation: Float = 2      // -100 ... +100
    /// 생동감을 올릴 때 살색을 얼마나 지킬지. 0 ... 100
    var skinProtect: Float = 100

    // MARK: 색 분리 (스플릿 토닝)
    var splitShadowHue: Float = 215   // 0 ... 360
    var splitShadowSat: Float = 0     // 0 ... 100
    var splitHighHue: Float = 45      // 0 ... 360
    var splitHighSat: Float = 0       // 0 ... 100
    var splitBalance: Float = 0       // -100 ... +100

    // MARK: 디테일
    var texture: Float = 0         // -100 ... +100
    var clarity: Float = 0         // -100 ... +100
    var sharpness: Float = 40      // 0 ... 150
    var sharpenRadius: Float = 1.0 // 0.5 ... 3.0 px
    var luminanceNR: Float = 12    // 0 ... 100
    var colorNR: Float = 25        // 0 ... 100

    // MARK: 렌즈 (보케 시뮬레이션)
    var bokehEnabled = true
    /// 시뮬레이션할 조리개값. 네 FE 50mm F1.8 기준 1.8 ... 16
    var fNumber: Float = 1.8
    /// 초점 거리(m). 0 이면 촬영 시 LiDAR 초점 거리 사용
    var focusDistance: Float = 0
    /// 35mm 환산 초점거리. 보케 크기를 결정. 네 렌즈와 같은 50mm 기본
    var focalLength: Float = 50
    /// 조리개 날 수 (0 = 완전 원형). 소니 FE 50 F1.8 은 7 날
    var apertureBlades: Int = 7
    /// 날 곡률. 0 = 직선 다각형, 1 = 원형
    var bladeCurvature: Float = 0.75
    /// 하이라이트가 보케 볼로 피어나는 정도
    var highlightBloom: Float = 1.0 // 0 ... 2
    /// 화면 가장자리 고양이눈(기계적 비네팅)
    var catsEye: Float = 0.6       // 0 ... 1
    /// 보케 볼 가장자리 강조 (구면수차). 0 = 평평, 1 = 링 보케
    var bokehRing: Float = 0.15    // 0 ... 1
    /// 아포다이제이션 — 조리개 가장자리 투과율을 떨군다. 소니 STF 렌즈의 그 효과.
    /// 보케 경계가 솜처럼 부드러워진다. 0 ... 1
    var apodization: Float = 0.18
    /// 종방향 색수차 — 파장별로 초점면이 다르다. 밝은 렌즈의 실제 특성.
    var longitudinalCA: Float = 0.06  // 0 ... 0.4
    /// 조리개 회전 (도). 다각형 보케와 회절 스파이크의 방향.
    var apertureRotation: Float = 0   // 0 ... 90

    // MARK: 광원 추적 (렌즈 플레어)
    /// 전체 세기. 0 이면 광원 추적 단계를 아예 건너뛴다.
    var flare: Float = 0           // 0 ... 100
    var ghostCount: Float = 5      // 0 ... 8
    var ghostStrength: Float = 55  // 0 ... 100
    var haloStrength: Float = 35   // 0 ... 100
    var glareStrength: Float = 40  // 0 ... 100 (베일링 글레어)
    var spikeStrength: Float = 60  // 0 ... 100 (회절 스파이크)

    // MARK: 마무리
    var vignette: Float = -2       // -100 ... +100
    var grain: Float = 0           // 0 ... 100
    var grainSize: Float = 1.0     // 0.5 ... 3
    var chromaticAberration: Float = 0 // 0 ... 100
    /// 코마 수차 — 주변부에서 점광원이 방사 방향으로 번진다. 0 ... 100
    var coma: Float = 0

    // MARK: 지오메트리
    var rotation: Float = 0        // -45 ... +45 도
    var cropRect: CropRect = .full

    /// 주찬님 기본 룩 (샘플 평균)
    static let chan = DevelopSettings()

    /// 보정 없는 상태
    static var flat: DevelopSettings {
        var s = DevelopSettings()
        s.contrast = 0; s.highlights = 0; s.shadows = 0; s.whites = 0; s.blacks = 0
        s.vibrance = 0; s.saturation = 0; s.sharpness = 0; s.vignette = 0
        s.dehaze = 0; s.localContrast = 0
        s.splitShadowSat = 0; s.splitHighSat = 0
        s.flare = 0; s.coma = 0
        s.apodization = 0; s.longitudinalCA = 0
        s.bokehEnabled = false
        return s
    }

    /// 프리셋. 기본 사진 앱의 약점(과한 샤프닝·HDR티 나는 그림자·차가운 피부톤)을
    /// 피하도록 값을 잡았다.
    static var presets: [Preset] {
        // 애플이 했어야 할 "그냥 잘 찍힌 사진". 로컬 톤매핑을 과하게 안 쓴다.
        var natural = DevelopSettings()
        natural.contrast = 4
        natural.highlights = -45      // 하늘만 살짝 살림 (기본 앱은 -100급으로 눌러 평평해짐)
        natural.shadows = 28          // 들어 올리되 회색으로 뜨지 않게
        natural.whites = 18
        natural.blacks = -14          // 블랙을 제대로 떨궈 입체감 유지
        natural.vibrance = 10
        natural.saturation = 0
        natural.sharpness = 28        // 기본 앱보다 확실히 약하게
        natural.sharpenRadius = 0.9
        natural.luminanceNR = 10
        natural.colorNR = 22
        natural.bokehEnabled = false
        natural.vignette = 0

        // 인물: 피부가 핵심. 샤프닝을 크게 낮추고 하이라이트를 길게 눕힌다.
        var portrait = DevelopSettings()
        portrait.contrast = 2
        portrait.highlights = -62
        portrait.shadows = 42
        portrait.whites = 14
        portrait.blacks = -12
        portrait.vibrance = 8         // 생동감은 살색 보호가 들어가 있음
        portrait.saturation = 1
        portrait.sharpness = 18       // 피부 질감이 뭉개지지도, 거칠어지지도 않는 지점
        portrait.sharpenRadius = 1.2
        portrait.texture = -6         // 아주 약한 피부 정리
        portrait.luminanceNR = 18
        portrait.colorNR = 30
        portrait.fNumber = 1.8
        portrait.highlightBloom = 1.15
        portrait.catsEye = 0.7
        portrait.vignette = -14

        // 풍경: 디테일과 색. 보케는 끈다.
        var landscape = DevelopSettings()
        landscape.contrast = 10
        landscape.highlights = -70
        landscape.shadows = 45
        landscape.whites = 30
        landscape.blacks = -28
        landscape.vibrance = 22
        landscape.saturation = 2
        landscape.clarity = 14
        landscape.texture = 12
        landscape.sharpness = 55
        landscape.sharpenRadius = 0.8
        landscape.luminanceNR = 6
        landscape.colorNR = 18
        landscape.dehaze = 22         // 먼 산의 대기 산란을 걷어낸다
        landscape.localContrast = 18
        landscape.bokehEnabled = false
        landscape.vignette = -8

        // 야간: 노이즈를 잡되 뭉개지 않고, 점광원이 보케 볼로 피게 한다.
        var night = DevelopSettings()
        night.exposure = 0.15
        night.contrast = 6
        night.highlights = -55
        night.shadows = 38
        night.whites = 10
        night.blacks = -32            // 밤은 블랙이 떠 보이면 바로 싸구려가 된다
        night.vibrance = 14
        night.sharpness = 22
        night.luminanceNR = 42
        night.colorNR = 58
        night.fNumber = 1.8
        night.highlightBloom = 1.7
        night.bokehRing = 0.28
        night.catsEye = 0.75
        night.apodization = 0.08      // 밤엔 보케 볼이 또렷한 쪽이 낫다
        night.longitudinalCA = 0.10
        night.flare = 48              // 가로등·네온이 렌즈 안에서 하는 일
        night.ghostCount = 6
        night.spikeStrength = 70
        night.glareStrength = 50
        night.vignette = -10

        // 필름: 블랙을 띄우고 하이라이트를 길게. Portra 계열 느낌.
        var film = DevelopSettings()
        film.exposure = 0.1
        film.contrast = -14
        film.highlights = -72
        film.shadows = 34
        film.whites = 22
        film.blacks = 14              // 띄운 블랙이 필름의 핵심
        film.vibrance = 20
        film.saturation = -10
        film.temperature = 6300       // 살짝 따뜻하게 고정
        film.sharpness = 24
        film.grain = 42
        film.grainSize = 1.5
        film.vignette = -20
        film.fNumber = 2.0
        film.highlightBloom = 1.3
        film.apodization = 0.3        // 올드 렌즈의 뭉근한 보케
        film.longitudinalCA = 0.14
        film.flare = 30               // 코팅이 약한 올드 렌즈의 글로우
        film.glareStrength = 65
        film.ghostStrength = 35
        film.spikeStrength = 20
        film.coma = 18
        film.dehaze = -8              // 아주 살짝 안개를 얹는다

        // 흑백: 중간톤 분리가 생명.
        var mono = DevelopSettings()
        mono.contrast = 16
        mono.highlights = -58
        mono.shadows = 30
        mono.whites = 34
        mono.blacks = -26
        mono.saturation = -100
        mono.clarity = 18
        mono.sharpness = 42
        mono.grain = 28
        mono.grainSize = 1.2
        mono.vignette = -16

        return [
            Preset("Chan", "내 Lightroom 보정 평균", "person.crop.square", .chan),
            Preset("내추럴", "과하지 않게, 본 그대로", "leaf", natural),
            Preset("인물", "피부 우선 · f/1.8 보케", "person.fill", portrait),
            Preset("풍경", "디테일과 색 최대", "mountain.2.fill", landscape),
            Preset("야간", "노이즈 억제 · 보케 볼", "moon.stars.fill", night),
            Preset("필름", "띄운 블랙 · 그레인", "film.fill", film),
            Preset("흑백", "고대비 모노", "circle.lefthalf.filled", mono),
            Preset("원본", "보정 없음", "slash.circle", .flat),
        ]
    }
}

struct Preset: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let symbol: String
    let settings: DevelopSettings

    init(_ name: String, _ detail: String, _ symbol: String, _ settings: DevelopSettings) {
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.settings = settings
    }
}

struct CropRect: Codable, Equatable {
    var x: Float = 0
    var y: Float = 0
    var width: Float = 1
    var height: Float = 1

    static let full = CropRect()
    var isFull: Bool { x == 0 && y == 0 && width == 1 && height == 1 }
}

/// 슬라이더 하나의 정의 (UI 자동 생성용)
struct Slider1D: Identifiable {
    let id = UUID()
    let name: String
    let range: ClosedRange<Float>
    let neutral: Float
    let key: WritableKeyPath<DevelopSettings, Float>
    var step: Float = 1
    var unit: String = ""

    func value(_ s: DevelopSettings) -> Float { s[keyPath: key] }
    func text(_ s: DevelopSettings) -> String {
        let v = s[keyPath: key]
        if step < 1 { return String(format: "%+.2f%@", v, unit) }
        return String(format: "%+.0f%@", v, unit)
    }
}

enum EditorGroup: String, CaseIterable, Identifiable {
    case light = "라이트"
    case color = "컬러"
    case detail = "디테일"
    case lens = "렌즈"
    case optics = "광학"
    case effect = "효과"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "paintpalette"
        case .detail: return "circle.grid.cross"
        case .lens: return "camera.aperture"
        case .optics: return "rays"
        case .effect: return "wand.and.stars"
        }
    }

    /// 이 그룹이 하는 일에 대한 한 줄 설명 — 슬라이더 이름만으론 뭔지 모를 것들
    var note: String? {
        switch self {
        case .light:
            return "하이라이트·섀도우는 다중 스케일 분해의 '넓은' 밴드에만 걸려요. 그래서 크게 올려도 평평해지지 않아요."
        case .color:
            return "생동감은 이미 채도가 낮은 색에만 들어가고, 살색은 따로 지켜요."
        case .detail:
            return "신경망 디테일 세기는 현상 시작 화면에서 고르세요. 여기 값들은 그 위에 더해지는 고전 샤프닝이에요."
        case .lens:
            return "조리개·초점 거리는 얇은 렌즈 공식으로 착란원을 계산해요. 실제 렌즈와 같은 숫자를 넣으면 같은 흐림이 나와요."
        case .optics:
            return "광원이 렌즈 안에서 반사·회절되며 만드는 것들이에요. 밝은 점광원이 화면에 있을 때만 보여요."
        case .effect:
            return nil
        }
    }

    var sliders: [Slider1D] {
        switch self {
        case .light:
            return [
                Slider1D(name: "노출", range: -5...5, neutral: 0, key: \.exposure, step: 0.05, unit: " EV"),
                Slider1D(name: "대비", range: -100...100, neutral: 0, key: \.contrast),
                Slider1D(name: "하이라이트", range: -100...100, neutral: 0, key: \.highlights),
                Slider1D(name: "섀도우", range: -100...100, neutral: 0, key: \.shadows),
                Slider1D(name: "화이트", range: -100...100, neutral: 0, key: \.whites),
                Slider1D(name: "블랙", range: -100...100, neutral: 0, key: \.blacks),
                Slider1D(name: "로컬 대비", range: -100...100, neutral: 0, key: \.localContrast),
                Slider1D(name: "디헤이즈", range: -100...100, neutral: 0, key: \.dehaze),
            ]
        case .color:
            return [
                Slider1D(name: "색온도", range: 2000...12000, neutral: 5500, key: \.temperature, step: 50, unit: "K"),
                Slider1D(name: "색조", range: -150...150, neutral: 0, key: \.tint),
                Slider1D(name: "생동감", range: -100...100, neutral: 0, key: \.vibrance),
                Slider1D(name: "채도", range: -100...100, neutral: 0, key: \.saturation),
                Slider1D(name: "살색 보호", range: 0...100, neutral: 100, key: \.skinProtect),
                Slider1D(name: "섀도우 색조", range: 0...360, neutral: 215, key: \.splitShadowHue, step: 5, unit: "°"),
                Slider1D(name: "섀도우 채도", range: 0...100, neutral: 0, key: \.splitShadowSat),
                Slider1D(name: "하이라이트 색조", range: 0...360, neutral: 45, key: \.splitHighHue, step: 5, unit: "°"),
                Slider1D(name: "하이라이트 채도", range: 0...100, neutral: 0, key: \.splitHighSat),
                Slider1D(name: "분리 균형", range: -100...100, neutral: 0, key: \.splitBalance),
            ]
        case .detail:
            return [
                Slider1D(name: "텍스처", range: -100...100, neutral: 0, key: \.texture),
                Slider1D(name: "부분 대비", range: -100...100, neutral: 0, key: \.clarity),
                Slider1D(name: "샤프닝", range: 0...150, neutral: 0, key: \.sharpness),
                Slider1D(name: "샤프닝 반경", range: 0.5...3, neutral: 1, key: \.sharpenRadius, step: 0.1, unit: "px"),
                Slider1D(name: "휘도 노이즈", range: 0...100, neutral: 0, key: \.luminanceNR),
                Slider1D(name: "컬러 노이즈", range: 0...100, neutral: 0, key: \.colorNR),
            ]
        case .lens:
            return [
                Slider1D(name: "조리개", range: 1.0...16, neutral: 1.8, key: \.fNumber, step: 0.1),
                Slider1D(name: "초점 거리", range: 0...10, neutral: 0, key: \.focusDistance, step: 0.05, unit: "m"),
                Slider1D(name: "환산 화각", range: 24...135, neutral: 50, key: \.focalLength, step: 1, unit: "mm"),
                Slider1D(name: "조리개 곡률", range: 0...1, neutral: 1, key: \.bladeCurvature, step: 0.05),
                Slider1D(name: "조리개 회전", range: 0...90, neutral: 0, key: \.apertureRotation, step: 1, unit: "°"),
                Slider1D(name: "아포다이제이션", range: 0...1, neutral: 0, key: \.apodization, step: 0.02),
                Slider1D(name: "하이라이트 블룸", range: 0...2, neutral: 1, key: \.highlightBloom, step: 0.05),
                Slider1D(name: "고양이눈", range: 0...1, neutral: 0, key: \.catsEye, step: 0.05),
                Slider1D(name: "링 보케", range: 0...1, neutral: 0, key: \.bokehRing, step: 0.05),
                Slider1D(name: "종방향 색수차", range: 0...0.4, neutral: 0, key: \.longitudinalCA, step: 0.01),
            ]
        case .optics:
            return [
                Slider1D(name: "플레어 전체", range: 0...100, neutral: 0, key: \.flare),
                Slider1D(name: "고스트 개수", range: 0...8, neutral: 5, key: \.ghostCount),
                Slider1D(name: "고스트 세기", range: 0...100, neutral: 55, key: \.ghostStrength),
                Slider1D(name: "헤일로", range: 0...100, neutral: 35, key: \.haloStrength),
                Slider1D(name: "베일링 글레어", range: 0...100, neutral: 40, key: \.glareStrength),
                Slider1D(name: "회절 스파이크", range: 0...100, neutral: 60, key: \.spikeStrength),
                Slider1D(name: "코마 수차", range: 0...100, neutral: 0, key: \.coma),
            ]
        case .effect:
            return [
                Slider1D(name: "비네팅", range: -100...100, neutral: 0, key: \.vignette),
                Slider1D(name: "그레인", range: 0...100, neutral: 0, key: \.grain),
                Slider1D(name: "그레인 크기", range: 0.5...3, neutral: 1, key: \.grainSize, step: 0.1),
                Slider1D(name: "색수차", range: 0...100, neutral: 0, key: \.chromaticAberration),
            ]
        }
    }
}
