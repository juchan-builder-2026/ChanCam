import SwiftUI

/// 현상이 실제로 무엇을 보고 있는지 눈으로 확인하는 화면.
///
/// 결과 사진만 보고 "뭔가 이상한데 왜지"를 추리하는 건 느리고 자주 틀린다.
/// 깊이맵과 착란원을 그대로 띄우면 스크린샷 한 장으로 끝난다.
struct DiagnosticView: View {
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss

    let shot: Shot
    let settings: DevelopSettings

    @State private var result: Renderer.Diagnostics?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("깊이와 착란원을 뽑는 중")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let result {
                    content(result)
                } else {
                    ContentUnavailableView("진단할 수 없어요", systemImage: "exclamationmark.triangle",
                                           description: Text("원본이 없거나 GPU를 쓸 수 없어요."))
                }
            }
            .navigationTitle("진단")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        result = await processor.diagnose(shot: shot, settings: settings)
        loading = false
    }

    @ViewBuilder
    private func content(_ d: Renderer.Diagnostics) -> some View {
        List {
            Section {
                numbers(d)
            } header: {
                Text("지금 쓰이는 값")
            } footer: {
                Text(verdict(d))
            }

            if let image = d.coc {
                Section {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    Text("착란원 (흐림 지도)")
                } footer: {
                    Text("초록 = 초점이 맞은 곳 · 빨강 = 초점면 앞 · 파랑 = 초점면 뒤. 색이 진할수록 많이 흐려져요.\n\n초록이 아예 안 보이면 초점면에 아무것도 없다는 뜻이에요 — 편집 화면에서 피사체를 탭해 초점을 다시 잡으세요.")
                }
            }

            if let image = d.depthRaw {
                Section {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    Text("LiDAR 깊이 (원본)")
                } footer: {
                    Text("흰색 = 가까움 · 검정 = 멂 · 빨강 = 못 읽은 곳. LiDAR 는 5m 쯤부터 아무것도 못 읽어서 하늘과 먼 배경은 빨갛게 나오는 게 정상이에요.")
                }
            }

            if let image = d.depthFilled {
                Section {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    Text("깊이 (구멍 메운 뒤)")
                } footer: {
                    Text("작은 구멍은 주변 값으로 메우고, 큰 구멍은 무한대(검정)로 둬요. 여기서 하늘이 흰색(=가까움)으로 보이면 그게 버그예요.")
                }
            }

            if let image = d.matte {
                Section {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    Text("피사체 마스크")
                } footer: {
                    Text("흰색이 피사체예요. 엉뚱한 데가 희면 경계가 그쪽으로 끌려가요.")
                }
            }
        }
    }

    @ViewBuilder
    private func numbers(_ d: Renderer.Diagnostics) -> some View {
        row("초점 거리", String(format: "%.2f m", d.focusDistance))
        row("환산 화각", String(format: "%.0f mm", d.effectiveFocal))
        row("조리개", String(format: "f/%.1f", settings.fNumber))
        row("최대 착란원", String(format: "%.0f px", d.maxRadius))
        row("풀해상도 처리 한계", String(format: "%.0f px", d.nearLimit))
        row("깊이 유효 비율", String(format: "%.0f%%", d.validRatio * 100),
            good: d.validRatio > 0.25)
        row("깊이 범위",
            d.farDepth > 0 ? String(format: "%.2f – %.2f m", d.nearDepth, d.farDepth) : "없음")
        row("자동 노이즈 제거", String(format: "%.2f", d.autoNR), good: d.autoNR < 0.35)
        row("보케 작업 해상도", "\(d.bokehSide)px / 출력 \(d.outputLong)px")
    }

    /// 숫자만 보고 바로 알 수 있는 것들을 말로 적어 준다
    private func verdict(_ d: Renderer.Diagnostics) -> String {
        var lines: [String] = []
        if d.validRatio < 0.12 {
            lines.append("깊이 유효 비율이 너무 낮아요. LiDAR 가 거의 못 읽은 장면이라 보케가 엉성할 수밖에 없어요.")
        }
        if d.focusDistance < 0.35 {
            lines.append("초점이 아주 가까워요. 이 거리에서 f/\(String(format: "%.1f", settings.fNumber))면 피사계심도가 몇 cm 뿐이라, 거의 모든 게 흐려지는 게 물리적으로 맞아요. 조리개를 조이거나 초점을 더 먼 데로 잡아 보세요.")
        }
        if d.maxRadius > 120 {
            lines.append("흐림이 아주 커요(최대 \(Int(d.maxRadius))px). 보케 배율을 낮추거나 조리개를 조이면 자연스러워져요.")
        }
        if d.nearDepth > 0, d.farDepth > 0, d.farDepth / max(d.nearDepth, 0.01) < 1.6 {
            lines.append("장면 전체가 비슷한 거리에 있어요. 이런 장면은 원래 흐림이 거의 안 생겨요.")
        }
        if lines.isEmpty {
            lines.append("눈에 띄는 이상은 없어요. 착란원 지도에 초록(초점)이 피사체 위에 있는지 확인해 보세요.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func tint(_ good: Bool?) -> Color {
        switch good {
        case .some(true): return .green
        case .some(false): return .orange
        case nil: return .primary
        }
    }

    private func row(_ title: String, _ value: String, good: Bool? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint(good))
        }
        .font(.subheadline)
    }
}
