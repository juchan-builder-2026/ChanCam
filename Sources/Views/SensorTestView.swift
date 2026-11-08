import SwiftUI

/// 센서 테스터 — 이 기기가 실제로 뭘 할 수 있는지 하드웨어에 직접 물어본다.
/// 추측값은 없고, 못 알아내는 항목은 "확인 불가"로 남긴다.
struct SensorTestView: View {
    @ObservedObject var camera: Camera
    @ObservedObject private var monitor = SystemMonitor.shared
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [SensorProbe.Group] = []
    @State private var benchmark: SensorProbe.Benchmark?
    @State private var benchmarking = false
    @State private var memoryResults: [String] = []
    @State private var memoryTesting = false

    var body: some View {
        NavigationStack {
            List {
                liveSection
                depthSection
                benchmarkSection
                memorySection
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            RowView(row: row)
                        }
                    } header: {
                        Label(group.title, systemImage: group.symbol)
                    } footer: {
                        if let note = group.note {
                            Text(note)
                        }
                    }
                }
            }
            .navigationTitle("센서 테스터")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { monitor.stop(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onAppear {
                monitor.start()
                reload()
            }
            .onDisappear { monitor.stop() }
        }
    }

    // MARK: - 실시간

    private var liveSection: some View {
        Section {
            MonitorGraph(title: "CPU", samples: monitor.cpu, tint: .cyan,
                         value: String(format: "%.0f%% · %.1f코어",
                                       monitor.cpuNow * 100, monitor.cpuCores))
            MonitorGraph(title: "GPU", samples: monitor.gpu, tint: .yellow,
                         value: String(format: "%.0f%%", monitor.gpuNow * 100))
            MonitorGraph(title: "메모리", samples: monitor.ram, tint: .pink,
                         value: SystemMonitor.text(monitor.ramBytes))
        } header: {
            Label("실시간", systemImage: "waveform.path.ecg")
        } footer: {
            Text("GPU 사용률은 추정이 아니라 실측이에요. 우리가 쏘는 Metal 명령 버퍼마다 GPU 가 실제로 돌아간 시간을 받아서 벽시계 시간으로 나눈 값이에요. iOS 에는 전체 GPU 사용률 API 가 없어서, 다른 앱이 쓰는 몫은 여기 안 나와요.")
        }
    }

    // MARK: - 깊이 스트림

    private var depthSection: some View {
        let group = SensorProbe.depthGroup(fps: camera.depthFPS,
                                           coverage: camera.depthCoverage,
                                           distance: camera.liveFocusDistance,
                                           frames: camera.depthFrames,
                                           streaming: camera.capabilities.streamingDepth)
        return Section {
            ForEach(group.rows) { row in RowView(row: row) }
            if camera.depthFrames == 0 {
                Label("촬영 화면을 열어 둔 상태에서만 깊이가 흘러요. 이 화면을 닫고 뷰파인더를 몇 초 보고 다시 들어오세요.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(group.title, systemImage: group.symbol)
        } footer: {
            if let note = group.note { Text(note) }
        }
    }

    // MARK: - GPU 벤치마크

    private var benchmarkSection: some View {
        Section {
            if let benchmark {
                LabeledContent("처리량", value: benchmark.scoreText)
                LabeledContent("GPU 시간", value: String(format: "%.1f ms", benchmark.gpuSeconds * 1000))
                LabeledContent("벽시계", value: String(format: "%.1f ms", benchmark.milliseconds))
                LabeledContent("작업량",
                               value: String(format: "%.1fM 픽셀 × %d회",
                                             Double(benchmark.pixels) / 1e6, benchmark.rounds))
            }
            Button {
                run()
            } label: {
                HStack {
                    Label(benchmark == nil ? "GPU 측정" : "다시 측정", systemImage: "speedometer")
                    if benchmarking {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(benchmarking)
        } header: {
            Label("GPU 처리량", systemImage: "speedometer")
        } footer: {
            Text("현상에서 가장 무거운 연산(텍스처 샘플 + 초월함수)을 같은 비율로 2048×2048 에 돌려서 초당 몇 번 처리하는지 실측해요. 이 값이 현상 설정 화면의 예상 시간 계산에 쓰여요. 열이 오르면 값이 떨어지는 게 정상이에요.")
        }
    }

    // MARK: - 메모리 테스트

    private var memorySection: some View {
        Section {
            ForEach(memoryResults, id: \.self) { line in
                Text(line).font(.caption).monospaced()
            }
            Button {
                testMemory()
            } label: {
                HStack {
                    Label("풀해상도 버퍼 할당 시험", systemImage: "memorychip")
                    if memoryTesting {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(memoryTesting)
        } header: {
            Label("메모리", systemImage: "memorychip")
        } footer: {
            Text("12 / 24 / 48MP 각각에 대해 현상이 실제로 쓰는 풀해상도 중간 버퍼 두 장을 정말로 할당해 봐요. 48MP 가 실패하면 그 해상도로는 현상이 중간에 죽어요.")
        }
    }

    // MARK: - 동작

    private func reload() {
        var list: [SensorProbe.Group] = [
            SensorProbe.deviceGroup(),
            SensorProbe.gpuGroup(),
            SensorProbe.neuralGroup(),
            SensorProbe.photoGroup(camera.capabilities),
        ]
        list.append(contentsOf: SensorProbe.cameraGroups())
        groups = list
        camera.refreshDepthStats()
    }

    private func run() {
        benchmarking = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> SensorProbe.Benchmark? in
                Renderer.shared?.benchmark(side: 2048, rounds: 48)
            }.value
            benchmark = result
            if let result, result.tapsPerSecond.isFinite, result.tapsPerSecond > 0 {
                processor.gpuScore = result.tapsPerSecond
            }
            benchmarking = false
        }
    }

    private func testMemory() {
        memoryTesting = true
        memoryResults = []
        Task {
            for size in [4032, 5712, 8064] {
                let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                    SensorProbe.memoryTest(longSide: size)
                }.value
                let mp = Int((Double(size) * Double(size) * 0.75 / 1_000_000).rounded())
                memoryResults.append("\(mp)MP · \(result.0 ? "OK" : "실패") — \(result.1)")
            }
            memoryTesting = false
        }
    }
}

private struct RowView: View {
    let row: SensorProbe.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(row.value)
                .font(.subheadline)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch row.good {
        case .some(true): return .green
        case .some(false): return .orange
        case nil: return .primary
        }
    }
}
