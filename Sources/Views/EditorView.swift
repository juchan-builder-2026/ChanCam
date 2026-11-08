import SwiftUI
import UIKit

struct EditorView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss

    let shot: Shot

    @State private var settings = DevelopSettings.chan
    @State private var original = DevelopSettings.chan
    @State private var rendered: CGImage?
    @State private var fallback: UIImage?
    @State private var isRendering = false
    @State private var showOriginal = false
    @State private var group: EditorGroup = .light
    @State private var showInfo = false
    @State private var renderTask: Task<Void, Never>?
    @State private var loaded = false
    @State private var showDevelop = false
    @State private var showDiagnostic = false
    @State private var focusMarker: CGPoint?

    private var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    private var changed: Bool { settings != original }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imageArea
                controls
            }
            .background(Color.black)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { save(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostic = true } label: {
                        Image(systemName: "stethoscope")
                    }
                    .disabled(!store.hasRaw(shot))
                }
                ToolbarItem(placement: .principal) {
                    Button { showInfo = true } label: {
                        VStack(spacing: 1) {
                            Text(shot.summaryLine)
                                .font(.system(size: 11, weight: .medium))
                            Text(exportStatus)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                        showDevelop = true
                    } label: {
                        Image(systemName: "wand.and.rays")
                    }
                    .disabled(!store.hasRaw(shot) || processor.isDeveloping)
                }
            }
            .sheet(isPresented: $showInfo) { ShotInfoView(shot: shot) }
            .sheet(isPresented: $showDevelop) {
                DevelopView(shots: [store.shots.first(where: { $0.id == shot.id }) ?? shot])
            }
            .sheet(isPresented: $showDiagnostic) {
                DiagnosticView(shot: shot, settings: settings)
            }
        }
        .onAppear(perform: load)
        .onDisappear { renderTask?.cancel(); save() }
    }

    // MARK: - 이미지

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                imageContent
                if let marker = focusMarker {
                    Circle()
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: 54, height: 54)
                        .position(marker)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { point in
                setFocus(at: point, in: geo.size)
            }
            .onLongPressGesture(minimumDuration: 0.08, maximumDistance: 40) {
            } onPressingChanged: { pressing in
                showOriginal = pressing
                if !pressing { scheduleRender() } else { renderOriginal() }
            }
        }
    }

    private var imageContent: some View {
        ZStack {
            Color.black
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            if isRendering {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).tint(.yellow)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.4)))
                            .padding(10)
                    }
                    Spacer()
                }
            }
            if showOriginal {
                VStack {
                    Spacer()
                    Text("원본")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 탭한 곳에 초점을 잡는다. 화면 좌표를 '사진 안의 정규화 좌표'로 바꿔야 해서
    /// scaledToFit 으로 들어간 실제 그림 영역을 다시 계산한다.
    private func setFocus(at point: CGPoint, in size: CGSize) {
        guard shot.hasDepth, settings.bokehEnabled else { return }
        guard let image = displayImage, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let originX = (size.width - drawn.width) / 2
        let originY = (size.height - drawn.height) / 2
        let nx = (point.x - originX) / drawn.width
        let ny = (point.y - originY) / drawn.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
        settings.focusX = Float(nx)
        settings.focusY = Float(ny)
        settings.focusDistance = 0          // 탭한 지점이 수동 거리보다 우선
        focusMarker = point
        scheduleRender()
    }

    private var displayImage: UIImage? {
        if let rendered { return UIImage(cgImage: rendered) }
        return fallback
    }

    private var exportStatus: String {
        if let state = processor.state(shot.id), state.isActive { return state.label }
        if changed { return "변경됨 — 저장하려면 내보내기" }
        if shot.exportedAt != nil { return "현상 완료 · \(processor.exportSize.title)" }
        return store.hasRaw(shot) ? "원본 보관 중" : "원본 삭제됨"
    }

    // MARK: - 조작부

    private var controls: some View {
        VStack(spacing: 0) {
            presetRow
            Divider().overlay(Color.white.opacity(0.1))
            groupTabs
            sliderList
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DevelopSettings.presets) { preset in
                    Button {
                        var next = preset.settings
                        next.focusDistance = settings.focusDistance
                        next.focusX = settings.focusX
                        next.focusY = settings.focusY
                        settings = next
                        scheduleRender()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.symbol).font(.system(size: 13))
                            Text(preset.name).font(.system(size: 10, weight: .semibold))
                        }
                        .frame(width: 58, height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(matches(preset.settings) ? Color.yellow : Color.white.opacity(0.09)))
                        .foregroundStyle(matches(preset.settings) ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// 지금 실제로 쓰이는 환산 화각과 확대에 따른 해상도 손실
    private var autoFocalNote: String {
        let captured = (shot.focalLength35 > 1 ? shot.focalLength35 : 24)
            * max(shot.captureZoom, 1)
        let effective = settings.effectiveFocalLength(captured: captured)
        let base = String(format: "촬영 %.0fmm → 지금 %.0fmm 상당", captured, effective)
        guard settings.zoom > 1.01 else { return base }
        let mp = shot.megapixels / Double(settings.zoom * settings.zoom)
        return base + String(format: " · %.1fMP 로 잘림", mp)
    }

    private func matches(_ other: DevelopSettings) -> Bool {
        var a = settings, b = other
        a.focusDistance = 0; b.focusDistance = 0
        a.focusX = -1; b.focusX = -1
        a.focusY = -1; b.focusY = -1
        return a == b
    }

    private var groupTabs: some View {
        HStack(spacing: 0) {
            ForEach(EditorGroup.allCases) { item in
                Button { group = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 14))
                        Text(item.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(group == item ? .yellow : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.03))
    }

    private var sliderList: some View {
        ScrollView {
            VStack(spacing: 2) {
                if group == .lens {
                    Toggle(isOn: Binding(get: { settings.bokehEnabled },
                                         set: { settings.bokehEnabled = $0; scheduleRender() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("보케 시뮬레이션").font(.subheadline.weight(.medium))
                            Text(shot.hasDepth ? "LiDAR 깊이로 실제 렌즈처럼 계산"
                                               : "이 사진에는 깊이 정보가 없어요")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!shot.hasDepth)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if settings.bokehEnabled && shot.hasDepth {
                        BokehInfoRow(settings: settings, shot: shot)

                            Text("사진을 탭하면 그 자리에 초점을 잡아요.")
                            .font(.caption2)
                            .foregroundStyle(.yellow.opacity(0.75))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 2)

                        Toggle(isOn: Binding(get: { settings.autoFocalLength },
                                             set: { settings.autoFocalLength = $0; scheduleRender() })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("화각 자동 인식").font(.subheadline.weight(.medium))
                                Text(autoFocalNote).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("깊이 방향 — 보케가 엉뚱한 데 걸리면 돌려보세요")
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                            Picker("", selection: Binding(
                                get: { settings.depthRotation },
                                set: { settings.depthRotation = $0; scheduleRender() })) {
                                Text("0°").tag(0)
                                Text("90°").tag(1)
                                Text("180°").tag(2)
                                Text("270°").tag(3)
                            }
                            .pickerStyle(.segmented)
                            Toggle("깊이 좌우 반전", isOn: Binding(
                                get: { settings.depthMirror },
                                set: { settings.depthMirror = $0; scheduleRender() }))
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }

                if let note = group.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }

                ForEach(group.sliders) { slider in
                    EditSlider(slider: slider, settings: $settings) { scheduleRender() }
                }

                HStack(spacing: 10) {
                    Button {
                        settings = .flat
                        scheduleRender()
                    } label: {
                        Label("초기화", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        settings = .chan
                        scheduleRender()
                    } label: {
                        Label("Chan 기본", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                }
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .frame(height: 268)
        .scrollIndicators(.hidden)
    }

    // MARK: - 렌더

    private func load() {
        guard !loaded else { return }
        loaded = true
        let current = store.shots.first(where: { $0.id == shot.id }) ?? shot
        settings = current.develop
        original = current.develop
        if let url = store.exportURL(current) ?? store.previewURL(current),
           let data = try? Data(contentsOf: url) {
            fallback = UIImage(data: data)
        }
        scheduleRender()
    }

    private func scheduleRender() {
        guard !isDemo else { return }
        renderTask?.cancel()
        let current = settings
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            if Task.isCancelled { return }
            isRendering = true
            let image = await processor.preview(shot: shot, settings: current)
            if Task.isCancelled { return }
            if let image { rendered = image }
            isRendering = false
        }
    }

    private func renderOriginal() {
        guard !isDemo else { return }
        renderTask?.cancel()
        renderTask = Task {
            isRendering = true
            let image = await processor.preview(shot: shot, settings: .flat)
            if Task.isCancelled { return }
            if let image { rendered = image }
            isRendering = false
        }
    }

    private func save() {
        store.updateDevelop(shot.id, settings)
    }
}

// MARK: - 슬라이더

struct EditSlider: View {
    let slider: Slider1D
    @Binding var settings: DevelopSettings
    let onChange: () -> Void

    private var value: Binding<Double> {
        Binding(get: { Double(settings[keyPath: slider.key]) },
                set: { settings[keyPath: slider.key] = Float($0) })
    }

    private var isNeutral: Bool {
        abs(settings[keyPath: slider.key] - slider.neutral) < slider.step * 0.6
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(slider.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(slider.text(settings))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isNeutral ? .white.opacity(0.4) : .yellow)
                    .onTapGesture {
                        settings[keyPath: slider.key] = slider.neutral
                        onChange()
                    }
            }
            Slider(value: value,
                   in: Double(slider.range.lowerBound)...Double(slider.range.upperBound),
                   step: Double(slider.step)) { editing in
                if !editing { onChange() }
            }
            .tint(.yellow)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// 현재 설정으로 배경이 얼마나 흐려지는지 숫자로 보여준다
struct BokehInfoRow: View {
    let settings: DevelopSettings
    let shot: Shot

    private var focus: Float {
        settings.focusDistance > 0.02 ? settings.focusDistance : shot.focusDistance
    }

    private var effectiveFocal: Float {
        let captured = (shot.focalLength35 > 1 ? shot.focalLength35 : 24)
            * max(shot.captureZoom, 1)
        return settings.effectiveFocalLength(captured: captured)
    }

    private var maxBlur: Float {
        Renderer.maxCoCPixels(settings: settings, focus: max(focus, 0.3),
                              focalLength: effectiveFocal,
                              imageWidth: Float(max(shot.pixelWidth, 4032)))
    }

    var body: some View {
        HStack(spacing: 14) {
            info("화각", String(format: "%.0fmm", effectiveFocal))
            info("조리개", String(format: "f/%.1f", settings.fNumber))
            info("초점", focus > 0.02 ? String(format: "%.2fm", focus) : "자동")
            info("최대 흐림", String(format: "%.0fpx", maxBlur))
            info("날", settings.apertureBlades == 0 ? "원형" : "\(settings.apertureBlades)장")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.05))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 사진 정보

struct ShotInfoView: View {
    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss
    let shot: Shot

    var body: some View {
        NavigationStack {
            List {
                Section("촬영") {
                    row("해상도", "\(shot.pixelWidth)×\(shot.pixelHeight)")
                    row("형식", shot.isProRAW ? "Apple ProRAW (DNG)" : "HEIF")
                    row("ISO", shot.iso > 0 ? "\(Int(shot.iso))" : "—")
                    row("셔터", shot.shutterText)
                    row("조리개", shot.deviceAperture > 0 ? String(format: "f/%.1f", shot.deviceAperture) : "—")
                    row("환산 화각", shot.focalLength35 > 0 ? "\(Int(shot.focalLength35))mm" : "—")
                    row("촬영 시각", shot.date.formatted(date: .abbreviated, time: .shortened))
                }
                Section("깊이") {
                    row("LiDAR 깊이", shot.hasDepth ? "\(shot.depthWidth)×\(shot.depthHeight)" : "없음")
                    row("인물 매트", shot.hasMatte ? "있음" : "없음")
                    row("초점 거리", shot.focusDistance > 0 ? String(format: "%.2fm", shot.focusDistance) : "—")
                }
                Section("저장") {
                    row("원본 RAW", store.hasRaw(shot) ? "보관 중" : "삭제됨")
                    row("현상 결과", shot.exportedAt != nil ? "있음" : "없음")
                    row("차지하는 용량",
                        ByteCountFormatter.string(fromByteCount: store.size(of: shot), countStyle: .file))
                }
            }
            .navigationTitle("사진 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}
