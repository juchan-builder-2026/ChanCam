import Foundation
import CoreGraphics

/// 촬영한 사진 한 장. 원본 DNG + LiDAR 깊이 + 인물 매트 + 현상 설정.
struct Shot: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()

    // 저장 파일 (Documents/Shots/<id>/ 안)
    var rawFile = "raw.dng"
    var depthFile: String?       // Float32 깊이맵 (미터), 헤더 포함 바이너리
    var matteFile: String?       // 8bit 인물 매트
    var previewFile = "preview.jpg"
    var exportFile: String?      // 현상 완료한 48MP JPEG

    // 촬영 정보
    var pixelWidth = 0
    var pixelHeight = 0
    var depthWidth = 0
    var depthHeight = 0
    var iso: Float = 0
    var shutter: Float = 0       // 초
    var deviceAperture: Float = 0
    var focalLength35: Float = 0
    var focusDistance: Float = 0 // m, LiDAR 기준 초점면
    var lensName = ""
    var isProRAW = false
    var hasDepth: Bool { depthFile != nil }
    var hasMatte: Bool { matteFile != nil }

    var develop = DevelopSettings.chan
    var isFavorite = false
    /// 마지막 현상 완료 시각 (설정이 바뀌면 nil 로)
    var exportedAt: Date?

    var folderName: String { id.uuidString }

    var megapixels: Double { Double(pixelWidth) * Double(pixelHeight) / 1_000_000 }

    var shutterText: String {
        guard shutter > 0 else { return "—" }
        if shutter >= 1 { return String(format: "%.1fs", shutter) }
        return "1/\(Int((1 / shutter).rounded()))"
    }

    var summaryLine: String {
        var parts: [String] = []
        if pixelWidth > 0 { parts.append(String(format: "%.0fMP", megapixels.rounded(.down))) }
        if isProRAW { parts.append("ProRAW") }
        if hasDepth { parts.append("LiDAR") }
        if iso > 0 { parts.append("ISO \(Int(iso))") }
        if shutter > 0 { parts.append(shutterText) }
        return parts.joined(separator: " · ")
    }
}

/// 깊이맵 파일 포맷: [width:Int32][height:Int32][Float32 * w*h] (미터, 0 = 알 수 없음)
struct DepthMap {
    var width: Int
    var height: Int
    var values: [Float]

    func encoded() -> Data {
        var data = Data()
        var w = Int32(width), h = Int32(height)
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        values.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        return data
    }

    static func decode(_ data: Data) -> DepthMap? {
        guard data.count > 8 else { return nil }
        let w = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let h = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard w > 0, h > 0, data.count >= 8 + w * h * 4 else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        values.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: 8..<(8 + w * h * 4))
        }
        return DepthMap(width: w, height: h, values: values)
    }

    /// 중앙 영역의 유효 깊이 중앙값 — 자동 초점면 추정
    func centerDistance() -> Float {
        let x0 = width / 3, x1 = width * 2 / 3
        let y0 = height / 3, y1 = height * 2 / 3
        var samples: [Float] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = values[y * width + x]
                if v > 0.05 && v < 30 { samples.append(v) }
            }
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return samples[samples.count / 2]
    }
}

/// 현상 진행 상태
enum JobState: Equatable {
    case queued
    case running(stage: String, progress: Double)
    case done
    case failed(String)

    var progress: Double {
        switch self {
        case .queued: return 0
        case .running(_, let p): return p
        case .done: return 1
        case .failed: return 0
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .running: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "대기 중"
        case .running(let stage, let p): return "\(stage) \(Int(p * 100))%"
        case .done: return "완료"
        case .failed(let m): return "실패 — \(m)"
        }
    }
}
