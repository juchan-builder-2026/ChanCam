#include "Common.h"

// ============================================================================
//  ChanCam 현상 파이프라인
//  입력은 CIRAWFilter 가 디코드한 선형(linear) 장면 참조 RGB (RGBA16Float).
//  모든 단계는 선형에서 처리하고 마지막에만 디스플레이 감마로 인코딩한다.
//  보케는 반드시 선형 HDR 에서 해야 하이라이트가 보케 볼로 피어난다.
//
//  구조체·공용 함수는 Common.h 에 있다 (Advanced.metal 과 공유).
// ============================================================================

// ---------------------------------------------------------------------------
//  1. 깊이 업샘플 — LiDAR 저해상 깊이를 색상 가이드로 조인트 바이래터럴 업샘플
//     이게 없으면 보케 경계가 LiDAR 해상도(저해상)로 뭉개진다.
// ---------------------------------------------------------------------------

kernel void depth_upsample(texture2d<float, access::sample> guide   [[texture(0)]],  // 선형 RGB
                           texture2d<float, access::sample> depthLo [[texture(1)]],  // R = 미터, 0 = 무효
                           texture2d<float, access::write>  depthHi [[texture(2)]],
                           constant float& sigmaColor               [[buffer(0)]],
                           uint2 gid                                [[thread_position_in_grid]])
{
    uint w = depthHi.get_width(), h = depthHi.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float centerL = luma(guide.sample(kLinear, uv).rgb);

    float2 loSize = float2(depthLo.get_width(), depthLo.get_height());
    float2 step = 1.0f / loSize;

    float acc = 0.0f, wsum = 0.0f;
    // 저해상 깊이에서 5x5 이웃을 색상 유사도로 가중 평균
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            float2 suv = uv + float2(dx, dy) * step;
            float d = depthLo.sample(kNearest, suv).r;
            if (d <= 0.0f) continue;
            float sl = luma(guide.sample(kLinear, suv).rgb);
            float dc = (sl - centerL) / max(sigmaColor, 1e-3f);
            float ds = float(dx * dx + dy * dy) / 8.0f;
            float wgt = exp(-0.5f * (dc * dc + ds));
            acc += d * wgt;
            wsum += wgt;
        }
    }
    float result = (wsum > 1e-5f) ? (acc / wsum) : depthLo.sample(kLinear, uv).r;
    depthHi.write(float4(result, 0, 0, 1), gid);
}

// 인물 매트로 깊이 경계를 정리 (머리카락 경계까지 살림)
kernel void depth_refine_matte(texture2d<float, access::read>  depthIn [[texture(0)]],
                               texture2d<float, access::sample> matte  [[texture(1)]],
                               texture2d<float, access::write> depthOut[[texture(2)]],
                               constant float& subjectDistance         [[buffer(0)]],
                               uint2 gid                               [[thread_position_in_grid]])
{
    uint w = depthOut.get_width(), h = depthOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float d = depthIn.read(gid).r;
    float m = matte.sample(kLinear, (float2(gid) + 0.5f) / float2(w, h)).r;
    // 매트가 확실한 인물 영역이면 피사체 거리로 끌어당긴다
    float pull = smoothstep(0.55f, 0.95f, m);
    float fixed_d = (d > 0.05f) ? mix(d, subjectDistance, pull * 0.85f) : subjectDistance;
    depthOut.write(float4(fixed_d, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
//  2. 착란원(CoC) 계산 — 실제 얇은 렌즈 공식
//     CoC_mm = (f^2 / N) * |S2 - S1| / (S2 * (S1 - f))
//     부호: + 는 초점면 뒤(배경), - 는 앞(전경)
// ---------------------------------------------------------------------------

kernel void coc_from_depth(texture2d<float, access::read>  depth [[texture(0)]],
                           texture2d<float, access::write> coc   [[texture(1)]],
                           constant CoCParams& P                 [[buffer(0)]],
                           uint2 gid                             [[thread_position_in_grid]])
{
    uint w = coc.get_width(), h = coc.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float d = depth.read(gid).r;                 // m
    if (d <= 0.02f || P.focusDistance <= 0.02f) { coc.write(float4(0), gid); return; }

    float f  = P.focalLength;                    // mm
    float S1 = P.focusDistance * 1000.0f;        // mm
    float S2 = d * 1000.0f;                      // mm
    float cocMM = (f * f / max(P.fNumber, 0.7f)) * abs(S2 - S1) / (S2 * max(S1 - f, 1.0f));
    float px = cocMM / P.sensorWidth * P.imageWidth;
    px = min(px, P.maxCoC);
    coc.write(float4((S2 >= S1) ? px : -px, 0, 0, 1), gid);
}

// CoC 를 약간 부드럽게 (깊이 계단 현상 제거)
kernel void coc_smooth(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid                           [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float acc = 0.0f;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            uint2 p = uint2(clamp(int(gid.x) + dx, 0, int(w) - 1),
                            clamp(int(gid.y) + dy, 0, int(h) - 1));
            acc += src.read(p).r;
        }
    }
    dst.write(float4(acc / 9.0f, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
//  3. 노이즈 제거 — 휘도/색도 분리 바이래터럴
//     색 노이즈는 훨씬 세게 뭉개도 디테일이 안 죽는다.
// ---------------------------------------------------------------------------

//  컬러 노이즈는 저주파라 1/4 해상도에서 넓게 뭉개는 게 더 깨끗하고 16배 빠르다.
//  여기서 작은 해상도의 색도판을 만든다.
kernel void chroma_blur(texture2d<float, access::sample> src [[texture(0)]],  // 1/4 축소본
                        texture2d<float, access::write>  dst [[texture(1)]],
                        constant DetailParams& P             [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float3 center = src.sample(kLinear, uv).rgb;
    float centerL = max(luma(center), 1e-4f);

    int r = 1 + int(clamp(P.colorNR, 0.0f, 1.0f) * 3.0f);   // 최대 7x7 @ 1/4 = 28x28 @ 풀
    float3 acc = 0.0f;
    float wsum = 0.0f;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            float3 s = src.sample(kLinear, uv + float2(dx, dy) / size).rgb;
            float sl = max(luma(s), 1e-4f);
            // 밝기가 비슷한 이웃만 — 경계 너머로 색이 번지지 않게
            float dl = log2(sl / centerL);
            float wgt = exp(-0.5f * dl * dl / 0.36f);
            acc += (s / sl) * wgt;      // 휘도를 뺀 순수 색도
            wsum += wgt;
        }
    }
    dst.write(float4(acc / max(wsum, 1e-5f), 1), gid);
}

kernel void denoise(texture2d<float, access::sample> src    [[texture(0)]],
                    texture2d<float, access::sample> chroma [[texture(1)]],  // 1/4 색도판
                    texture2d<float, access::write>  dst    [[texture(2)]],
                    constant DetailParams& P                [[buffer(0)]],
                    uint2 gid                               [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float3 center = src.sample(kLinear, uv).rgb;

    if (P.lumaNR < 0.01f && P.colorNR < 0.01f) {
        dst.write(float4(center, 1), gid);
        return;
    }

    float3 outC = center;

    // 1) 휘도 노이즈 — 풀해상도 3x3 바이래터럴이면 충분하다 (디테일을 지킨다)
    if (P.lumaNR > 0.01f) {
        float centerL = luma(center);
        float sigmaL = 0.010f + 0.12f * P.lumaNR;
        float3 acc = 0.0f;
        float wsum = 0.0f;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                float3 s = src.sample(kLinear, uv + float2(dx, dy) / size).rgb;
                float dl = (luma(s) - centerL) / sigmaL;
                float spatial = (dx == 0 && dy == 0) ? 1.0f : ((dx == 0 || dy == 0) ? 0.7f : 0.45f);
                float wgt = spatial * exp(-0.5f * dl * dl);
                acc += s * wgt;
                wsum += wgt;
            }
        }
        outC = mix(center, acc / max(wsum, 1e-5f), clamp(P.lumaNR, 0.0f, 1.0f));
    }

    // 2) 컬러 노이즈 — 작은 색도판을 가져와 현재 휘도에 입힌다
    if (P.colorNR > 0.01f) {
        float3 cs = chroma.sample(kLinear, uv).rgb;       // 휘도 1 로 정규화된 색도
        float lp = max(luma(outC), 1e-5f);
        float cl = max(luma(cs), 1e-4f);
        float3 chromaPart = cs * (lp / cl);
        outC = mix(outC, chromaPart, clamp(P.colorNR * 0.9f, 0.0f, 1.0f));
    }

    dst.write(float4(max(outC, 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  4. 로컬 톤 마스크용 휘도 블러 (하이라이트/섀도우가 로컬로 동작하게)
// ---------------------------------------------------------------------------

//  입력·출력 모두 '로그2 휘도' 다. 레인지 가중치를 쓰는 바이래터럴이라
//  경계를 넘어 번지지 않는다 → 섀도우를 크게 올려도 할로가 안 생긴다.

inline float bilateralLine(texture2d<float, access::sample> src, float2 uv, float2 step,
                           int r, float sigmaS2, float sigmaR)
{
    float center = src.sample(kNearest, uv).r;
    float acc = center, wsum = 1.0f;
    float invR2 = (sigmaR > 1e-4f) ? (1.0f / (2.0f * sigmaR * sigmaR)) : 0.0f;
    for (int i = 1; i <= r; ++i) {
        float sp = exp(-0.5f * float(i * i) / sigmaS2);
        for (int s = -1; s <= 1; s += 2) {
            float v = src.sample(kLinear, uv + step * float(i * s)).r;
            float dv = v - center;
            float wgt = (invR2 > 0.0f) ? sp * exp(-dv * dv * invR2) : sp;
            acc += v * wgt;
            wsum += wgt;
        }
    }
    return acc / max(wsum, 1e-5f);
}

kernel void luma_blur_h(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write>  dst [[texture(1)]],
                        constant BlurParams& P               [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(P.radius, 1.0f, 28.0f));
    float v = bilateralLine(src, uv, float2(1.0f / size.x, 0.0f), r,
                            0.35f * float(r * r) + 1.0f, P.sigmaStops);
    dst.write(float4(v, 0, 0, 1), gid);
}

kernel void luma_blur_v(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write>  dst [[texture(1)]],
                        constant BlurParams& P               [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(P.radius, 1.0f, 28.0f));
    float v = bilateralLine(src, uv, float2(0.0f, 1.0f / size.y), r,
                            0.35f * float(r * r) + 1.0f, P.sigmaStops);
    dst.write(float4(v, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
//  5. 톤 + 컬러 — 선형에서 노출/로컬톤, 숄더, 감마, 대비, 엔드포인트, 컬러
// ---------------------------------------------------------------------------

//  밴드 셋:
//    coarse  = 아주 넓은 영역의 로그 휘도  → 전역 톤 연산자(숄더·대비·존)를 받는다
//    fine    = 중간 영역의 로그 휘도       → 중역 로컬 대비 (localGain)
//    detail  = 픽셀 − fine                 → 미세 디테일 (detailGain)
//  이게 로컬 라플라시안과 같은 다중 스케일 분해다. 단일 스케일로 하면
//  섀도우를 올릴 때 '중간이 평평해지는' HDR 티가 반드시 생긴다.

kernel void tone_color(texture2d<float, access::read>   src     [[texture(0)]],
                       texture2d<float, access::sample> fineTex [[texture(1)]],  // log2 휘도 (1/8)
                       texture2d<float, access::sample> coarse  [[texture(2)]],  // log2 휘도 (1/16)
                       texture2d<float, access::sample> darkTex [[texture(3)]],  // 선형 최소채널
                       texture2d<float, access::write>  dst     [[texture(4)]],
                       constant ToneParams& P                   [[buffer(0)]],
                       uint2 gid                                [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);

    float3 c = max(src.read(gid).rgb, 0.0f);

    // (a) 화이트밸런스 — 선형에서 채널 게인
    c *= float3(P.tempScaleR, P.tempScaleG, P.tempScaleB);

    // (b) 노출 (사용자 + 장면 자동)
    float gain = exp2(P.exposure);
    c *= gain;

    // (c) 디헤이즈 — 다크 채널 프라이어. 투과율 t 를 추정해 대기광을 역산한다.
    //     J = (I − A(1−t)) / t.  음수면 반대로 안개를 더한다.
    if (abs(P.dehaze) > 0.002f) {
        float A = max(P.airLight, 1e-3f);
        float dark = max(darkTex.sample(kLinear, uv).r * P.wbLuma * gain, 0.0f);
        float t = 1.0f - clamp(P.dehaze, -1.0f, 1.0f) * 0.90f * saturate(dark / A);
        t = clamp(t, 0.12f, 2.5f);
        c = max((c - A * (1.0f - t)) / t, 0.0f);
    }

    // (d) 블랙 포인트를 선형에서 뺀다 — 베일링 플레어(뿌연 안개)를 걷어낸다.
    //     이게 없으면 역광·실내 반사가 있는 장면이 통째로 희뿌옇게 나온다.
    float bp = P.blackPoint;
    float invBp = 1.0f / max(1.0f - bp, 1e-3f);
    c = max(c - bp, 0.0f) * invBp;

    // (e) 다중 스케일 분해. 마스크는 보정 전 로그 휘도라서 같은 변환을 따라 적용한다.
    float fineRaw = exp2(fineTex.sample(kLinear, uv).r) * P.wbLuma * gain;
    fineRaw = max(fineRaw - bp, 0.0f) * invBp;
    float logFine = log2(max(fineRaw, 1e-5f));

    float logCoarse = logFine;
    if (P.toneBands > 2.5f) {
        float coarseRaw = exp2(coarse.sample(kLinear, uv).r) * P.wbLuma * gain;
        coarseRaw = max(coarseRaw - bp, 0.0f) * invBp;
        logCoarse = log2(max(coarseRaw, 1e-5f));
    }

    float L = max(luma(c), 1e-5f);
    float bandMid = clamp(logFine - logCoarse, -5.0f, 5.0f);      // 중역 로컬 대비
    float bandFine = clamp(log2(L) - logFine, -6.0f, 6.0f);       // 미세 디테일

    // (f) 전역 톤은 coarse 에만 건다 → 로컬 대비가 통째로 보존된다.
    //     존 가중치는 로그 공간. z: -7EV→0, +1EV→1
    float z = saturate((logCoarse + 7.0f) / 8.0f);
    float hiMask = smoothstep(0.58f, 0.97f, z);
    float shMask = 1.0f - smoothstep(0.16f, 0.56f, z);
    float lb = logCoarse + P.highlights * 0.9f * hiMask + P.shadows * 0.85f * shMask;

    // (g) 대비 = 미드그레이(0.18) 기준 로그 기울기. 필름 감마와 같은 방식.
    lb = kPivotLog + (lb - kPivotLog) * exp2(P.contrast * 0.45f);

    // (h) 필름 숄더 — 장면의 실제 최대 휘도(white)를 1.0 으로 눕힌다.
    //     하이라이트가 잘리는 게 아니라 길게 누워서 '카메라처럼' 보인다.
    float baseDisp = filmicShoulder(float3(exp2(lb)), P.white).x;

    // (i) 밴드 재조립
    float Ld = clamp(baseDisp * exp2(bandMid * P.localGain + bandFine * P.detailGain),
                     0.0f, 1.0f);

    // (j) 색은 비율로 옮긴다 → 색상/채도가 틀어지지 않는다
    float3 outLin = c * (Ld / L);

    // (k) 아주 밝은 곳은 흰색으로 모은다 (형광등·창문이 색을 띠지 않게)
    float over = saturate((Ld - 0.82f) / 0.30f);
    outLin = mix(outLin, float3(Ld), over * 0.8f);

    // (l) 감마 인코딩 — 파이프라인 전체에서 딱 한 번
    float3 g = encodeGamma(outLin);

    // (m) 블랙 엔드포인트 (슬라이더)
    float blackLift = P.blacks * 0.18f;
    g = (blackLift >= 0.0f) ? (g * (1.0f - blackLift) + blackLift)
                            : max((g + blackLift) / (1.0f + blackLift), 0.0f);

    // (n) 색 분리 (스플릿 토닝) — 섀도우/하이라이트에 서로 다른 색을 얹는다
    float lum0 = dot(g, kLumaRec709);
    float pivot = 0.5f + P.splitBalance * 0.35f;
    float hiW = smoothstep(pivot - 0.32f, min(pivot + 0.42f, 1.0f), lum0);
    float shW = 1.0f - smoothstep(max(pivot - 0.45f, 0.0f), pivot + 0.28f, lum0);
    g += float3(P.splitShadowR, P.splitShadowG, P.splitShadowB) * shW;
    g += float3(P.splitHighR, P.splitHighG, P.splitHighB) * hiW;
    g = max(g, 0.0f);

    // (o) 채도 / 생동감
    float lum = dot(g, kLumaRec709);
    float mx = max(max(g.r, g.g), g.b);
    float mn = min(min(g.r, g.g), g.b);
    float sat = (mx - mn) / max(mx, 1e-4f);
    // 살색 보호: R ≥ G ≥ B 이면서 (G-B)/(R-B) 가 0.55 근처면 피부
    float skin = 0.0f;
    if (g.r >= g.g && g.g >= g.b && (g.r - g.b) > 0.02f) {
        float ratio = (g.g - g.b) / (g.r - g.b);
        skin = saturate(1.0f - 3.2f * abs(ratio - 0.55f));
    }
    skin *= clamp(P.skinProtect, 0.0f, 1.0f);
    float vib = P.vibrance * (1.0f - sat * sat) * (1.0f - 0.6f * skin);
    g = mix(float3(lum), g, clamp(1.0f + vib + P.saturation, 0.0f, 3.0f));

    dst.write(float4(clamp(g, 0.0f, 1.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  6. 디테일 — 언샤프 + 텍스처(소반경) + 클래리티(대반경), 경계 보호
// ---------------------------------------------------------------------------

kernel void detail(texture2d<float, access::sample> src     [[texture(0)]],
                   texture2d<float, access::sample> blurBig [[texture(1)]],  // 클래리티용 휘도 블러
                   texture2d<float, access::write>  dst     [[texture(2)]],
                   constant DetailParams& P                 [[buffer(0)]],
                   uint2 gid                                [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float3 c = src.sample(kLinear, uv).rgb;

    if (P.sharpness < 0.01f && abs(P.texture) < 0.01f && abs(P.clarity) < 0.01f) {
        dst.write(float4(c, 1), gid);
        return;
    }

    float r = max(P.radius, 0.5f);
    // 소반경 블러 (3x3 가우시안 근사, radius 로 간격 조절)
    float3 blurS = 0.0f;
    float wsum = 0.0f;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float wgt = (dx == 0 && dy == 0) ? 4.0f : ((dx == 0 || dy == 0) ? 2.0f : 1.0f);
            blurS += src.sample(kLinear, uv + float2(dx, dy) * r / size).rgb * wgt;
            wsum += wgt;
        }
    }
    blurS /= wsum;

    float L = luma(c);
    float3 highFreq = c - blurS;
    float hfL = luma(highFreq);

    // 경계 보호: 이미 강한 경계는 덜 깎아 할로를 막는다
    float edge = saturate(abs(hfL) * 14.0f);
    float protect = 1.0f - 0.55f * edge;
    // 하이라이트/섀도우 끝에서는 샤프닝 줄임
    float tonal = smoothstep(0.02f, 0.12f, L) * (1.0f - smoothstep(0.88f, 0.99f, L));

    float3 outC = c + highFreq * (P.sharpness * protect * tonal + P.texture * 0.7f);

    // 클래리티: 대반경 휘도 대비
    if (abs(P.clarity) > 0.01f) {
        float lb = blurBig.sample(kLinear, uv).r;
        float localContrast = L - lb;
        float mid = 1.0f - abs(L - 0.5f) * 1.6f;     // 중간톤에만
        outC += localContrast * P.clarity * max(mid, 0.0f) * 1.1f;
    }

    dst.write(float4(clamp(outC, 0.0f, 1.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  7. 보케 — 선형 HDR 에서 디스크 게더링
//     핵심 3가지:
//      · 샘플의 CoC 가 중심까지 닿을 때만 기여 (에너지 보존 디스크)
//      · 디스크 면적으로 나눠 밝은 점이 '퍼지지 않고 동그랗게' 남는다
//      · 가중치에 하이라이트 블룸을 곱해 보케 볼이 또렷해진다
// ---------------------------------------------------------------------------

kernel void bokeh_gather(texture2d<float, access::sample> src [[texture(0)]],  // 선형 HDR
                         texture2d<float, access::sample> coc [[texture(1)]],  // px, 부호 있음
                         texture2d<float, access::write>  dst [[texture(2)]],
                         constant BokehParams& P                [[buffer(0)]],
                         uint2 gid                              [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;

    float4 center = src.sample(kLinear, uv);
    float centerCoC = coc.sample(kLinear, uv).r;

    float R = P.maxRadius;
    if (R < 1.0f) { dst.write(center, gid); return; }

    // 고양이눈: 화면 가장자리에서 조리개가 잘린다
    float2 e = (uv - 0.5f) * 2.0f;
    float2 clipDir = (length(e) > 1e-4f) ? normalize(e) : float2(0.0f);
    float clipAmt = P.catsEye * clamp(length(e), 0.0f, 1.0f) * 0.85f;

    float3 acc = 0.0f;
    float wsum = 0.0f;
    int rings = int(max(P.rings, 1.0f));
    // 픽셀마다 샘플 각도를 돌려준다 — 링 수를 줄여도 줄무늬가 안 생긴다
    float jitter = hash12(float2(gid) * 1.7f + P.rotation) * 6.2831853f;

    for (int ri = 0; ri <= rings; ++ri) {
        float t = float(ri) / float(rings);
        int samples = (ri == 0) ? 1 : max(6, int(6.0f * float(ri)));
        for (int si = 0; si < samples; ++si) {
            float ang = 2.0f * M_PI_F * float(si) / float(samples) + jitter + float(ri) * 0.37f;
            float2 dir = float2(cos(ang), sin(ang));
            // 조리개 날 모양
            float shape = apertureRadius(ang, P.blades, P.curvature);
            float2 unitOffset = dir * shape * t;
            // 고양이눈: 중심에서 밀린 원과의 교집합 밖이면 버림
            if (clipAmt > 0.001f && length(unitOffset - clipDir * clipAmt) > 1.0f) continue;

            float2 off = unitOffset * R;
            float2 suv = uv + off / size;
            float sCoC = coc.sample(kLinear, suv).r;
            float sAbs = abs(sCoC);
            float dist = length(off);

            // 이 샘플의 블러 디스크가 중심 픽셀까지 닿는가
            float cover = saturate((sAbs - dist) * 0.5f + 0.5f);
            if (cover <= 0.001f) continue;

            // 오클루전: 초점이 맞은 피사체 위로 배경이 번지지 않게
            if (sCoC > 0.0f && centerCoC < sCoC - 2.0f) {
                cover *= saturate(1.0f - (sCoC - max(centerCoC, 0.0f)) / max(sAbs, 1.0f));
            }

            float3 s = src.sample(kLinear, suv).rgb;

            // 디스크 면적 정규화 — 에너지 보존
            float area = max(sAbs * sAbs, 1.0f);
            float wgt = cover / area;

            // 구면수차: 디스크 가장자리를 강조해 링 보케
            float edgeT = (sAbs > 1e-3f) ? saturate(dist / sAbs) : 0.0f;
            wgt *= 1.0f + P.ring * 2.2f * edgeT * edgeT;

            // 하이라이트 블룸 — 선형에서 밝은 값일수록 크게
            float sl = luma(s);
            wgt *= 1.0f + P.bloom * smoothstep(0.75f, 3.0f, sl) * 3.0f;

            acc += s * wgt;
            wsum += wgt;
        }
    }

    float3 result = (wsum > 1e-6f) ? (acc / wsum) : center.rgb;
    dst.write(float4(result, 1), gid);
}

// 보케 결과(저해상)를 선명한 원본과 CoC 로 합성
kernel void bokeh_composite(texture2d<float, access::sample> sharp  [[texture(0)]],
                            texture2d<float, access::sample> blurred[[texture(1)]],
                            texture2d<float, access::sample> coc    [[texture(2)]],
                            texture2d<float, access::write>  dst    [[texture(3)]],
                            uint2 gid                               [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float3 a = sharp.sample(kLinear, uv).rgb;
    float3 b = blurred.sample(kLinear, uv).rgb;
    float c = abs(coc.sample(kLinear, uv).r);
    // CoC 1px 미만은 선명하게, 3px 이상은 완전히 블러
    float t = smoothstep(0.8f, 3.0f, c);
    dst.write(float4(mix(a, b, t), 1), gid);
}

// ---------------------------------------------------------------------------
//  8. 마무리 — 색수차, 비네팅, 그레인 (디스플레이 공간)
// ---------------------------------------------------------------------------

kernel void finish(texture2d<float, access::sample> src [[texture(0)]],
                   texture2d<float, access::write>  dst [[texture(1)]],
                   constant FinishParams& P             [[buffer(0)]],
                   uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 e = (uv - 0.5f) * 2.0f;
    float rad = length(e);

    float3 c;
    if (P.chroma > 0.001f) {
        // 배율 색수차: R/B 를 중심에서 반대로 밀어 가장자리 색번짐
        float k = P.chroma * 0.0022f * rad * rad;
        c.r = src.sample(kLinear, 0.5f + (uv - 0.5f) * (1.0f + k)).r;
        c.g = src.sample(kLinear, uv).g;
        c.b = src.sample(kLinear, 0.5f + (uv - 0.5f) * (1.0f - k)).b;
    } else {
        c = src.sample(kLinear, uv).rgb;
    }

    // 코마 수차 — 주변부에서 점광원이 방사 방향으로 번진다 (밝은 렌즈의 실제 특성).
    // 중심은 전혀 건드리지 않고 r^3 로 커진다.
    if (P.coma > 0.001f && rad > 0.25f) {
        float amount = P.coma * pow(saturate((rad - 0.25f) / 0.75f), 3.0f);
        float2 dir = (rad > 1e-4f) ? (e / rad) : float2(0.0f);
        float3 smear = 0.0f;
        for (int i = 1; i <= 4; ++i) {
            float t = float(i) / 4.0f;
            smear += src.sample(kLinear, uv + dir * (t * amount * 0.016f)).rgb;
        }
        c = mix(c, smear * 0.25f, saturate(amount * 0.8f));
    }

    // 비네팅 (부드러운 코사인 4제곱 느낌)
    if (abs(P.vignette) > 0.001f) {
        // 라이트룸과 같은 부호: 음수 = 네 귀퉁이가 어두워진다
        float v = 1.0f + P.vignette * 0.9f * smoothstep(0.25f, 1.35f, rad);
        c *= clamp(v, 0.0f, 2.0f);
    }

    // 그레인 — 중간톤에 가장 많이, 밝은 곳은 적게 (필름처럼)
    if (P.grain > 0.001f) {
        float2 gp = floor(float2(gid) / max(P.grainSize, 0.5f)) + P.seed;
        float n = hash12(gp) - 0.5f;
        float L = dot(c, kLumaRec709);
        float weight = 1.0f - abs(L - 0.42f) * 1.5f;
        c += n * P.grain * 0.16f * max(weight, 0.12f);
    }

    dst.write(float4(clamp(c, 0.0f, 1.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  유틸: 박스 다운샘플. ratio 만큼 줄일 때 그에 맞는 넓이로 평균 낸다.
//  (48MP 에서 풀해상도 중간 버퍼를 만들지 않기 위해 한 번에 1/4, 1/8 로 줄인다)
// ---------------------------------------------------------------------------

kernel void downsample_box(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           constant float& ratio                [[buffer(0)]],
                           uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;

    int taps = int(clamp(ratio, 1.0f, 4.0f));           // 1/2 → 2탭, 1/4 → 4탭
    float4 acc = 0.0f;
    float span = 1.0f / float(taps);
    for (int y = 0; y < taps; ++y) {
        for (int x = 0; x < taps; ++x) {
            float2 o = (float2(x, y) + 0.5f) * span - 0.5f;  // -0.5 ... 0.5 (dst 텍셀 기준)
            acc += src.sample(kLinear, uv + o / size);
        }
    }
    dst.write(acc / float(taps * taps), gid);
}

// CoC 다운샘플은 '절대값이 큰 쪽'을 살려야 블러가 끊기지 않는다.
// scale 로 픽셀 단위를 목표 해상도에 맞춰 환산한다.
kernel void downsample_coc(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           constant float& scale                [[buffer(0)]],
                           uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float2 texel = 0.5f / size;
    float best = 0.0f;
    for (int dy = -1; dy <= 1; dy += 2) {
        for (int dx = -1; dx <= 1; dx += 2) {
            float v = src.sample(kLinear, uv + float2(float(dx) * texel.x, float(dy) * texel.y)).r;
            if (abs(v) > abs(best)) best = v;
        }
    }
    dst.write(float4(best * scale, 0, 0, 1), gid);
}

// 톤 매핑용 '로그2 휘도' 축소. 선형 평균이 아니라 로그 평균을 내야
// 밝은 점 하나가 타일 전체를 끌어올리지 않는다.
kernel void log_downsample(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           constant float& ratio                [[buffer(0)]],
                           uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int taps = int(clamp(ratio, 1.0f, 4.0f));
    float acc = 0.0f;
    float span = 1.0f / float(taps);
    for (int y = 0; y < taps; ++y) {
        for (int x = 0; x < taps; ++x) {
            float2 o = (float2(x, y) + 0.5f) * span - 0.5f;
            float L = luma(src.sample(kLinear, uv + o / size).rgb);
            acc += log2(max(L, 1e-5f));
        }
    }
    dst.write(float4(acc / float(taps * taps), 0, 0, 1), gid);
}

// 장면 분석용: 넓게 층화 샘플링한 로그 휘도 (CPU 가 읽어 히스토그램을 만든다)
kernel void analyze_luma(texture2d<float, access::sample> src [[texture(0)]],
                         texture2d<float, access::write>  dst [[texture(1)]],
                         uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 base = float2(gid) / size;
    float2 cell = 1.0f / size;
    float acc = 0.0f;
    for (int y = 0; y < 3; ++y) {
        for (int x = 0; x < 3; ++x) {
            float2 uv = base + (float2(x, y) + 0.5f) / 3.0f * cell;
            float L = luma(src.sample(kLinear, uv).rgb);
            acc += log2(max(L, 1e-5f));
        }
    }
    dst.write(float4(acc / 9.0f, 0, 0, 1), gid);
}

// 저해상 휘도 마스크 만들기 (풀해상도 중간 버퍼 없이 바로 축소 + 휘도화)
kernel void luma_downsample(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            constant float& ratio                [[buffer(0)]],
                            uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int taps = int(clamp(ratio, 1.0f, 4.0f));
    float acc = 0.0f;
    float span = 1.0f / float(taps);
    for (int y = 0; y < taps; ++y) {
        for (int x = 0; x < taps; ++x) {
            float2 o = (float2(x, y) + 0.5f) * span - 0.5f;
            acc += luma(src.sample(kLinear, uv + o / size).rgb);
        }
    }
    dst.write(float4(acc / float(taps * taps), 0, 0, 1), gid);
}
