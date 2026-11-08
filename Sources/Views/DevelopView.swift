import SwiftUI

/// 현상 화면. v1.2 부터 현상은 여기서만 시작된다 —
/// 품질과 옵션을 직접 고르고, 시작을 누르면 진행률과 CPU·GPU·메모리가 실시간으로 보인다.
struct DevelopView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @ObservedObject private var monitor = SystemMonitor.shared
    @Environment(\.dismiss) private var dismiss

    let shots: [Shot]

    @State private var benchmarking = false

    private var recipe: DevelopRecipe { processor.recipe }

    var body: some View {
        NavigationStack {
            Group {
                if let batch = processor.batch {
                    ProgressStage(batch: batch, monitor: monitor)
                } else {
                    optionsStage
                }
            }
            .navigationTitle(processor.batch == nil ? "현상 설정" : "현상 중")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if processor.batch == nil {
                    ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                } else if processor.batch?.isRunning == false {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { processor.clearBatch(); dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(processor.batch?.isRunning == true)
        }
        .task { await benchmarkIfNeeded() }
    }

    // MARK: - 옵션

    private var optionsStage: some View {
        VStack(spacing: 0) {
            Form {
                tierSection
                outputSection
                opticsSection
                neuralSection
                toneSection
                subjectSection
                estimateSection
            }
            startBar
        }
    }

    private var tierSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DevelopTier.allCases) { tier in
                        TierCard(tier: tier, selected: recipe.tier == tier) {
                            var next = processor.recipe
                            next.applyTier(tier)
                            processor.recipe = next
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text("얼마나 빡세게 현상할지")
        } footer: {
            Text(recipe.tier.detail + (recipe.isCustom ? " · 세부 값을 직접 바꿨어요" : ""))
        }
    }

    private var outputSection: some View {
        Section {
            Picker("해상도", selection: Binding(
                get: { processor.recipe.outputSize },
                set: { processor.recipe.outputSize = $0 })) {
                Text("12MP").tag(12)
                Text("24MP").tag(24)
                Text("48MP").tag(48)
            }
            .pickerStyle(.segmented)

            LabeledSlider(title: "JPEG 품질", value: Binding(
                get: { processor.recipe.jpegQuality },
                set: { processor.recipe.jpegQuality = $0 }),
                          range: 0.7...1.0, step: 0.01,
                          text: "\(Int(recipe.jpegQuality * 100))")

            Toggle("사진 앱에도 저장", isOn: Binding(
                get: { processor.recipe.saveToPhotos },
                set: { processor.recipe.saveToPhotos = $0 }))
            Toggle("현상 후 원본 RAW 보관", isOn: Binding(
                get: { processor.recipe.keepRaw },
                set: { processor.recipe.keepRaw = $0 }))
        } header: {
            Text("출력")
        } footer: {
            Text("아이폰 48MP 센서는 네 화소를 하나로 묶는 방식이라 실제 분해 해상도는 24MP 쪽에 가까워요. 24MP가 화질과 용량의 균형점이에요.")
        }
    }

    private var opticsSection: some View {
        Section {
            Toggle("레이트레이싱 피사계심도", isOn: Binding(
                get: { processor.recipe.rayTracedDoF },
                set: { processor.recipe.rayTracedDoF = $0 }))
            if recipe.rayTracedDoF {
                LabeledSlider(title: "조리개 광선 수", value: Binding(
                    get: { Double(processor.recipe.apertureSamples) },
                    set: { processor.recipe.apertureSamples = Int($0) }),
                              range: 8...192, step: 8, text: "\(recipe.apertureSamples)")
                LabeledSlider(title: "마칭 스텝", value: Binding(
                    get: { Double(processor.recipe.marchSteps) },
                    set: { processor.recipe.marchSteps = Int($0) }),
                              range: 6...48, step: 2, text: "\(recipe.marchSteps)")
            }
            Toggle("하이라이트 산란 (보케 볼)", isOn: Binding(
                get: { processor.recipe.highlightScatter },
                set: { processor.recipe.highlightScatter = $0 }))
            if recipe.highlightScatter {
                LabeledSlider(title: "산란 임계", value: Binding(
                    get: { Double(processor.recipe.scatterThreshold) },
                    set: { processor.recipe.scatterThreshold = Float($0) }),
                              range: 1.0...6.0, step: 0.1,
                              text: String(format: "%.1f", recipe.scatterThreshold))
            }
            Toggle("광원 추적 (고스트·회절)", isOn: Binding(
                get: { processor.recipe.lightTransport },
                set: { processor.recipe.lightTransport = $0 }))
            if recipe.lightTransport {
                LabeledSlider(title: "광원 인정 밝기", value: Binding(
                    get: { Double(processor.recipe.lightThreshold) },
                    set: { processor.recipe.lightThreshold = Float($0) }),
                              range: 1.2...12, step: 0.2,
                              text: String(format: "%.1f", recipe.lightThreshold))
            }
            LabeledContent("보케 작업 해상도", value: "\(recipe.bokehSide)px")
            LabeledContent("픽셀당 광선 탭", value: "\(recipe.tapsPerPixel)")
        } header: {
            Text("광학 시뮬레이션")
        } footer: {
            Text("조리개 광선 수를 올리면 보케 디스크의 얼룩이 줄어요. 그림의 성격은 안 바뀌고 샘플링 노이즈만 줄어드는 거예요. 마칭 스텝은 피사체와 배경이 겹치는 경계의 가려짐 정확도를 정해요.\n\n광원 추적은 밝은 점광원이 있을 때만 보여요. 세기는 사진별 편집 화면의 '광학' 탭에서 조절해요.")
        }
    }

    private var neuralSection: some View {
        Section {
            Toggle("신경망 디테일", isOn: Binding(
                get: { processor.recipe.neuralDetail },
                set: { processor.recipe.neuralDetail = $0 }))
            if recipe.neuralDetail {
                Picker("스케일", selection: Binding(
                    get: { processor.recipe.neuralScales },
                    set: { processor.recipe.neuralScales = $0 })) {
                    Text("1단").tag(1)
                    Text("2단").tag(2)
                    Text("3단").tag(3)
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "디테일 복원", value: Binding(
                    get: { Double(processor.recipe.neuralStrength) },
                    set: { processor.recipe.neuralStrength = Float($0) }),
                              range: 0...1.5, step: 0.05,
                              text: String(format: "%.2f", recipe.neuralStrength))
                LabeledSlider(title: "노이즈 억제", value: Binding(
                    get: { Double(processor.recipe.neuralDenoise) },
                    set: { processor.recipe.neuralDenoise = Float($0) }),
                              range: 0...1, step: 0.05,
                              text: String(format: "%.2f", recipe.neuralDenoise))
                LabeledSlider(title: "분할 정규화", value: Binding(
                    get: { Double(processor.recipe.neuralInhibition) },
                    set: { processor.recipe.neuralInhibition = Float($0) }),
                              range: 0...2, step: 0.05,
                              text: String(format: "%.2f", recipe.neuralInhibition))
                LabeledSlider(title: "경계 강조", value: Binding(
                    get: { Double(processor.recipe.neuralEdgeBoost) },
                    set: { processor.recipe.neuralEdgeBoost = Float($0) }),
                              range: 0...1, step: 0.05,
                              text: String(format: "%.2f", recipe.neuralEdgeBoost))
            }
        } header: {
            Text("신경망")
        } footer: {
            Text("3층 합성곱 블록이에요. 1층이 8개 방향 필터로 응답을 뽑고, 2층이 '한 방향으로만 센 응답'(=경계)과 '모든 방향이 비슷한 응답'(=센서 노이즈)을 분할 정규화로 가려내고, 3층이 경계만 되살려요.\n\n가중치는 학습한 게 아니라 조향 기저로 해석적으로 정했어요. 그래서 모델 파일이 없고, 결과가 항상 같고, 아주 빨라요. 스케일을 올리면 더 큰 구조까지 같은 판단을 받아요.")
        }
    }

    private var toneSection: some View {
        Section {
            Picker("톤 밴드", selection: Binding(
                get: { processor.recipe.toneBands },
                set: { processor.recipe.toneBands = $0 })) {
                Text("2밴드").tag(2)
                Text("3밴드").tag(3)
            }
            .pickerStyle(.segmented)
            Toggle("장면 분석 (자동 노출·블랙·화이트)", isOn: Binding(
                get: { processor.recipe.sceneAnalysis },
                set: { processor.recipe.sceneAnalysis = $0 }))
        } header: {
            Text("톤매핑")
        } footer: {
            Text("3밴드는 로그 휘도를 '아주 넓은 영역 / 중간 영역 / 픽셀'로 나눠서, 전역 톤 커브를 가장 넓은 밴드에만 걸어요. 그래서 하이라이트를 −75까지 눌러도 중간톤이 평평해지지 않아요. 기본 사진 앱의 그 'HDR 티'가 이걸 안 해서 생기는 거예요.")
        }
    }

    private var subjectSection: some View {
        Section {
            Toggle("Vision 피사체 분리", isOn: Binding(
                get: { processor.recipe.subjectMask },
                set: { processor.recipe.subjectMask = $0 }))
        } header: {
            Text("피사체")
        } footer: {
            Text("애플이 학습시킨 피사체 분리 모델로 깊이 경계를 다듬어요. LiDAR 는 머리카락 같은 얇은 경계를 못 읽는데 이쪽은 읽어요. 결과는 파일로 캐시해서 두 번째 현상부터는 공짜예요.")
        }
    }

    private var estimateSection: some View {
        Section {
            LabeledContent("대상", value: "\(shots.count)장")
            if processor.gpuScore > 0 {
                let per = recipe.estimatedSeconds(gpuScore: processor.gpuScore)
                LabeledContent("예상 시간",
                               value: DevelopView.duration(per * Double(shots.count)))
                LabeledContent("한 장당", value: DevelopView.duration(per))
            } else {
                HStack {
                    Text("예상 시간")
                    Spacer()
                    if benchmarking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("GPU 측정 필요").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("중간 버퍼", value: SystemMonitor.text(bufferBytes))
            LabeledContent("앱 메모리 한도", value: SystemMonitor.text(memoryLimit))
            if memoryTight {
                Label("이 해상도·등급은 메모리 한도에 가까워요. 48MP + 극한은 중간에 강제 종료될 수 있어요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("예상")
        } footer: {
            Text("예상 시간은 이 기기에서 실제로 측정한 GPU 처리량(" + scoreText + ")으로 계산해요. 열이 오르면 느려지니 눈금으로만 보세요.")
        }
    }

    private var scoreText: String {
        let score = processor.gpuScore
        guard score > 0 else { return "미측정" }
        return String(format: "%.1f G탭/초", score / 1e9)
    }

    private var bufferBytes: UInt64 {
        UInt64(max(recipe.estimatedBytes, 0))
    }

    private var memoryLimit: UInt64 {
        if monitor.ramLimit > 0 { return monitor.ramLimit }
        return SystemMonitor.memoryLimit(current: SystemMonitor.footprint())
    }

    private var memoryTight: Bool {
        let limit = memoryLimit
        guard limit > 0 else { return false }
        return Double(recipe.estimatedBytes) > Double(limit) * 0.62
    }

    private var startBar: some View {
        VStack(spacing: 8) {
            Text(recipe.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                processor.start(shots)
            } label: {
                Label("현상 시작 · \(shots.count)장", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            .disabled(shots.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
    }

    // MARK: - 도우미

    private func benchmarkIfNeeded() async {
        guard processor.gpuScore <= 0, !benchmarking else { return }
        benchmarking = true
        let score = await Task.detached(priority: .userInitiated) { () -> Double? in
            Renderer.shared?.benchmark(side: 768, rounds: 32)?.tapsPerSecond
        }.value
        if let score, score.isFinite, score > 0 { processor.gpuScore = score }
        benchmarking = false
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return String(format: "%.1f초", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)분 \(rest)초"
    }
}

// MARK: - 등급 카드

private struct TierCard: View {
    let tier: DevelopTier
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: tier.symbol).font(.system(size: 18))
                Text(tier.name).font(.system(size: 13, weight: .bold))
                Text(tier.apertureSamples == 0 ? "RT 끔" : "\(tier.apertureSamples)광선")
                    .font(.system(size: 9.5))
                    .foregroundStyle(selected ? .black.opacity(0.65) : .secondary)
            }
            .frame(width: 78, height: 76)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.yellow : Color.primary.opacity(0.08)))
            .foregroundStyle(selected ? .black : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 라벨 붙은 슬라이더

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $value, in: range, step: step)
                .tint(.yellow)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 진행 화면

private struct ProgressStage: View {
    let batch: BatchProgress
    @ObservedObject var monitor: SystemMonitor
    @EnvironmentObject private var processor: Processor

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                percentRing
                stageLine
                graphs
                statsGrid
                if batch.isRunning {
                    Button(role: .destructive) {
                        processor.cancel()
                    } label: {
                        Label("취소", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(batch.cancelled)
                } else {
                    doneSummary
                }
            }
            .padding(18)
        }
    }

    private var percentRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(batch.overall, 0.002))
                .stroke(batch.cancelled ? Color.orange : Color.yellow,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: batch.overall)
            VStack(spacing: 2) {
                Text("\(Int(batch.overall * 100))")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 180, height: 180)
    }

    private var stageLine: some View {
        VStack(spacing: 4) {
            Text(batch.stage)
                .font(.headline)
            Text("\(min(batch.finished + (batch.isRunning ? 1 : 0), batch.total)) / \(batch.total)장")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if batch.isRunning {
                ProgressView(value: batch.fraction)
                    .tint(.yellow)
                    .frame(maxWidth: 240)
            }
        }
    }

    private var graphs: some View {
        VStack(spacing: 10) {
            MonitorGraph(title: "CPU", samples: monitor.cpu, tint: .cyan,
                         value: String(format: "%.0f%% · %.1f코어",
                                       monitor.cpuNow * 100, monitor.cpuCores))
            MonitorGraph(title: "GPU", samples: monitor.gpu, tint: .yellow,
                         value: String(format: "%.0f%%", monitor.gpuNow * 100))
            MonitorGraph(title: "메모리", samples: monitor.ram, tint: .pink,
                         value: SystemMonitor.text(monitor.ramBytes))
        }
    }

    private var statsGrid: some View {
        let gpu = GPUClock.shared.stats
        return VStack(spacing: 0) {
            statRow("경과", DevelopView.duration(batch.elapsed))
            Divider()
            statRow("남은 시간", batch.remaining.map(DevelopView.duration) ?? "—")
            Divider()
            statRow("GPU 실제 작업", DevelopView.duration(gpu.seconds))
            Divider()
            statRow("명령 버퍼", "\(gpu.buffers)개")
            Divider()
            statRow("메모리 최고점", SystemMonitor.text(monitor.ramPeak))
            Divider()
            HStack {
                Text("열 상태").foregroundStyle(.secondary)
                Spacer()
                Text(monitor.thermal.label).foregroundStyle(monitor.thermal.tint)
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var doneSummary: some View {
        let perShot = batch.completedSeconds.isEmpty
            ? 0
            : batch.completedSeconds.reduce(0, +) / Double(batch.completedSeconds.count)
        return VStack(spacing: 10) {
            Label(batch.cancelled ? "취소했어요"
                  : (batch.failed > 0 ? "\(batch.failed)장 실패" : "현상 완료"),
                  systemImage: batch.cancelled ? "stop.circle"
                  : (batch.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle.fill"))
                .font(.headline)
                .foregroundStyle(batch.cancelled ? .orange : (batch.failed > 0 ? .orange : .green))
            if perShot > 0 {
                Text("한 장 평균 \(DevelopView.duration(perShot))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - 그래프

struct MonitorGraph: View {
    let title: String
    let samples: [Double]
    let tint: Color
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    // 25% 격자
                    ForEach(1..<4) { line in
                        let y = geo.size.height * (1 - Double(line) / 4)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                    }
                    if samples.count > 1 {
                        shape(in: geo.size, closed: true)
                            .fill(LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                        shape(in: geo.size, closed: false)
                            .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    }
                }
            }
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        }
    }

    private func shape(in size: CGSize, closed: Bool) -> Path {
        Path { path in
            let count = max(SystemMonitor.capacity, samples.count)
            let dx = size.width / Double(count - 1)
            // 오른쪽 끝이 현재 시점 — 샘플이 모자라면 왼쪽을 비운다
            let offset = Double(count - samples.count) * dx
            for (index, sample) in samples.enumerated() {
                let x = offset + Double(index) * dx
                let y = size.height * (1 - min(max(sample, 0), 1))
                if index == 0 {
                    if closed { path.move(to: CGPoint(x: x, y: size.height)) }
                    else { path.move(to: CGPoint(x: x, y: y)) }
                    if closed { path.addLine(to: CGPoint(x: x, y: y)) }
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            if closed, let last = samples.indices.last {
                let x = offset + Double(last) * dx
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.closeSubpath()
            }
        }
    }
}
