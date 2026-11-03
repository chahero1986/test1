import SwiftUI

@main
struct PhotoSpaceMasterApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var library = LibraryStore()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.completed")
    @State private var showSplash = false

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

                if showOnboarding {
                    OnboardingView {
                        showOnboarding = false
                        showSplash = true
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.25), value: showSplash)
            .animation(.easeOut(duration: 0.25), value: showOnboarding)
            .preferredColorScheme(appState.settings.theme.colorScheme)
        }
    }
}
