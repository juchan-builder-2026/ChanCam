import SwiftUI
import UIKit

/// 목록 썸네일 캐시
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 160 }

    func image(for shot: Shot) -> UIImage? {
        let key = shot.id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let store = ShotStore.shared
        let url = store.exportURL(shot) ?? store.previewURL(shot)
        guard let url, let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        let thumb = ShotStore.downscale(image, maxSide: 600)
        cache.setObject(thumb, forKey: key)
        return thumb
    }

    func drop(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    let onEdit: (Shot) -> Void

    @State private var showOnlyFavorites = false
    @State private var confirmPurge = false
    @State private var purgeResult: String?

    private var shown: [Shot] {
        showOnlyFavorites ? store.shots.filter(\.isFavorite) : store.shots
    }

    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label(showOnlyFavorites ? "즐겨찾기 없음" : "사진 없음", systemImage: "photo.stack")
                    } description: {
                        Text(showOnlyFavorites ? "하트를 누른 사진이 여기 모여요." : "촬영 버튼을 눌러 첫 장을 찍어보세요.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(shown) { shot in
                                GridCell(shot: shot, state: processor.state(shot.id))
                                    .onTapGesture { dismiss(); onEdit(shot) }
                                    .contextMenu {
                                        Button {
                                            store.toggleFavorite(shot.id)
                                        } label: {
                                            Label(shot.isFavorite ? "즐겨찾기 해제" : "즐겨찾기",
                                                  systemImage: shot.isFavorite ? "heart.slash" : "heart")
                                        }
                                        Button {
                                            processor.enqueue(shot)
                                        } label: {
                                            Label("다시 현상", systemImage: "arrow.clockwise")
                                        }
                                        .disabled(!store.hasRaw(shot))
                                        Divider()
                                        Button(role: .destructive) {
                                            ThumbCache.shared.drop(shot.id)
                                            store.delete(shot)
                                        } label: {
                                            Label("삭제", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 3)

                        StorageFooter(confirmPurge: $confirmPurge, purgeResult: purgeResult)
                            .padding(.top, 18)
                            .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle("보관함")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Material.bar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnlyFavorites.toggle()
                    } label: {
                        Image(systemName: showOnlyFavorites ? "heart.fill" : "heart")
                    }
                }
            }
            .confirmationDialog("현상이 끝난 사진의 원본 RAW를 모두 지울까요?",
                                isPresented: $confirmPurge, titleVisibility: .visible) {
                Button("원본 RAW 삭제", role: .destructive) {
                    let freed = store.purgeExportedRaws()
                    purgeResult = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file) + " 확보했어요"
                }
            } message: {
                Text("현상된 JPEG는 그대로 남아요. 지운 뒤에는 그 사진을 다시 현상할 수 없어요.")
            }
        }
    }
}

private struct GridCell: View {
    let shot: Shot
    let state: JobState?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(Rectangle())
    }

    private var content: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image = ThumbCache.shared.image(for: shot) {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if let state, state.isActive {
                Rectangle().fill(.black.opacity(0.55))
                VStack(spacing: 5) {
                    ProgressView(value: max(state.progress, 0.03)).tint(.yellow)
                        .frame(width: 58)
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 3) {
                if shot.isFavorite {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
                if shot.hasDepth {
                    Image(systemName: "cube.transparent").foregroundStyle(.cyan)
                }
                if shot.exportedAt != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.system(size: 9))
            .padding(4)
            .shadow(radius: 2)
        }
    }
}

private struct StorageFooter: View {
    @EnvironmentObject private var store: ShotStore
    @Binding var confirmPurge: Bool
    let purgeResult: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("사용 중", systemImage: "externaldrive.fill")
                Spacer()
                Text(store.usedText).monospacedDigit()
            }
            HStack {
                Label("남은 공간", systemImage: "internaldrive")
                Spacer()
                Text(store.freeText).monospacedDigit().foregroundStyle(.secondary)
            }
            if let purgeResult {
                Text(purgeResult).font(.caption).foregroundStyle(.green)
            }
            Button {
                confirmPurge = true
            } label: {
                Label("현상 끝난 원본 RAW 비우기", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            Text("ProRAW 원본은 한 장에 70~100MB예요. 현상된 JPEG만 남기면 공간을 크게 아낄 수 있어요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .font(.subheadline)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 14)
    }
}
