import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPurge = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("내보내기 크기", selection: Binding(
                        get: { processor.exportSize },
                        set: { processor.exportSize = $0 })) {
                        ForEach(ExportSize.allCases) { size in
                            VStack(alignment: .leading) {
                                Text(size.title)
                                Text(size.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("내보내기 크기")
                } footer: {
                    Text("아이폰 48MP 센서는 네 화소를 하나로 묶는 방식이라, 실제로 분해되는 해상도는 24MP 쪽에 가까워요. 24MP가 화질과 용량의 균형점이고 a7 III와 같은 화소예요.")
                }

                Section {
                    Toggle("촬영 후 자동 현상", isOn: $store.autoExport)
                    Toggle("사진 앱에도 저장", isOn: $store.saveToPhotos)
                    HStack {
                        Text("JPEG 품질")
                        Spacer()
                        Text("\(Int(store.jpegQuality * 100))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $store.jpegQuality, in: 0.7...1.0, step: 0.01)
                } header: {
                    Text("현상")
                } footer: {
                    Text("자동 현상을 켜면 셔터를 누른 뒤 백그라운드에서 바로 현상돼요. 꺼두면 보관함에서 원하는 사진만 골라 현상할 수 있어요.")
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
                } footer: {
                    Text("기본 프로파일 'Chan'은 a7 III + FE 50mm F1.8로 찍은 사진 171장의 Lightroom 보정값 평균이에요. 하이라이트 −75 · 섀도우 +55 · 생동감 +12.")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .confirmationDialog("현상이 끝난 사진의 원본 RAW를 모두 지울까요?",
                                isPresented: $confirmPurge, titleVisibility: .visible) {
                Button("원본 RAW 삭제", role: .destructive) { store.purgeExportedRaws() }
            } message: {
                Text("현상된 JPEG는 그대로 남아요.")
            }
        }
    }
}
