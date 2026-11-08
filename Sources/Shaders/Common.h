//
//  Common.h — ChanCam 셰이더 공용 정의
//
//  Pipeline.metal / Advanced.metal 두 파일이 같은 구조체와 도우미를 쓴다.
//  파일 범위 심볼이 두 번 링크되지 않도록 상수는 매크로, 샘플러는 constexpr
//  (내부 링키지) 로 둔다.
//

#pragma once
#include <metal_stdlib>
using namespace metal;

#define kLumaRec709 float3(0.2126f, 0.7152f, 0.0722f)
#define kPivotLog   (-2.4739312f)      // log2(0.18) — 미드그레이

constexpr sampler kLinear(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler kNearest(coord::normalized, address::clamp_to_edge, filter::nearest);

// ---------------------------------------------------------------------------
//  파라미터 — Swift 쪽 구조체와 메모리 배치가 같아야 한다 (전부 float)
// ---------------------------------------------------------------------------

struct ToneParams {
    float exposure;       // EV (사용자 + 자동 분석)
    float contrast;       // -1 ... 1
    float highlights;     // -1 ... 1
    float shadows;        // -1 ... 1
    float whites;         // -1 ... 1
    float blacks;         // -1 ... 1
    float vibrance;       // -1 ... 1
    float saturation;     // -1 ... 1
    float tempScaleR;     // 화이트밸런스 채널 게인
    float tempScaleG;
    float tempScaleB;
    float wbLuma;         // 위 게인의 휘도 (마스크 보정용)
    float white;          // 필름 숄더 백포인트 (선형). 장면 분석에서 나온다
    float blackPoint;     // 선형 블랙 (베일링 플레어 제거). 장면 분석
    float detailGain;     // 미세 밴드 게인 (1.0 ~ 1.4)
    float localGain;      // 중역 밴드 게인 (로컬 대비)
    float dehaze;         // -1 ... 1  (다크 채널 프라이어)
    float airLight;       // 대기광 추정 (선형 휘도)
    float splitShadowR;   // 색 분리 — 섀도우 틴트
    float splitShadowG;
    float splitShadowB;
    float splitHighR;     // 색 분리 — 하이라이트 틴트
    float splitHighG;
    float splitHighB;
    float splitBalance;   // -1 ... 1  분리 기준점
    float skinProtect;    // 0 ... 1
    float toneBands;      // 2 또는 3
    float _pad0;
};

struct BlurParams {
    float radius;         // px
    float sigmaStops;     // 바이래터럴 레인지 시그마 (스톱). 0 이면 일반 가우시안
    float _pad0;
    float _pad1;
};

struct DetailParams {
    float sharpness;      // 0 ... 1.5
    float radius;         // px
    float texture;        // -1 ... 1
    float clarity;        // -1 ... 1
    float lumaNR;         // 0 ... 1
    float colorNR;        // 0 ... 1
    float _pad0;
    float _pad1;
};

struct BokehParams {
    float maxRadius;      // 게더 반경 (px, 현재 해상도 기준)
    float rings;          // 샘플 링 수
    float blades;         // 조리개 날 수 (0 = 원형)
    float curvature;      // 0 = 다각형, 1 = 원형
    float bloom;          // 하이라이트 블룸
    float catsEye;        // 0 ... 1
    float ring;           // 구면수차(링 보케)
    float rotation;       // 조리개 회전 (rad)
};

struct CoCParams {
    float focusDistance;  // m
    float focalLength;    // mm (35mm 환산)
    float fNumber;
    float sensorWidth;    // mm (풀프레임 36)
    float imageWidth;     // px
    float maxCoC;         // px 상한
    float scale;          // 보케 배율 (물리값 위에 얹는 과장)
    float _pad1;
};

/// 깊이 업샘플 — 저해상 LiDAR 깊이를 이미지 좌표로 옮길 때의 보정
struct UpsampleParams {
    float sigmaColor;
    float scaleX;         // 이미지 uv → 깊이 uv (확대/크롭 + 화각 차이 보정)
    float scaleY;
    float offsetX;
    float offsetY;
    float rotation;       // 0,1,2,3 = 0°,90°,180°,270°
    float mirror;         // 0 또는 1
    float _pad0;
};

/// 흐린 층을 선명한 원본 위에 올릴 때
struct CompositeParams {
    float upscale;        // 출력/작업 해상도 비. 1 이면 보정 안 함
    float nearLimit;      // 이 착란원(px)까지는 풀해상도에서 직접 흐린다
    float blades;
    float curvature;
    float rotation;
    float _pad0;
    float _pad1;
    float _pad2;
};

/// 진단 시각화
struct DebugParams {
    float lo;
    float hi;
    float mode;
    float _pad0;
};

struct FinishParams {
    float vignette;       // -1 ... 1
    float grain;          // 0 ... 1
    float grainSize;      // px
    float chroma;         // 배율 색수차 0 ... 1
    float seed;
    float coma;           // 코마 수차 (주변부 방사 번짐) 0 ... 1
    float _pad1;
    float _pad2;
};

// ---------------------------------------------------------------------------
//  레이트레이싱 피사계심도
// ---------------------------------------------------------------------------

struct MarchParams {
    float maxRadius;      // px — 최대 착란원 반경
    float samples;        // 이번 패스에서 쏠 조리개 샘플 수
    float sampleOffset;   // 전체 중 시작 인덱스
    float totalSamples;   // 전체 조리개 샘플 수
    float steps;          // 레이 마치 스텝 수
    float blades;
    float curvature;
    float catsEye;
    float ring;           // 구면수차
    float apodization;    // 0 = 균일, 1 = 가장자리 완전 감쇠 (STF 렌즈)
    float caScale;        // 종방향 색수차 (채널별 초점면 차이)
    float rotation;       // 조리개 회전 (rad)
    float _pad0;
    float _pad1;
    float _pad2;
    float _pad3;
};

struct ScatterParams {
    float width;          // 대상 해상도
    float height;
    float maxRadius;      // px
    float blades;
    float curvature;
    float catsEye;
    float ring;
    float apodization;
    float gain;           // 하이라이트 블룸 배율
    float rotation;
    float threshold;      // 하이라이트 분리 임계 (선형)
    float _pad0;
};

// ---------------------------------------------------------------------------
//  광원 추적 (렌즈 플레어 / 고스트 / 회절)
// ---------------------------------------------------------------------------

struct LightSource {
    float u;              // 0 ... 1 화면 좌표
    float v;
    float intensity;      // 선형 휘도
    float r;              // 색
    float g;
    float b;
    float radius;         // 광원 크기 (uv)
    float _pad0;
};

struct FlareParams {
    float count;          // 유효 광원 수
    float ghosts;         // 고스트 개수
    float ghostStrength;  // 0 ... 1
    float haloStrength;
    float glareStrength;  // 베일링 글레어
    float spikeStrength;  // 회절 스파이크
    float spikes;         // 스파이크 수 (날 수에서 계산)
    float blades;
    float curvature;
    float rotation;
    float aspect;         // w/h
    float fNumber;        // 회절 세기 (조이면 강해진다)
    float _pad0;
    float _pad1;
    float _pad2;
    float _pad3;
};

// ---------------------------------------------------------------------------
//  신경망 디테일 블록
// ---------------------------------------------------------------------------

struct NeuralParams {
    float strength;       // 디테일 복원 0 ... 1.5
    float denoise;        // 노이즈 억제 0 ... 1
    float threshold;      // 셰이프 임계 (노이즈 레벨 추정)
    float scale;          // 이 패스의 스케일 (1, 2, 4)
    float inhibition;     // 분할 정규화 세기
    float edgeBoost;      // 일관된 경계 강조
    float _pad0;
    float _pad1;
};

// ---------------------------------------------------------------------------
//  공용 함수
// ---------------------------------------------------------------------------

inline float luma(float3 c) { return dot(max(c, 0.0f), kLumaRec709); }

// 선형 → sRGB 감마
inline float3 encodeGamma(float3 c) {
    c = clamp(c, 0.0f, 1.0f);
    return select(12.92f * c, 1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c > 0.0031308f);
}

inline float3 decodeGamma(float3 c) {
    c = clamp(c, 0.0f, 1.0f);
    return select(c / 12.92f, pow((c + 0.055f) / 1.055f, 2.4f), c > 0.04045f);
}

// 하이라이트 소프트 클립 (필름 숄더). white 보다 위를 부드럽게 눕힌다.
inline float3 filmicShoulder(float3 x, float white) {
    float w = max(white, 1.0f);
    return (x * (1.0f + x / (w * w))) / (1.0f + x);
}

// 조리개 날 모양: 각도에 따른 반경 배율
inline float apertureRadius(float theta, float blades, float curvature) {
    if (blades < 3.0f) return 1.0f;
    float seg = 2.0f * M_PI_F / blades;
    float a = fmod(theta + 4.0f * M_PI_F, seg) - seg * 0.5f;
    float poly = cos(seg * 0.5f) / max(cos(a), 1e-3f);
    return mix(min(poly, 1.0f), 1.0f, clamp(curvature, 0.0f, 1.0f));
}

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// 다각형 조리개 안쪽 판정 — 소프트 엣지. 0 = 밖, 1 = 안
inline float apertureMask(float2 p, float blades, float curvature, float softness) {
    float r = length(p);
    if (r < 1e-5f) return 1.0f;
    float shape = apertureRadius(atan2(p.y, p.x), blades, curvature);
    return 1.0f - smoothstep(shape - softness, shape, r);
}
