import SwiftUI

@main
struct PhotoSpaceMasterApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var library = LibraryStore()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environmentObject(appState)
                    .environmentObject(library)
                    .environmentObject(RatingService.shared)

                if showSplash {
                    SplashAdView {
                        showSplash = false
                        Task {
                            await library.requestAccessAndReload()
                            appState.loadMarkers()
                            RatingService.shared.load()
                        }
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.25), value: showSplash)
            .preferredColorScheme(appState.settings.theme.colorScheme)
        }
    }
}
