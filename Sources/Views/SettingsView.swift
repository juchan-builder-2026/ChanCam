import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var camera: Camera

    @State private var confirmPurge = false
    @State private var showSensor = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("현재 등급", value: processor.recipe.tier.name)
                    LabeledContent("출력 해상도", value: "\(processor.recipe.outputSize)MP")
                    LabeledContent("지시서", value: processor.recipe.summary)
                        .font(.caption)
                } header: {
                    Text("현상")
                } footer: {
                    Text("현상은 자동으로 돌지 않아요. 촬영 화면 아래 '현상 N장' 버튼이나 보관함에서 시작하면, 그 화면에서 품질과 옵션을 고르고 진행률·CPU·GPU·메모리를 보면서 돌려요.")
                }

                Section {
                    Button {
                        showSensor = true
                    } label: {
                        Label("센서 테스터 열기", systemImage: "waveform.badge.magnifyingglass")
                    }
                    if processor.gpuScore > 0 {
                        LabeledContent("측정된 GPU 처리량",
                                       value: String(format: "%.1f G탭/초", processor.gpuScore / 1e9))
                    }
                    LabeledContent("활성 카메라", value: camera.capabilities.deviceName)
                    LabeledContent("깊이 스트림",
                                   value: camera.capabilities.streamingDepth ? "사용 중" : "사용 안 함")
                    LabeledContent("깊이 프레임", value: "\(camera.depthFrames)")
                } header: {
                    Text("하드웨어")
                } footer: {
                    Text("센서 테스터는 이 기기의 카메라·GPU·신경망 능력을 하드웨어에 직접 물어봐서 보여줘요. LiDAR 깊이가 실제로 흐르고 있는지도 거기서 확인할 수 있어요.")
                }

                Section {
                    Toggle("현상 후 원본 RAW 보관", isOn: $store.keepRawAfterExport)
                    HStack {
                        Text("사용 중")
                        Spacer()
                        Text(store.usedText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("남은 공간")
                        Spacer()
                        Text(store.freeText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("현상 대기")
                        Spacer()
                        Text("\(store.undeveloped.count)장").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        confirmPurge = true
                    } label: {
                        Label("현상 끝난 원본 RAW 비우기", systemImage: "trash")
                    }
                } header: {
                    Text("저장 공간")
                } footer: {
                    Text("48MP ProRAW 원본은 한 장에 70~100MB예요. 보관을 끄면 현상이 끝나는 즉시 원본을 지우고 결과 JPEG만 남겨서 용량을 10분의 1 이하로 줄여요. 대신 나중에 다시 현상할 수는 없어요.")
                }

                Section {
                    LabeledContent("버전",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("기본 프로파일", value: "Chan")
                    LabeledContent("현상 엔진", value: "레이트레이싱 + 신경망")
                } footer: {
                    Text("기본 프로파일 'Chan'은 a7 III + FE 50mm F1.8로 찍은 사진 171장의 Lightroom 보정값 평균이에요. 하이라이트 −75 · 섀도우 +55 · 생동감 +12.")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .sheet(isPresented: $showSensor) { SensorTestView(camera: camera) }
            .confirmationDialog("현상이 끝난 사진의 원본 RAW를 모두 지울까요?",
                                isPresented: $confirmPurge, titleVisibility: .visible) {
                Button("원본 RAW 삭제", role: .destructive) { store.purgeExportedRaws() }
            } message: {
                Text("현상된 JPEG는 그대로 남아요.")
            }
        }
    }
}
