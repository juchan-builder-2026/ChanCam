import SwiftUI

@main
struct ChanCamApp: App {
    @StateObject private var store = ShotStore.shared
    @StateObject private var processor = Processor.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(processor)
                .preferredColorScheme(.dark)
                .tint(.yellow)
                .statusBarHidden(true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ShotStore
    @State private var showLibrary = ProcessInfo.processInfo.arguments.contains("-demoLibrary")
    @State private var editing: Shot?

    private var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    var body: some View {
        CameraView(showLibrary: $showLibrary)
            .fullScreenCover(isPresented: $showLibrary) {
                LibraryView(onEdit: { editing = $0 })
            }
            .fullScreenCover(item: $editing) { shot in
                EditorView(shot: shot)
            }
            .onAppear {
                if isDemo { DemoData.install() }
                if ProcessInfo.processInfo.arguments.contains("-demoEditor"),
                   let first = store.shots.first {
                    editing = first
                }
            }
    }
}
