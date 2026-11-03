import SwiftUI

/// 开屏页：广告就绪则展示；倒计时由 App 层统一管理（与引导页共享 8 秒），
/// 本视图只展示剩余秒数与「跳过」按钮；广告加载失败直接由用户跳过/倒计时结束进主界面。
struct SplashAdView: View {
    let remaining: Int          // 共享倒计时剩余秒数
    var onFinish: () -> Void

    @StateObject private var coordinator = SplashAdCoordinator()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            Group {
                if coordinator.adReady, let adView = coordinator.adView {
                    adView
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 56))
                            .foregroundColor(.accentColor)
                        Text("相册空间大师")
                            .font(.title2.weight(.semibold))
                        Text("本地整理 · 隐私安全")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button {
                onFinish()
            } label: {
                Text(remaining > 0 ? "跳过 \(remaining)s" : "跳过")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .onAppear {
            coordinator.onFinish = { onFinish() }
            coordinator.load()
        }
    }
}

// MARK: - 开屏协调器

@MainActor
final class SplashAdCoordinator: ObservableObject {
    @Published var adReady = false
    @Published var adView: AnyView?

    let provider = AdProviderFactory.splashProvider()
    var onFinish: (() -> Void)?

    var countdownSeconds: Int { provider.countdownSeconds }

    func load() {
        provider.load { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, ok else { return }
                self.adView = self.provider.makeAdView { [weak self] in
                    self?.onFinish?()
                }
                self.adReady = (self.adView != nil)
            }
        }
    }
}
