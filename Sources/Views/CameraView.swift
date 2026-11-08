import AVFoundation
import SwiftUI

struct CameraView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @StateObject private var camera = Camera()
    @Binding var showLibrary: Bool

    @State private var focusPoint: CGPoint?
    @State private var exposureBias: Float = 0
    @State private var showSettings = false
    @State private var showSensor = false
    @State private var developTargets: [Shot] = []
    @State private var pinchBase: CGFloat = 1
    @AppStorage("capturePreset") private var presetIndex = 0

    private var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDemo {
                DemoViewfinder()
            } else if camera.permissionDenied {
                PermissionNotice()
            } else {
                CameraPreview(session: camera.session,
                              onTap: { point in camera.focus(at: point) },
                              onPinch: { scale in
                                  camera.setZoom(pinchBase * scale)
                              },
                              onPinchEnded: { pinchBase = camera.zoom })
                .ignoresSafeArea()
            }

            if camera.flashOverlay {
                Color.black.ignoresSafeArea().transition(.opacity)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .animation(.easeOut(duration: 0.12), value: camera.flashOverlay)
        .sheet(isPresented: $showSettings) { SettingsView(camera: camera) }
        .sheet(isPresented: $showSensor) { SensorTestView(camera: camera) }
        .sheet(isPresented: Binding(get: { !developTargets.isEmpty },
                                    set: { if !$0 { developTargets = [] } })) {
            DevelopView(shots: developTargets)
        }
        .onAppear {
            if !isDemo { camera.start() }
        }
        .onDisappear { camera.stop() }
    }

    // MARK: - 위

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isDemo ? "48MP ProRAW" : camera.modeLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(isDemo ? "8064×6048 · LiDAR 깊이 · 인물 매트" : camera.detailLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.42)))

            Spacer()

            if processor.isDeveloping {
                ProcessingPill()
            }

            Button { showSensor = true } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.42)))
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.42)))
            }
        }
    }

    // MARK: - 아래

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if !isDemo {
                ZoomStrip(camera: camera, pinchBase: $pinchBase)
            }

            PresetStrip(index: $presetIndex)

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text(focusText)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.4)))

                Spacer()

                let waiting = store.undeveloped
                if !waiting.isEmpty, !processor.isDeveloping {
                    Button {
                        developTargets = waiting
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.rays")
                            Text("현상 \(waiting.count)장")
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.yellow))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                    Text(store.usedText)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.4)))
            }

            HStack {
                LibraryThumb(shot: store.shots.first) { showLibrary = true }
                Spacer()
                ShutterButton(busy: camera.isCapturing) {
                    guard !isDemo else { return }
                    camera.capture()
                }
                Spacer()
                Color.clear.frame(width: 58, height: 58)
            }

            if let error = camera.lastError ?? processor.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.5)))
            }
        }
    }

    private var focusText: String {
        let d = isDemo ? 1.85 : Double(camera.liveFocusDistance)
        guard d > 0.03 else { return "초점 —" }
        return String(format: "초점 %.2fm", d)
    }
}

// MARK: - 부품

struct ShutterButton: View {
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 3.5).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 61, height: 61)
                    .scaleEffect(busy ? 0.84 : 1)
                if busy {
                    ProgressView().tint(.black)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: busy)
        .sensoryFeedback(.impact(weight: .heavy), trigger: busy)
    }
}

struct LibraryThumb: View {
    let shot: Shot?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.12))
                if let shot, let image = ThumbCache.shared.image(for: shot) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 촬영 중 확대. 메인 센서를 자르는 디지털 줌이라 렌즈가 바뀌지 않는다.
struct ZoomStrip: View {
    @ObservedObject var camera: Camera
    @Binding var pinchBase: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ForEach(camera.zoomStops, id: \.self) { stop in
                let selected = abs(camera.zoom - stop) < 0.06
                Button {
                    camera.setZoom(stop)
                    pinchBase = stop
                } label: {
                    Text(label(stop))
                        .font(.system(size: selected ? 13 : 11.5,
                                      weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 42, height: 32)
                        .background(Circle().fill(selected ? .yellow : .black.opacity(0.45))
                            .frame(width: 36, height: 36))
                        .foregroundStyle(selected ? .black : .white)
                }
                .buttonStyle(.plain)
            }
            if !isStop(camera.zoom) {
                Text(String(format: "%.1f×", camera.zoom))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.yellow))
            }
        }
        .frame(height: 40)
        .sensoryFeedback(.selection, trigger: camera.zoom)
    }

    private func isStop(_ value: CGFloat) -> Bool {
        camera.zoomStops.contains { abs($0 - value) < 0.06 }
    }

    private func label(_ stop: CGFloat) -> String {
        stop == stop.rounded() ? "\(Int(stop))×" : String(format: "%.1f×", stop)
    }
}

struct PresetStrip: View {
    @Binding var index: Int
    private let presets = DevelopSettings.presets

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.element.id) { i, preset in
                    let selected = i == index
                    Button { index = i } label: {
                        HStack(spacing: 5) {
                            Image(systemName: preset.symbol).font(.system(size: 10))
                            Text(preset.name).font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(selected ? .yellow : .black.opacity(0.45)))
                        .foregroundStyle(selected ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .sensoryFeedback(.selection, trigger: index)
    }
}

struct ProcessingPill: View {
    @EnvironmentObject private var processor: Processor

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini).tint(.yellow)
            if let batch = processor.batch {
                Text("\(batch.stage) \(Int(batch.overall * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if batch.total > 1 {
                    Text("\(batch.finished + 1)/\(batch.total)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.5)))
    }
}

struct PermissionNotice: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.yellow)
            Text("카메라 접근이 꺼져 있어요").font(.headline).foregroundStyle(.white)
            Text("설정 → ChanCam → 카메라를 켜주세요")
                .font(.subheadline).foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// 시뮬레이터 스크린샷용 가짜 뷰파인더 (카메라 없음)
struct DemoViewfinder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.18),
                                    Color(red: 0.26, green: 0.20, blue: 0.16),
                                    Color(red: 0.07, green: 0.07, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // 보케 볼 느낌
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .fill(Color.orange.opacity(0.1 + Double(i % 3) * 0.05))
                    .frame(width: 60 + CGFloat(i % 4) * 34)
                    .blur(radius: 1.5)
                    .offset(x: CGFloat((i * 71) % 300) - 150,
                            y: CGFloat((i * 113) % 420) - 260)
            }
            RoundedRectangle(cornerRadius: 3)
                .stroke(.yellow, lineWidth: 1.5)
                .frame(width: 74, height: 74)
        }
        .ignoresSafeArea()
    }
}
