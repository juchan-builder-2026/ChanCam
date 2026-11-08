import AVFoundation
import CoreMedia
import Foundation
import Metal
import QuartzCore
import UIKit
import Vision

/// 기기 하드웨어를 실제로 조회해서 적는다. 추측값은 하나도 넣지 않는다 —
/// 못 알아내는 항목은 "확인 불가"로 남긴다.
struct SensorProbe {

    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        var good: Bool?          // nil = 중립, true = 녹색, false = 주황
    }

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let rows: [Row]
        var note: String?
    }

    // MARK: - 기기

    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        let raw = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return raw.isEmpty ? "확인 불가" : raw
    }

    static func deviceGroup() -> Group {
        let info = ProcessInfo.processInfo
        var rows: [Row] = [
            Row(title: "모델 식별자", value: modelIdentifier),
            Row(title: "시스템", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
            Row(title: "CPU 코어", value: "\(info.activeProcessorCount) / \(info.processorCount)"),
            Row(title: "물리 메모리", value: SystemMonitor.text(info.physicalMemory)),
        ]
        let footprint = SystemMonitor.footprint()
        rows.append(Row(title: "앱 사용 메모리", value: SystemMonitor.text(footprint)))
        rows.append(Row(title: "앱 메모리 한도",
                        value: SystemMonitor.text(SystemMonitor.memoryLimit(current: footprint))))
        rows.append(Row(title: "열 상태", value: info.thermalState.label,
                        good: info.thermalState == .nominal))
        rows.append(Row(title: "저전력 모드", value: info.isLowPowerModeEnabled ? "켜짐 — 성능 제한" : "꺼짐",
                        good: !info.isLowPowerModeEnabled))
        return Group(title: "기기", symbol: "iphone", rows: rows)
    }

    // MARK: - GPU

    static func gpuGroup() -> Group {
        guard let device = Renderer.shared?.device else {
            return Group(title: "GPU", symbol: "cpu", rows: [Row(title: "Metal", value: "사용 불가", good: false)])
        }
        var rows: [Row] = [
            Row(title: "이름", value: device.name),
            Row(title: "통합 메모리", value: device.hasUnifiedMemory ? "예" : "아니오"),
            Row(title: "권장 작업 메모리",
                value: SystemMonitor.text(device.recommendedMaxWorkingSetSize)),
            Row(title: "최대 버퍼 길이", value: SystemMonitor.text(UInt64(device.maxBufferLength))),
            Row(title: "스레드그룹 최대", value: "\(device.maxThreadsPerThreadgroup.width)×\(device.maxThreadsPerThreadgroup.height)"),
            Row(title: "Metal 3", value: device.supportsFamily(.metal3) ? "지원" : "미지원",
                good: device.supportsFamily(.metal3)),
            Row(title: "하드웨어 레이트레이싱", value: device.supportsRaytracing ? "지원" : "미지원",
                good: device.supportsRaytracing),
            Row(title: "32비트 float 필터링", value: device.supports32BitFloatFiltering ? "지원" : "미지원"),
            Row(title: "읽기·쓰기 텍스처", value: "티어 \(device.readWriteTextureSupport.rawValue)"),
        ]
        var family = "확인 불가"
        if device.supportsFamily(.apple9) { family = "Apple9 (A17 Pro / M3 급)" }
        else if device.supportsFamily(.apple8) { family = "Apple8 (A15~A16 / M2 급)" }
        else if device.supportsFamily(.apple7) { family = "Apple7 (A14 / M1 급)" }
        else if device.supportsFamily(.apple6) { family = "Apple6 (A13 급)" }
        rows.insert(Row(title: "GPU 패밀리", value: family), at: 1)
        return Group(title: "GPU", symbol: "cpu", rows: rows,
                     note: "하드웨어 레이트레이싱은 3D 가속기 얘기예요. ChanCam 의 광선 추적은 깊이 버퍼를 직접 마칭하는 컴퓨트 셰이더라 이 항목과 무관하게 동작해요.")
    }

    // MARK: - 신경망 / Vision

    static func neuralGroup() -> Group {
        var rows: [Row] = []
        rows.append(Row(title: "Vision 사람 분리",
                        value: "사용 가능", good: true))
        if #available(iOS 17.0, *) {
            rows.append(Row(title: "Vision 피사체 분리 (전경 인스턴스)",
                            value: "사용 가능", good: true))
        } else {
            rows.append(Row(title: "Vision 피사체 분리", value: "iOS 17 필요", good: false))
        }
        let revisions = VNGeneratePersonSegmentationRequest.supportedRevisions
            .map { String($0) }.joined(separator: ", ")
        rows.append(Row(title: "사람 분리 리비전", value: revisions.isEmpty ? "확인 불가" : revisions))
        rows.append(Row(title: "ChanCam 신경망 블록",
                        value: "3층 · 8필터 · 결정론적 가중치"))
        return Group(title: "신경망", symbol: "brain", rows: rows,
                     note: "ChanCam 의 디테일 복원 망은 방향 선택 합성곱 → 분할 정규화 → 재결합 3층 구조예요. 가중치를 학습한 게 아니라 조향 기저로 해석적으로 정해서, 모델 파일이 없고 결과가 항상 같아요. 피사체 분리는 애플이 학습시킨 Vision 모델을 그대로 써요.")
    }

    // MARK: - 카메라

    static func cameraGroups() -> [Group] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInLiDARDepthCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: .unspecified)
        let devices = session.devices.filter { $0.position == .back }
        guard !devices.isEmpty else {
            return [Group(title: "카메라", symbol: "camera",
                          rows: [Row(title: "뒷면 카메라", value: "찾지 못함", good: false)])]
        }
        return devices.map { cameraGroup($0) }
    }

    private static func cameraGroup(_ device: AVCaptureDevice) -> Group {
        let depthFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        let maxPhoto = device.formats
            .flatMap(\.supportedMaxPhotoDimensions)
            .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        let bestDepth = depthFormats
            .flatMap(\.supportedDepthDataFormats)
            .map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }

        var rows: [Row] = []
        if let maxPhoto {
            let mp = Double(maxPhoto.width) * Double(maxPhoto.height) / 1_000_000
            rows.append(Row(title: "최대 사진",
                            value: String(format: "%.0fMP · %d×%d", mp.rounded(.down),
                                          maxPhoto.width, maxPhoto.height)))
        }
        rows.append(Row(title: "포맷 수", value: "\(device.formats.count)개"))
        rows.append(Row(title: "깊이 지원 포맷", value: "\(depthFormats.count)개",
                        good: !depthFormats.isEmpty))
        if let bestDepth {
            rows.append(Row(title: "최대 깊이맵", value: "\(bestDepth.width)×\(bestDepth.height)",
                            good: true))
        } else {
            rows.append(Row(title: "최대 깊이맵", value: "없음", good: false))
        }

        // 48MP 와 깊이를 동시에 가지는 포맷이 있는지 — v1.0 의 LiDAR 문제의 핵심
        let bigAndDepth = device.formats.contains { format in
            guard !format.supportedDepthDataFormats.isEmpty else { return false }
            let best = format.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
            return best >= 40_000_000
        }
        rows.append(Row(title: "40MP↑ + 깊이 동시 포맷", value: bigAndDepth ? "있음" : "없음",
                        good: bigAndDepth))

        let active = device.activeFormat
        let activeDim = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        rows.append(Row(title: "현재 활성 포맷", value: "\(activeDim.width)×\(activeDim.height)"))
        rows.append(Row(title: "ISO 범위",
                        value: String(format: "%.0f – %.0f", active.minISO, active.maxISO)))
        rows.append(Row(title: "셔터 범위",
                        value: String(format: "%.0fs – 1/%.0f",
                                      CMTimeGetSeconds(active.maxExposureDuration),
                                      1 / max(CMTimeGetSeconds(active.minExposureDuration), 1e-6))))
        rows.append(Row(title: "노출 보정 범위",
                        value: String(format: "%+.1f – %+.1f EV",
                                      device.minExposureTargetBias, device.maxExposureTargetBias)))
        rows.append(Row(title: "최소 초점 거리",
                        value: device.minimumFocusDistance > 0
                            ? "\(device.minimumFocusDistance)mm" : "확인 불가"))
        rows.append(Row(title: "광학 손떨림 보정",
                        value: active.isVideoStabilizationModeSupported(.cinematicExtended)
                            ? "시네마틱 확장" : (active.isVideoStabilizationModeSupported(.standard)
                                             ? "표준" : "미지원")))
        rows.append(Row(title: "빈닝(픽셀 합치기) 포맷",
                        value: active.isVideoBinned ? "사용 중" : "사용 안 함"))
        rows.append(Row(title: "렌즈 조리개", value: String(format: "f/%.2f", device.lensAperture)))

        var note: String?
        if device.deviceType == .builtInLiDARDepthCamera {
            note = "LiDAR 카메라예요. ChanCam 은 여기서 깊이를 전용 스트림으로 계속 받아 셔터 순간 프레임을 붙여요."
        }
        return Group(title: label(for: device), symbol: "camera.aperture", rows: rows, note: note)
    }

    private static func label(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInLiDARDepthCamera: return "LiDAR 깊이 카메라"
        case .builtInWideAngleCamera: return "광각"
        case .builtInUltraWideCamera: return "초광각"
        case .builtInTelephotoCamera: return "망원"
        case .builtInDualWideCamera: return "듀얼 광각"
        case .builtInTripleCamera: return "트리플"
        default: return device.localizedName
        }
    }

    // MARK: - 사진 출력 능력 (실제로 세션에 붙은 출력에서 읽은 값)

    static func photoGroup(_ caps: Camera.Capabilities?) -> Group {
        guard let caps, caps.configured else {
            return Group(title: "사진 출력", symbol: "camera.shutter.button",
                         rows: [Row(title: "상태", value: "카메라 세션이 아직 안 열렸어요", good: false)],
                         note: "이 항목들은 세션을 실제로 구성한 뒤에만 의미가 있어요. 촬영 화면을 한 번 열고 다시 들어오세요.")
        }
        func mark(_ ok: Bool) -> String { ok ? "지원" : "미지원" }
        var rows: [Row] = [
            Row(title: "활성 카메라", value: caps.deviceName),
            Row(title: "최대 사진",
                value: String(format: "%.0fMP · %d×%d",
                              (Double(caps.maxPhotoWidth) * Double(caps.maxPhotoHeight) / 1_000_000)
                                  .rounded(.down),
                              caps.maxPhotoWidth, caps.maxPhotoHeight)),
            Row(title: "Apple ProRAW", value: caps.proRAWEnabled ? "켜짐" : mark(caps.proRAW),
                good: caps.proRAWEnabled),
            Row(title: "깊이 전달 (사진 출력)", value: mark(caps.depthDelivery)),
            Row(title: "깊이 전용 스트림",
                value: caps.streamingDepth ? "사용 중" : "사용 안 함", good: caps.streamingDepth),
            Row(title: "인물 효과 매트", value: mark(caps.portraitMatte)),
            Row(title: "콘텐츠 인식 왜곡 보정", value: mark(caps.distortionCorrection)),
            Row(title: "제로 셔터랙", value: mark(caps.zeroShutterLag)),
            Row(title: "반응형 캡처", value: mark(caps.responsiveCapture)),
            Row(title: "사용 가능 RAW 포맷", value: "\(caps.rawFormats)개"),
        ]
        if caps.depthWidth > 0 {
            rows.append(Row(title: "활성 깊이 포맷",
                            value: "\(caps.depthWidth)×\(caps.depthHeight)", good: true))
        } else {
            rows.append(Row(title: "활성 깊이 포맷", value: "없음", good: false))
        }
        return Group(title: "사진 출력", symbol: "camera.shutter.button", rows: rows,
                     note: "깊이 데이터 전달과 48MP ProRAW 는 동시에 못 켜요. 그래서 ChanCam 은 깊이를 전용 스트림으로 따로 받아요.")
    }

    /// 깊이 스트림이 지금 실제로 흐르고 있는지 — "LiDAR 안 찍힘"을 눈으로 확인하는 곳
    static func depthGroup(fps: Double, coverage: Double, distance: Float,
                           frames: Int, streaming: Bool) -> Group {
        var rows: [Row] = [
            Row(title: "스트림 상태", value: streaming ? "흐르는 중" : "멈춤", good: streaming),
            Row(title: "초당 프레임", value: String(format: "%.1f fps", fps), good: fps > 5),
            Row(title: "받은 프레임 수", value: "\(frames)", good: frames > 0),
            Row(title: "유효 픽셀 비율", value: String(format: "%.0f%%", coverage * 100),
                good: coverage > 0.3),
            Row(title: "중앙 거리",
                value: distance > 0.03 ? String(format: "%.2f m", distance) : "측정 안 됨",
                good: distance > 0.03),
        ]
        if !streaming {
            rows.append(Row(title: "원인", value: "전용 깊이 출력이 세션에 안 붙었어요", good: false))
        }
        return Group(title: "LiDAR 깊이 스트림", symbol: "cube.transparent", rows: rows,
                     note: "유효 픽셀 비율은 깊이를 실제로 측정한 픽셀의 비율이에요. 하늘·유리·아주 먼 곳은 LiDAR 가 못 읽어서 0 으로 와요. 30% 아래면 보케 경계가 거칠어질 수 있어요.")
    }

    // MARK: - GPU 벤치마크

    struct Benchmark {
        var tapsPerSecond: Double
        var milliseconds: Double
        var gpuSeconds: Double
        var pixels: Int
        var rounds: Int

        var scoreText: String {
            String(format: "%.1f G탭/초", tapsPerSecond / 1e9)
        }
    }

    /// 현상에서 가장 무거운 연산(텍스처 샘플 + 초월함수)을 같은 비율로 돌려
    /// 이 기기가 초당 몇 번의 샘플을 처리하는지 실측한다.
    static func benchmark(side: Int = 1024, rounds: Int = 48) -> Benchmark? {
        guard let renderer = Renderer.shared else { return nil }
        return renderer.benchmark(side: side, rounds: rounds)
    }

    /// 목표 해상도의 중간 버퍼를 정말로 잡을 수 있는지 시험한다
    static func memoryTest(longSide: Int) -> (ok: Bool, detail: String) {
        guard let renderer = Renderer.shared else { return (false, "GPU 없음") }
        let width = longSide, height = Int(Double(longSide) * 0.75)
        let bytes = Int64(width) * Int64(height) * 8 * 2
        guard let a = renderer.texture(width, height), let b = renderer.texture(width, height) else {
            return (false, "\(SystemMonitor.text(UInt64(bytes))) 할당 실패")
        }
        _ = a.width; _ = b.width
        return (true, "\(SystemMonitor.text(UInt64(bytes))) 할당 성공 (풀해상도 버퍼 2장)")
    }
}
