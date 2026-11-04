import SwiftUI

@main
struct PhotoSpaceMasterApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var library = LibraryStore()
    @State private var showOnboarding = true
    @State private var showSplash = false
    @State private var remaining = 8          // 引导页 + 开屏共享的总倒计时（秒）
    @State private var didFinishAll = false

    private let sharedCountdownTotal = 8

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environmentObject(appState)
                    .environmentObject(library)
                    .environmentObject(RatingService.shared)

                if showSplash {
                    SplashAdView(remaining: remaining) {
                        finishSplash()
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }

                if showOnboarding {
                    OnboardingView(remaining: remaining) {
                        // 用户在引导页提前跳过 → 剩余时间交给开屏广告
                        showOnboarding = false
                        if remaining > 0 {
                            showSplash = true
                        } else {
                            finishSplash()
                        }
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.25), value: showSplash)
            .animation(.easeOut(duration: 0.25), value: showOnboarding)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                guard !didFinishAll else { return }
                if remaining > 0 { remaining -= 1 }
                if remaining <= 0 {
                    // 总倒计时耗尽：仍在引导页 → 直接进主界面（广告不再展示）
                    if showOnboarding {
                        showOnboarding = false
                        finishSplash()
                    } else if showSplash {
                        finishSplash()
                    }
                }
            }
            .preferredColorScheme(appState.settings.theme.colorScheme)
            // 语言：跟随系统 / 强制简体中文 / 强制英文（影响系统组件与已本地化文案）
            .environment(\.locale, appState.settings.language.resolvedLocale)
        }
    }

    private func finishSplash() {
        didFinishAll = true
        showSplash = false
        Task {
            await library.requestAccessAndReload()
            appState.loadMarkers()
            RatingService.shared.load()
        }
    }
}
