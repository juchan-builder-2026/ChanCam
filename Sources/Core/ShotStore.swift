import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// 촬영 결과 보관소.
///
/// 48MP ProRAW 한 장이 70~100MB 라서 용량 관리가 중요하다.
/// `keepRawAfterExport` 를 끄면 현상이 끝난 뒤 원본 DNG 를 지워
/// 결과 JPEG(10~20MB)만 남긴다.
@MainActor
final class ShotStore: ObservableObject {
    static let shared = ShotStore()

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var usedBytes: Int64 = 0

    @AppStorage("keepRawAfterExport") var keepRawAfterExport = true {
        didSet { objectWillChange.send() }
    }
    /// 촬영 화면에서 고른 프리셋 번호 — 저장할 때 바로 적용된다
    @AppStorage("capturePreset") var capturePreset = 0

    private let root: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Shots", isDirectory: true)
        indexURL = documents.appendingPathComponent("shots.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 경로

    func folder(_ shot: Shot) -> URL {
        root.appendingPathComponent(shot.folderName, isDirectory: true)
    }

    func url(_ shot: Shot, _ name: String?) -> URL? {
        guard let name else { return nil }
        let candidate = folder(shot).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func rawURL(_ shot: Shot) -> URL? { url(shot, shot.rawFile) }
    func previewURL(_ shot: Shot) -> URL? { url(shot, shot.previewFile) }
    func exportURL(_ shot: Shot) -> URL? { url(shot, shot.exportFile) }

    func depthMap(_ shot: Shot) -> DepthMap? {
        guard let url = url(shot, shot.depthFile), let data = try? Data(contentsOf: url) else { return nil }
        return DepthMap.decode(data)
    }

    func matteImage(_ shot: Shot) -> CIImage? {
        guard let url = url(shot, shot.matteFile) else { return nil }
        return CIImage(contentsOf: url)
    }

    // MARK: - 저장

    func save(raw: Data?, preview: Data?, depth: AVDepthData?, matte: AVPortraitEffectsMatte?,
              metadata: [String: Any], dimensions: CGSize, focusDistance: Float,
              isProRAW: Bool) throws -> Shot {
        var shot = Shot()
        let presets = DevelopSettings.presets
        shot.develop = presets[min(max(capturePreset, 0), presets.count - 1)].settings
        shot.pixelWidth = Int(dimensions.width)
        shot.pixelHeight = Int(dimensions.height)
        shot.isProRAW = isProRAW && raw != nil
        shot.focusDistance = focusDistance

        // EXIF
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first {
                shot.iso = iso.floatValue
            }
            if let t = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
                shot.shutter = t.floatValue
            }
            if let f = exif[kCGImagePropertyExifFNumber as String] as? NSNumber {
                shot.deviceAperture = f.floatValue
            }
            if let fl = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber {
                shot.focalLength35 = fl.floatValue
            }
            if let lens = exif[kCGImagePropertyExifLensModel as String] as? String {
                shot.lensName = lens
            }
        }

        let dir = folder(shot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let raw {
            try raw.write(to: dir.appendingPathComponent("raw.dng"), options: .atomic)
        } else {
            shot.rawFile = "raw.heic"
            if let preview {
                try preview.write(to: dir.appendingPathComponent("raw.heic"), options: .atomic)
            }
        }

        // 빠른 미리보기 (목록용 축소본)
        if let preview, let source = UIImage(data: preview) {
            let thumb = ShotStore.downscale(source, maxSide: 1600)
            if let data = thumb.jpegData(compressionQuality: 0.85) {
                try data.write(to: dir.appendingPathComponent("preview.jpg"), options: .atomic)
            }
        }

        // 깊이
        if let depth {
            let converted = depth.depthDataType == kCVPixelFormatType_DepthFloat32
                ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            if let map = ShotStore.depthMap(from: converted.depthDataMap)?.rotatedToPortrait() {
                try map.encoded().write(to: dir.appendingPathComponent("depth.bin"), options: .atomic)
                shot.depthFile = "depth.bin"
                shot.depthWidth = map.width
                shot.depthHeight = map.height
                if shot.focusDistance <= 0.02 { shot.focusDistance = map.centerDistance() }
            }
        }

        // 인물 매트
        if let matte {
            let image = CIImage(cvPixelBuffer: matte.mattingImage)
            let context = CIContext()
            if let data = context.jpegRepresentation(of: image,
                                                     colorSpace: CGColorSpaceCreateDeviceGray(),
                                                     options: [:]) {
                try data.write(to: dir.appendingPathComponent("matte.jpg"), options: .atomic)
                shot.matteFile = "matte.jpg"
            }
        }

        shots.insert(shot, at: 0)
        persist()
        recomputeUsage()
        return shot
    }

    /// 시뮬레이터 데모 전용 — 디스크 인덱스에는 쓰지 않는다
    func appendDemo(_ shot: Shot) {
        shots.append(shot)
        shots.sort { $0.date > $1.date }
    }

    // MARK: - 갱신

    func update(_ shot: Shot) {
        guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
        shots[index] = shot
        persist()
    }

    func updateDevelop(_ id: UUID, _ settings: DevelopSettings) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        guard shots[index].develop != settings else { return }
        shots[index].develop = settings
        shots[index].exportedAt = nil
        persist()
    }

    func markExported(_ id: UUID, file: String, keepRaw: Bool? = nil) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].exportFile = file
        shots[index].exportedAt = Date()
        // 용량 절약: 원본을 남기지 않는 설정이면 DNG 삭제
        if !(keepRaw ?? keepRawAfterExport), shots[index].isProRAW {
            let target = folder(shots[index]).appendingPathComponent(shots[index].rawFile)
            try? FileManager.default.removeItem(at: target)
        }
        persist()
        recomputeUsage()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].isFavorite.toggle()
        persist()
    }

    func delete(_ shot: Shot) {
        try? FileManager.default.removeItem(at: folder(shot))
        shots.removeAll { $0.id == shot.id }
        persist()
        recomputeUsage()
    }

    /// 현상이 끝난 사진들의 원본 DNG 만 한 번에 지운다
    @discardableResult
    func purgeExportedRaws() -> Int64 {
        var freed: Int64 = 0
        for shot in shots where shot.exportedAt != nil && shot.isProRAW {
            let target = folder(shot).appendingPathComponent(shot.rawFile)
            if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64 {
                freed += size
            }
            try? FileManager.default.removeItem(at: target)
        }
        recomputeUsage()
        return freed
    }

    func hasRaw(_ shot: Shot) -> Bool { rawURL(shot) != nil }

    /// 아직 현상하지 않은 사진들 (원본이 남아 있는 것만)
    var undeveloped: [Shot] {
        shots.filter { $0.exportedAt == nil && rawURL($0) != nil }
    }

    // MARK: - 용량

    func recomputeUsage() {
        let path = root
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            if let walker = FileManager.default.enumerator(at: path,
                                                           includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            Task { @MainActor in self.usedBytes = total }
        }
    }

    var usedText: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var freeText: String {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    func size(of shot: Shot) -> Int64 {
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: folder(shot),
                                                       includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    // MARK: - 목록 저장

    private func persist() {
        guard let data = try? JSONEncoder().encode(shots) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([Shot].self, from: data) else { return }
        // 폴더가 사라진 항목은 정리
        shots = saved.filter { FileManager.default.fileExists(atPath: folder($0).path) }
        if shots.count != saved.count { persist() }
        recomputeUsage()
    }

    // MARK: - 도우미

    nonisolated static func depthMap(from buffer: CVPixelBuffer) -> DepthMap? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        let isDisparity = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DisparityFloat32
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                var v = row[x]
                if !v.isFinite || v <= 0 { v = 0 }
                else if isDisparity { v = 1 / v }
                values[y * width + x] = v
            }
        }
        return DepthMap(width: width, height: height, values: values)
    }

    nonisolated static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
