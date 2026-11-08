#include "Common.h"

// ============================================================================
//  ChanCam 고급 현상 — 레이트레이싱 피사계심도 · 광원 추적 · 신경망 디테일
//
//  여기 있는 단계들은 "흐림 흉내"가 아니라 실제 광학을 푼다.
//   · dof_march      : 조리개 위의 점에서 센서 픽셀로 가는 광선을 깊이 버퍼에
//                      대고 레이 마칭해서 교차점을 찾는다 → 가려짐이 공짜로 맞는다
//   · scatter_splat  : 점광원의 에너지를 조리개 모양대로 실제로 흩뿌린다 (보케 볼)
//   · flare_render   : 광원이 렌즈 안에서 반사·회절되며 만드는 고스트/스파이크를
//                      광원 위치에서 추적해 선형 HDR 로 더한다
//   · neural_*       : 3층 합성곱 블록 (방향 선택성 → 분할 정규화 → 재결합)
// ============================================================================


// ---------------------------------------------------------------------------
//  0. 복사 — 파이프라인 분기 정리용
// ---------------------------------------------------------------------------

kernel void blit(texture2d<float, access::read>  src [[texture(0)]],
                 texture2d<float, access::write> dst [[texture(1)]],
                 uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid), gid);
}

/// private 텍스처는 초기값이 보장되지 않는다. 누산 전에 0 으로 채운다.
kernel void zero_fill(texture2d<float, access::write> dst [[texture(0)]],
                      uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(0), gid);
}

// ---------------------------------------------------------------------------
//  0.5 깊이 구멍 메우기 (push-pull)
//
//  LiDAR 는 5m 쯤 넘어가면 아무것도 못 읽는다. 하늘, 먼 나무, 유리, 젖은 아스팔트
//  전부 0 으로 온다. 거리 화면이라면 화면의 절반 이상이 구멍이다.
//  유효한 값만 가중 평균하며 피라미드를 올리고(pull), 내려오면서 구멍만
//  부모 값으로 메운다(push). 영상 기반 렌더링의 표준 기법이고, 가장자리를
//  뭉개지 않으면서 빈 곳을 '주변이 말하는 거리'로 채운다.
// ---------------------------------------------------------------------------

/// r32f 깊이 → rg16f (깊이×가중치, 가중치)
kernel void depth_pack(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid                           [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float d = src.read(gid).r;
    bool ok = d > 0.02f && d < 300.0f;
    dst.write(float4(ok ? d : 0.0f, ok ? 1.0f : 0.0f, 0, 1), gid);
}

/// 2x2 를 모아 올린다 (유효한 것만)
kernel void depth_pull(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid                           [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    uint sw = src.get_width(), sh = src.get_height();
    float2 acc = 0.0f;
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            uint2 p = uint2(min(gid.x * 2 + dx, sw - 1), min(gid.y * 2 + dy, sh - 1));
            acc += src.read(p).rg;
        }
    }
    dst.write(float4(acc.x, acc.y, 0, 1), gid);
}

/// 내려오면서 구멍만 부모 값으로 메운다
kernel void depth_push(texture2d<float, access::read>   fine   [[texture(0)]],
                       texture2d<float, access::sample> coarse [[texture(1)]],
                       texture2d<float, access::write>  dst    [[texture(2)]],
                       uint2 gid                                [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 here = fine.read(gid).rg;
    if (here.y > 0.001f) { dst.write(float4(here.x, here.y, 0, 1), gid); return; }
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float2 up = coarse.sample(kLinear, uv).rg;
    if (up.y > 0.001f) {
        // 부모의 평균 깊이를 가중치 1 로 내려받는다
        dst.write(float4(up.x / up.y, 1.0f, 0, 1), gid);
    } else {
        dst.write(float4(0, 0, 0, 1), gid);
    }
}

/// 착란원 경계를 이미지 가장자리에 맞춰 다듬는다 (가이드 바이래터럴, 분리형).
///
/// 깊이맵은 이미지보다 훨씬 거칠어서 그대로 쓰면 능선 같은 데서 계단이 보인다.
/// 밝기가 비슷한 쪽끼리만 섞으면 계단은 사라지고 진짜 경계는 남는다.
inline float cocGuidedLine(texture2d<float, access::sample> coc,
                           texture2d<float, access::sample> guide,
                           float2 uv, float2 step, int radius)
{
    float centerC = coc.sample(kLinear, uv).r;
    float centerL = luma(guide.sample(kLinear, uv).rgb);
    float acc = centerC, wsum = 1.0f;
    float sigma2 = 0.35f * float(radius * radius) + 1.0f;
    for (int i = 1; i <= radius; ++i) {
        float spatial = exp(-0.5f * float(i * i) / sigma2);
        for (int s = -1; s <= 1; s += 2) {
            float2 suv = uv + step * float(i * s);
            float v = coc.sample(kLinear, suv).r;
            float sl = luma(guide.sample(kLinear, suv).rgb);
            float dl = (sl - centerL) / 0.16f;
            float wgt = spatial * exp(-0.5f * dl * dl);
            acc += v * wgt;
            wsum += wgt;
        }
    }
    return acc / max(wsum, 1e-5f);
}

kernel void coc_guided_h(texture2d<float, access::sample> coc   [[texture(0)]],
                         texture2d<float, access::sample> guide [[texture(1)]],
                         texture2d<float, access::write>  dst   [[texture(2)]],
                         constant float& radius                  [[buffer(0)]],
                         uint2 gid                               [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(radius, 1.0f, 12.0f));
    float v = cocGuidedLine(coc, guide, uv, float2(1.0f / size.x, 0.0f), r);
    dst.write(float4(v, 0, 0, 1), gid);
}

kernel void coc_guided_v(texture2d<float, access::sample> coc   [[texture(0)]],
                         texture2d<float, access::sample> guide [[texture(1)]],
                         texture2d<float, access::write>  dst   [[texture(2)]],
                         constant float& radius                  [[buffer(0)]],
                         uint2 gid                               [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(radius, 1.0f, 12.0f));
    float v = cocGuidedLine(coc, guide, uv, float2(0.0f, 1.0f / size.y), r);
    dst.write(float4(v, 0, 0, 1), gid);
}

/// rg16f → r32f 깊이. 끝까지 못 메운 곳은 '아주 먼 곳'으로 둔다.
kernel void depth_unpack(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float& farDistance          [[buffer(0)]],
                         uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 v = src.read(gid).rg;
    float d = (v.y > 0.001f) ? (v.x / v.y) : farDistance;
    dst.write(float4(max(d, 0.02f), 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
//  1. 복사량 분리 (split radiance estimator)
//
//  밝은 점 하나를 레이 마칭으로 적분하면 샘플이 운 좋게 그 픽셀을 맞출 때만
//  기여해서 보케 볼이 얼룩덜룩해진다. 그래서 임계 위의 에너지는 떼어내
//  따로 '흩뿌려서'(scatter) 정확히 적분한다. 두 결과를 더하면 편향이 없다.
// ---------------------------------------------------------------------------

kernel void split_radiance(texture2d<float, access::read>  src       [[texture(0)]],
                           texture2d<float, access::write> diffuse   [[texture(1)]],
                           texture2d<float, access::write> highlight [[texture(2)]],
                           constant float& threshold                  [[buffer(0)]],
                           uint2 gid                                  [[thread_position_in_grid]])
{
    uint w = diffuse.get_width(), h = diffuse.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float3 c = max(src.read(gid).rgb, 0.0f);
    float L = luma(c);
    float T = max(threshold, 1e-3f);
    float s = (L > T) ? (T / L) : 1.0f;
    float3 d = c * s;
    diffuse.write(float4(d, 1), gid);
    highlight.write(float4(max(c - d, 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  2. 레이트레이싱 피사계심도
//
//  얇은 렌즈에서, 조리개 위의 상대 좌표 a (단위원) 를 지나 센서 픽셀 p 로
//  오는 광선은 착란원 반경 c 를 가지는 깊이의 면과 화면상 p + a·c/2 에서 만난다.
//  그래서 c 를 -R(전경) → +R(배경) 으로 훑으면서 그 위치의 실제 착란원이
//  가정값과 같아지는 지점을 찾으면 그게 광선-장면 교차점이다.
//  먼저 만난 면이 뒤를 가린다 → 게더 방식이 절대 못 하는 올바른 가려짐.
// ---------------------------------------------------------------------------

kernel void dof_march(texture2d<float, access::sample> src    [[texture(0)]],  // 선형 디퓨즈
                      texture2d<float, access::sample> coc    [[texture(1)]],  // px, 부호 있음
                      texture2d<float, access::read>   accIn  [[texture(2)]],
                      texture2d<float, access::write>  accOut [[texture(3)]],
                      constant MarchParams& P                  [[buffer(0)]],
                      uint2 gid                                [[thread_position_in_grid]])
{
    uint w = accOut.get_width(), h = accOut.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;

    float4 acc = accIn.read(gid);
    float R = P.maxRadius;
    float3 center = src.sample(kLinear, uv).rgb;

    if (R < 1.0f) {
        accOut.write(float4(acc.rgb + center, acc.a + 1.0f), gid);
        return;
    }

    // 주변이 전부 초점 안이면 레이를 쏠 필요가 없다 (큰 평면 영역에서 큰 절약)
    float centerCoC = coc.sample(kLinear, uv).r;
    {
        float probe = abs(centerCoC);
        float2 step = R / size;
        probe = max(probe, abs(coc.sample(kLinear, uv + float2( step.x, 0)).r));
        probe = max(probe, abs(coc.sample(kLinear, uv + float2(-step.x, 0)).r));
        probe = max(probe, abs(coc.sample(kLinear, uv + float2(0,  step.y)).r));
        probe = max(probe, abs(coc.sample(kLinear, uv + float2(0, -step.y)).r));
        probe = max(probe, abs(coc.sample(kLinear, uv + step * 0.7071f).r));
        probe = max(probe, abs(coc.sample(kLinear, uv - step * 0.7071f).r));
        if (probe < 0.9f) {
            accOut.write(float4(acc.rgb + center * P.samples, acc.a + P.samples), gid);
            return;
        }
    }

    // 고양이눈 — 화면 가장자리에서 조리개가 경통에 잘린다 (기계적 비네팅)
    float2 e = (uv - 0.5f) * 2.0f;
    float eLen = length(e);
    float2 clipDir = (eLen > 1e-4f) ? (e / eLen) : float2(0.0f);
    float clipAmt = P.catsEye * clamp(eLen, 0.0f, 1.0f) * 0.85f;

    float jitter = hash12(float2(gid) * 1.7f + P.sampleOffset * 0.013f);
    int n = int(max(P.samples, 1.0f));
    int steps = int(clamp(P.steps, 4.0f, 64.0f));
    float stepSize = 2.0f * R / float(steps);
    float ca = P.caScale;

    float3 sum = 0.0f;
    float wsum = 0.0f;

    for (int i = 0; i < n; ++i) {
        float idx = P.sampleOffset + float(i);

        // 조리개 위 샘플 — 황금각 나선에 픽셀별 지터. 패스가 쌓일수록 균일해진다.
        float u = fract((idx + jitter) / max(P.totalSamples, 1.0f));
        float rad = sqrt(saturate(u));
        float ang = idx * 2.39996323f + jitter * 6.2831853f + P.rotation;
        float shape = apertureRadius(ang, P.blades, P.curvature);
        float2 a = float2(cos(ang), sin(ang)) * rad * shape;

        if (clipAmt > 0.001f && length(a - clipDir * clipAmt) > 1.0f) continue;

        // 조리개 투과율: 아포다이제이션(STF 렌즈처럼 가장자리를 죽임) + 구면수차(링)
        float wgt = (1.0f - P.apodization * rad * rad) * (1.0f + P.ring * 1.8f * rad * rad);
        if (wgt <= 1e-4f) continue;

        // --- 레이 마칭: 전경 → 배경 ---
        float cHit = R;
        bool found = false;
        float prevDiff = 0.0f;
        for (int s = 0; s <= steps; ++s) {
            float c = -R + stepSize * float(s);
            float2 q = uv + a * (c * 0.5f) / size;
            float cq = coc.sample(kLinear, q).r;
            float diff = cq - c;
            if (s > 0 && ((diff <= 0.0f) != (prevDiff <= 0.0f))) {
                float t = prevDiff / max(prevDiff - diff, 1e-5f);
                cHit = (-R + stepSize * float(s - 1)) + stepSize * clamp(t, 0.0f, 1.0f);
                found = true;
                break;
            }
            prevDiff = diff;
        }
        if (!found) cHit = R;              // 광선이 빠져나갔다 = 가장 먼 배경

        float2 qh = uv + a * (cHit * 0.5f) / size;
        float3 col;
        if (ca > 0.001f) {
            // 종방향 색수차 — 파장별로 초점면이 다르다 (빨강이 뒤, 파랑이 앞)
            col.r = src.sample(kLinear, uv + a * (cHit * (1.0f + ca) * 0.5f) / size).r;
            col.g = src.sample(kLinear, qh).g;
            col.b = src.sample(kLinear, uv + a * (cHit * (1.0f - ca) * 0.5f) / size).b;
        } else {
            col = src.sample(kLinear, qh).rgb;
        }

        sum += max(col, 0.0f) * wgt;
        wsum += wgt;
    }

    accOut.write(float4(acc.rgb + sum, acc.a + wsum), gid);
}

kernel void dof_resolve(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::read>   acc [[texture(1)]],
                        texture2d<float, access::write>  dst [[texture(2)]],
                        uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 a = acc.read(gid);
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float3 out = (a.a > 1e-4f) ? (a.rgb / a.a) : src.sample(kLinear, uv).rgb;
    dst.write(float4(max(out, 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  3. 하이라이트 산란 (scatter) — 진짜 보케 볼
//
//  점광원의 복사량을 조리개 모양 디스크 전체에 '면적으로 나눠' 더한다.
//  균일한 밝은 면이면 받는 쪽에서 다시 합쳐져 원래 밝기가 되고(에너지 보존),
//  점광원이면 또렷한 조리개 모양 원반이 남는다. 32비트 정수 원자 덧셈을 쓴다.
// ---------------------------------------------------------------------------

#define kFixedScale 1024.0f

kernel void scatter_clear(device uint* bins       [[buffer(1)]],
                          constant ScatterParams& P [[buffer(0)]],
                          uint2 gid               [[thread_position_in_grid]])
{
    uint w = uint(P.width), h = uint(P.height);
    if (gid.x >= w || gid.y >= h) return;
    uint base = (gid.y * w + gid.x) * 3u;
    bins[base + 0u] = 0u;
    bins[base + 1u] = 0u;
    bins[base + 2u] = 0u;
}

kernel void scatter_splat(texture2d<float, access::read>   highlight [[texture(0)]],
                          texture2d<float, access::sample> coc       [[texture(1)]],
                          constant ScatterParams& P                   [[buffer(0)]],
                          device atomic_uint* bins                    [[buffer(1)]],
                          uint2 gid                                   [[thread_position_in_grid]])
{
    uint w = uint(P.width), h = uint(P.height);
    if (gid.x >= w || gid.y >= h) return;

    float3 energy = max(highlight.read(gid).rgb, 0.0f) * P.gain;
    if (luma(energy) < 1e-4f) return;

    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float c = coc.sample(kLinear, uv).r;
    float r = min(abs(c) * 0.5f, P.maxRadius * 0.5f);

    // 초점이 맞은 하이라이트는 흩뿌리지 않고 제자리에 둔다
    if (r < 1.0f) {
        uint base = (gid.y * w + gid.x) * 3u;
        for (uint k = 0; k < 3u; ++k) {
            uint v = uint(clamp(energy[k] * kFixedScale, 0.0f, 4.0e6f));
            if (v > 0u) atomic_fetch_add_explicit(&bins[base + k], v, memory_order_relaxed);
        }
        return;
    }

    int ir = int(ceil(r));
    int stride = max(1, (2 * ir + 1) / 19);          // 디스크당 최대 ~19x19 탭
    float cell = float(stride * stride);
    // 디스크 면적으로 나눈다 → 에너지 보존
    float area = max(M_PI_F * r * r, 1.0f);
    float3 perTap = energy * (cell / area);

    // 고양이눈
    float2 e = (uv - 0.5f) * 2.0f;
    float eLen = length(e);
    float2 clipDir = (eLen > 1e-4f) ? (e / eLen) : float2(0.0f);
    float clipAmt = P.catsEye * clamp(eLen, 0.0f, 1.0f) * 0.85f;

    int cx = int(gid.x), cy = int(gid.y);
    for (int dy = -ir; dy <= ir; dy += stride) {
        for (int dx = -ir; dx <= ir; dx += stride) {
            float2 d = float2(dx, dy) / r;           // 단위 디스크 좌표
            float dl = length(d);
            if (dl > 1.0f) continue;
            float shape = apertureRadius(atan2(d.y, d.x) + P.rotation, P.blades, P.curvature);
            if (dl > shape) continue;
            if (clipAmt > 0.001f && length(d - clipDir * clipAmt) > 1.0f) continue;

            int px = cx + dx, py = cy + dy;
            if (px < 0 || py < 0 || px >= int(w) || py >= int(h)) continue;

            // 투과율: 아포다이제이션 + 구면수차 링 + 가장자리 소프트
            float t = dl / max(shape, 1e-3f);
            float wgt = (1.0f - P.apodization * t * t) * (1.0f + P.ring * 1.8f * t * t);
            wgt *= 1.0f - smoothstep(0.90f, 1.0f, t);
            if (wgt <= 1e-4f) continue;

            uint base = (uint(py) * w + uint(px)) * 3u;
            for (uint k = 0; k < 3u; ++k) {
                uint v = uint(clamp(perTap[k] * wgt * kFixedScale, 0.0f, 4.0e6f));
                if (v > 0u) atomic_fetch_add_explicit(&bins[base + k], v, memory_order_relaxed);
            }
        }
    }
}

kernel void scatter_resolve(texture2d<float, access::read>  src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant ScatterParams& P            [[buffer(0)]],
                            device const uint* bins              [[buffer(1)]],
                            uint2 gid                            [[thread_position_in_grid]])
{
    uint w = uint(P.width), h = uint(P.height);
    if (gid.x >= w || gid.y >= h) return;
    uint base = (gid.y * w + gid.x) * 3u;
    float3 add = float3(float(bins[base + 0u]), float(bins[base + 1u]), float(bins[base + 2u]))
               / kFixedScale;
    dst.write(float4(max(src.read(gid).rgb + add, 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  4. 광원 찾기 — 타일마다 가장 밝은 점과 그 위치/색을 적어 CPU 로 넘긴다
// ---------------------------------------------------------------------------

kernel void light_scan(texture2d<float, access::sample> src   [[texture(0)]],
                       texture2d<float, access::write>  color [[texture(1)]],  // rgb + luma
                       texture2d<float, access::write>  place [[texture(2)]],  // u, v
                       uint2 gid                              [[thread_position_in_grid]])
{
    uint w = color.get_width(), h = color.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 tiles = float2(w, h);
    float2 origin = float2(gid) / tiles;
    float2 cell = 1.0f / tiles;

    float best = -1.0f;
    float3 bestColor = 0.0f;
    float2 bestUV = origin + cell * 0.5f;
    const int N = 6;
    for (int y = 0; y < N; ++y) {
        for (int x = 0; x < N; ++x) {
            float2 uv = origin + (float2(x, y) + 0.5f) / float(N) * cell;
            float3 c = max(src.sample(kLinear, uv).rgb, 0.0f);
            float L = luma(c);
            if (L > best) { best = L; bestColor = c; bestUV = uv; }
        }
    }
    color.write(float4(bestColor, best), gid);
    place.write(float4(bestUV, 0, 0), gid);
}

// ---------------------------------------------------------------------------
//  5. 광원 추적 — 고스트 · 헤일로 · 베일링 글레어 · 회절 스파이크
//
//  경통 안에서 광원의 빛은 렌즈 면 쌍 사이를 왕복 반사하며 '고스트'를 만든다.
//  고스트는 언제나 광원과 화면 중심을 잇는 직선 위에 생기고, 반사한 면 쌍에
//  따라 중심에서의 배율이 달라진다 (Hullin 2011 의 단순화된 파라메트릭 모델).
//  회절 스파이크 수는 조리개 날이 짝수면 날 수, 홀수면 날 수의 두 배다.
//  전부 톤매핑 '전' 선형 HDR 에 더해서, 숄더가 자연스럽게 받아주게 한다.
// ---------------------------------------------------------------------------

constant float kGhostOffsets[8] = {
    -0.62f, 0.28f, -0.21f, 0.46f, 0.82f, -1.08f, 1.34f, -1.72f
};
constant float3 kGhostTints[8] = {
    float3(0.72f, 0.88f, 1.00f),   // 멀티코팅은 보통 청록으로 반사한다
    float3(1.00f, 0.82f, 0.62f),
    float3(0.78f, 1.00f, 0.86f),
    float3(1.00f, 0.70f, 0.82f),
    float3(0.86f, 0.90f, 1.00f),
    float3(1.00f, 0.94f, 0.72f),
    float3(0.74f, 0.92f, 1.00f),
    float3(0.96f, 0.78f, 1.00f),
};

kernel void flare_render(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant FlareParams& P              [[buffer(0)]],
                         device const LightSource* lights     [[buffer(1)]],
                         uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    float3 base = max(src.read(gid).rgb, 0.0f);

    int count = int(clamp(P.count, 0.0f, 8.0f));
    if (count == 0) { dst.write(float4(base, 1), gid); return; }

    // 화면비를 보정한 등방 좌표계에서 계산한다
    float aspect = max(P.aspect, 1e-3f);
    float2 p = float2((uv.x - 0.5f) * aspect, uv.y - 0.5f);

    // 조리개를 조이면 회절이 강해진다 (f/16 에서 별빛이 뾰족해지는 그 이유)
    float stopFactor = clamp(P.fNumber / 5.6f, 0.25f, 3.0f);
    int spikes = max(int(P.spikes), 2);

    float3 add = 0.0f;

    for (int i = 0; i < count; ++i) {
        LightSource L = lights[i];
        float2 s = float2((L.u - 0.5f) * aspect, L.v - 0.5f);
        float I = L.intensity;
        if (I <= 0.001f) continue;
        float3 tint = normalize(max(float3(L.r, L.g, L.b), 1e-4f)) * 1.7320508f;  // 색만 남긴다
        float sLen = length(s);
        float2 d = p - s;
        float dist = length(d);

        // (a) 베일링 글레어 — 산란광의 넓은 꼬리. 1/r^2 에 가깝다.
        if (P.glareStrength > 0.001f) {
            float g = 1.0f / (1.0f + 950.0f * dist * dist);
            add += tint * (I * P.glareStrength * 0.040f * g);
        }

        // (b) 회절 스파이크 — 조리개 날의 프라운호퍼 회절
        if (P.spikeStrength > 0.001f && dist > 1e-4f) {
            float ang = atan2(d.y, d.x) - P.rotation;
            float lobe = pow(abs(cos(float(spikes) * 0.5f * ang)), 48.0f);
            float reach = 0.09f * sqrt(max(I, 0.0f)) * stopFactor;
            float fall = exp(-dist / max(reach, 1e-3f));
            add += tint * (I * P.spikeStrength * 0.055f * lobe * fall * stopFactor);
        }

        // (c) 헤일로 — 광원과 중심 사이 거리에 비례하는 고리
        if (P.haloStrength > 0.001f && sLen > 0.02f) {
            float ringR = sLen * 0.72f;
            float dr = abs(length(p) - ringR);
            float ring = exp(-dr * dr / (2.0f * 0.0024f));
            // 광원 반대쪽이 더 밝다
            float side = 0.5f - 0.5f * dot(normalize(p + 1e-5f), normalize(s + 1e-5f));
            add += tint * (I * P.haloStrength * 0.030f * ring * (0.35f + side));
        }

        // (d) 고스트 — 광원–중심 축 위의 조리개 모양 상
        int ghosts = int(clamp(P.ghosts, 0.0f, 8.0f));
        for (int k = 0; k < ghosts; ++k) {
            float gk = kGhostOffsets[k];
            float2 c = s * gk;
            float radius = L.radius * aspect * (0.55f + 1.9f * abs(gk)) + 0.012f * abs(gk);
            float2 q = (p - c) / max(radius, 1e-4f);
            float m = apertureMask(q, P.blades, P.curvature, 0.22f);
            if (m <= 0.001f) continue;
            // 가장자리가 살짝 밝은 고스트 특유의 링
            float rr = length(q);
            float rim = 1.0f + 0.9f * smoothstep(0.55f, 0.98f, rr);
            float fall = 1.0f / (1.0f + 2.6f * abs(gk));
            add += kGhostTints[k] * tint
                 * (I * P.ghostStrength * 0.028f * m * rim * fall / max(radius * 24.0f, 0.25f));
        }
    }

    dst.write(float4(max(base + add, 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  6. 신경망 디테일 블록 (3층 합성곱)
//
//  층1  방향 선택 합성곱 — 8개 필터 (1차 미분 4방향, 2차 미분 3개, 라플라시안)
//  층2  비선형 — 크기 게이트 + 분할 정규화. 실제 학습된 망의 1~2층이 늘
//       만들어내는 바로 그 연산이다. 등방(=노이즈) 응답은 억제되고
//       방향이 뚜렷한(=경계) 응답만 살아남는다.
//  층3  재결합 — 살아남은 응답을 휘도 잔차로 되돌린다.
//
//  가중치는 학습한 게 아니라 조향 가능 기저(steerable basis)로 해석적으로
//  정한 것이다. 그래서 결과가 항상 같고, 모델 파일이 없고, 아주 빠르다.
//  스케일 1/1 · 1/2 · 1/4 세 번 돌려 주파수대별로 따로 판단한다.
// ---------------------------------------------------------------------------

/// 한 픽셀의 3x3 휘도 패치에서 잔차(휘도 델타)를 계산한다
inline float neuralResidual(texture2d<float, access::sample> src, float2 uv, float2 size,
                            constant NeuralParams& P)
{
    float2 t = 1.0f / size;
    float p[9];
    int idx = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            p[idx++] = luma(src.sample(kLinear, uv + float2(dx, dy) * t).rgb);
        }
    }
    float c = p[4];

    // --- 층1: 방향 선택 합성곱 ---
    float d0   = ((p[2] + 2.0f * p[5] + p[8]) - (p[0] + 2.0f * p[3] + p[6])) * 0.25f;
    float d90  = ((p[6] + 2.0f * p[7] + p[8]) - (p[0] + 2.0f * p[1] + p[2])) * 0.25f;
    float d45  = ((p[1] + 2.0f * p[2] + p[5]) - (p[3] + 2.0f * p[6] + p[7])) * 0.25f;
    float d135 = ((p[1] + 2.0f * p[0] + p[3]) - (p[5] + 2.0f * p[8] + p[7])) * 0.25f;
    float dxx  = (p[3] - 2.0f * c + p[5]) * 0.5f;
    float dyy  = (p[1] - 2.0f * c + p[7]) * 0.5f;
    float dxy  = ((p[0] + p[8]) - (p[2] + p[6])) * 0.25f;
    float lap  = ((p[1] + p[3] + p[5] + p[7]) - 4.0f * c) * 0.25f;

    float r[8] = { d0, d90, d45, d135, dxx, dyy, dxy, lap };

    // --- 층2: 비선형 (크기 게이트 + 분할 정규화) ---
    float total = 0.0f, peak = 0.0f;
    for (int k = 0; k < 8; ++k) {
        float a = abs(r[k]);
        total += a;
        peak = max(peak, a);
    }
    float tau = max(P.threshold, 1e-5f);

    // 일관성: 가장 강한 방향이 전체 응답에서 차지하는 비중.
    // 0.125 = 완전 등방(센서 노이즈), 1.0 = 한 방향뿐(깨끗한 경계)
    float coherence = peak / max(total, 1e-6f);
    float orient = saturate((coherence - 0.17f) / 0.26f);
    // 신호가 노이즈 바닥보다 얼마나 위인지
    float level = saturate(peak / tau - 1.0f);
    float gate = level * level / (level * level + 0.25f);

    // 분할 정규화 — 주변 방향들이 같이 크면 이 응답을 깎는다
    float inhib = 1.0f / (1.0f + P.inhibition * (total - peak) / max(peak, 1e-6f));

    // --- 층3: 재결합 ---
    // (1) 디테일 복원: 일관되고 노이즈 위인 구조만 선명하게
    float restore = -lap * P.strength * (0.30f + 0.70f * orient) * gate * inhib;
    // (2) 경계 강조: 1차 미분 에너지가 큰 곳을 살짝 더
    float grad = sqrt(d0 * d0 + d90 * d90 + d45 * d45 + d135 * d135);
    restore += sign(-lap) * grad * P.edgeBoost * orient * gate * 0.35f;
    // (3) 노이즈 억제: 등방이고 노이즈 바닥 아래면 국소 평균으로 끌어당긴다
    float mean = (p[0] + p[1] + p[2] + p[3] + p[5] + p[6] + p[7] + p[8]) * 0.125f;
    float denoise = (mean - c) * P.denoise * (1.0f - orient) * (1.0f - gate);

    return restore + denoise;
}

kernel void neural_residual(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            constant NeuralParams& P              [[buffer(0)]],
                            uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    dst.write(float4(neuralResidual(src, uv, size, P), 0, 0, 1), gid);
}

/// 풀해상도 잔차는 즉석에서 계산하고, 1/2·1/4 잔차는 업샘플해서 더한다.
/// 색은 비율로 옮겨 색상·채도가 흔들리지 않게 한다.
kernel void neural_apply(texture2d<float, access::sample> src   [[texture(0)]],
                         texture2d<float, access::sample> half2 [[texture(1)]],
                         texture2d<float, access::sample> quar  [[texture(2)]],
                         texture2d<float, access::write>  dst   [[texture(3)]],
                         constant NeuralParams& P                [[buffer(0)]],
                         uint2 gid                               [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;

    float3 c = max(src.sample(kLinear, uv).rgb, 0.0f);
    float L = max(luma(c), 1e-5f);

    float delta = neuralResidual(src, uv, size, P);
    if (P.scale > 1.5f) delta += half2.sample(kLinear, uv).r * 0.72f;
    if (P.scale > 2.5f) delta += quar.sample(kLinear, uv).r * 0.48f;

    // 잔차가 휘도를 뒤집지 않도록 제한
    float Ld = max(L + clamp(delta, -L * 0.75f, L * 1.60f), 1e-5f);
    dst.write(float4(max(c * (Ld / L), 0.0f), 1), gid);
}

// ---------------------------------------------------------------------------
//  7. 디헤이즈용 다크 채널 — min(R,G,B) 를 축소해서 적는다 (He 2009)
// ---------------------------------------------------------------------------

kernel void dark_downsample(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            constant float& ratio                 [[buffer(0)]],
                            uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int taps = int(clamp(ratio, 1.0f, 4.0f));
    float span = 1.0f / float(taps);
    float dark = 1e9f;
    for (int y = 0; y < taps; ++y) {
        for (int x = 0; x < taps; ++x) {
            float2 o = (float2(x, y) + 0.5f) * span - 0.5f;
            float3 c = max(src.sample(kLinear, uv + o / size).rgb, 0.0f);
            dark = min(dark, min(c.r, min(c.g, c.b)));
        }
    }
    dst.write(float4(dark, 0, 0, 1), gid);
}

/// 일반 가우시안 선형 블러 (다크 채널 전용 — 로그가 아니라 선형값이다)
kernel void linear_blur_h(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write>  dst [[texture(1)]],
                          constant BlurParams& P                [[buffer(0)]],
                          uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(P.radius, 1.0f, 24.0f));
    float sigma2 = 0.35f * float(r * r) + 1.0f;
    float acc = src.sample(kNearest, uv).r, wsum = 1.0f;
    for (int i = 1; i <= r; ++i) {
        float wgt = exp(-0.5f * float(i * i) / sigma2);
        acc += src.sample(kLinear, uv + float2(float(i) / size.x, 0)).r * wgt;
        acc += src.sample(kLinear, uv - float2(float(i) / size.x, 0)).r * wgt;
        wsum += 2.0f * wgt;
    }
    dst.write(float4(acc / wsum, 0, 0, 1), gid);
}

kernel void linear_blur_v(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write>  dst [[texture(1)]],
                          constant BlurParams& P                [[buffer(0)]],
                          uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int r = int(clamp(P.radius, 1.0f, 24.0f));
    float sigma2 = 0.35f * float(r * r) + 1.0f;
    float acc = src.sample(kNearest, uv).r, wsum = 1.0f;
    for (int i = 1; i <= r; ++i) {
        float wgt = exp(-0.5f * float(i * i) / sigma2);
        acc += src.sample(kLinear, uv + float2(0, float(i) / size.y)).r * wgt;
        acc += src.sample(kLinear, uv - float2(0, float(i) / size.y)).r * wgt;
        wsum += 2.0f * wgt;
    }
    dst.write(float4(acc / wsum, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
//  7.5 진단 시각화 — 추리하지 않고 눈으로 본다
// ---------------------------------------------------------------------------

/// 깊이맵: 가까우면 흰색, 멀면 검정, 못 읽은 곳은 빨강
kernel void debug_depth(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant DebugParams& P              [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float d = src.read(gid).r;
    if (d <= 0.05f || d >= 300.0f) {
        dst.write(float4(0.95f, 0.15f, 0.15f, 1), gid);   // 구멍 = 빨강
        return;
    }
    // 로그 스케일이라야 가까운 쪽 차이가 보인다
    float t = saturate((log2(max(d, 1e-3f)) - P.lo) / max(P.hi - P.lo, 1e-3f));
    float v = 1.0f - t;
    dst.write(float4(v, v, v, 1), gid);
}

/// 착란원: 전경 흐림은 빨강, 배경 흐림은 파랑, 초점 맞은 곳은 초록
kernel void debug_coc(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant DebugParams& P              [[buffer(0)]],
                      uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float c = src.read(gid).r;
    float mag = saturate(abs(c) / max(P.hi, 1e-3f));
    float3 color;
    if (abs(c) < 1.0f) {
        color = float3(0.1f, 0.95f, 0.3f);                 // 초점 = 초록
    } else if (c < 0.0f) {
        color = float3(0.25f + 0.75f * mag, 0.1f, 0.1f);   // 전경 = 빨강
    } else {
        color = float3(0.1f, 0.25f, 0.35f + 0.65f * mag);  // 배경 = 파랑
    }
    dst.write(float4(color, 1), gid);
}

/// 단일 채널(매트 등)을 흑백으로
kernel void debug_gray(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write>  dst [[texture(1)]],
                       uint2 gid                            [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float v = saturate(src.sample(kLinear, (float2(gid) + 0.5f) / float2(w, h)).r);
    dst.write(float4(v, v, v, 1), gid);
}

// ---------------------------------------------------------------------------
//  8. GPU 성능 측정용 더미 부하 (센서 테스터)
//     현상에서 가장 무거운 연산(텍스처 샘플 + 초월함수)을 같은 비율로 돌린다.
// ---------------------------------------------------------------------------

kernel void bench_load(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write>  dst [[texture(1)]],
                       constant float& rounds                [[buffer(0)]],
                       uint2 gid                             [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 size = float2(w, h);
    float2 uv = (float2(gid) + 0.5f) / size;
    int n = int(clamp(rounds, 1.0f, 512.0f));
    float3 acc = 0.0f;
    float ang = hash12(float2(gid)) * 6.2831853f;
    for (int i = 0; i < n; ++i) {
        float t = float(i) / float(n);
        float a = ang + float(i) * 2.39996323f;
        float2 o = float2(cos(a), sin(a)) * (4.0f + 28.0f * t) / size;
        float3 s = src.sample(kLinear, uv + o).rgb;
        acc += s * exp2(-t * 2.0f) + log2(max(luma(s), 1e-4f)) * 1e-4f;
    }
    dst.write(float4(acc / float(n), 1), gid);
}
