import CoreGraphics
import Foundation
import UIKit

/// 시뮬레이터 스크린샷 전용 가짜 데이터. `-demo` 인수로만 동작하고
/// 카메라나 네트워크를 전혀 쓰지 않는다.
enum DemoData {
    static func install() {
        let store = ShotStore.shared
        guard store.shots.isEmpty else { return }

        let specs: [(hue: Double, iso: Float, shutter: Float, depth: Bool, preset: Int)] = [
            (0.07, 100, 1.0 / 250, true, 2),
            (0.56, 640, 1.0 / 125, true, 0),
            (0.10, 1600, 1.0 / 60, true, 4),
            (0.33, 100, 1.0 / 500, false, 3),
            (0.95, 800, 1.0 / 90, true, 5),
            (0.60, 125, 1.0 / 320, false, 1),
            (0.03, 2500, 1.0 / 45, true, 4),
            (0.45, 200, 1.0 / 200, true, 6),
            (0.15, 400, 1.0 / 160, true, 0),
        ]

        let presets = DevelopSettings.presets
        for (index, spec) in specs.enumerated() {
            var shot = Shot()
            shot.date = Date().addingTimeInterval(-Double(index) * 5400)
            shot.pixelWidth = 8064
            shot.pixelHeight = 6048
            shot.iso = spec.iso
            shot.shutter = spec.shutter
            shot.deviceAperture = 1.78
            shot.focalLength35 = 24
            shot.isProRAW = true
            shot.focusDistance = 1.2 + Float(index % 4) * 0.8
            shot.develop = presets[min(spec.preset, presets.count - 1)].settings
            shot.isFavorite = index % 4 == 1
            if spec.depth {
                shot.depthFile = "depth.bin"
                shot.depthWidth = 320
                shot.depthHeight = 240
            }
            if index % 3 != 2 { shot.exportedAt = shot.date }

            let dir = store.folder(shot)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = sample(hue: spec.hue, seed: index).jpegData(compressionQuality: 0.9) {
                try? data.write(to: dir.appendingPathComponent("preview.jpg"))
            }
            store.appendDemo(shot)
        }
    }

    /// 보케 느낌이 나는 가짜 샘플 이미지
    static func sample(hue: Double, seed: Int) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(hue: hue, saturation: 0.45, brightness: 0.22, alpha: 1).cgColor,
                UIColor(hue: hue + 0.05, saturation: 0.55, brightness: 0.52, alpha: 1).cgColor,
                UIColor(hue: hue - 0.03, saturation: 0.30, brightness: 0.10, alpha: 1).cgColor,
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // 흐린 배경 광원 (보케 볼)
            var generator = SeededRandom(seed: UInt64(seed * 977 + 13))
            for _ in 0..<14 {
                let r = CGFloat(generator.next(40...130))
                let x = CGFloat(generator.next(0...Int(size.width)))
                let y = CGFloat(generator.next(0...Int(size.height * 0.7)))
                let alpha = CGFloat(generator.next(8...26)) / 100
                cg.setFillColor(UIColor(hue: hue + 0.03, saturation: 0.35,
                                        brightness: 1.0, alpha: alpha).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            // 선명한 피사체 느낌
            cg.setFillColor(UIColor(hue: hue, saturation: 0.18, brightness: 0.88, alpha: 0.92).cgColor)
            cg.fillEllipse(in: CGRect(x: size.width * 0.28, y: size.height * 0.42,
                                      width: size.width * 0.44, height: size.width * 0.44))
        }
    }

    struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let span = UInt64(max(range.upperBound - range.lowerBound, 1))
            return range.lowerBound + Int((state >> 33) % span)
        }
    }
}
