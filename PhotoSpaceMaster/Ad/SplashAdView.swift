import SwiftUI

/// 开屏页：5 秒倒计时自动关闭 + 「跳过」按钮；广告加载失败直接进主界面。
struct SplashAdView: View {
    var onFinish: () -> Void

    @StateObject private var coordinator = SplashAdCoordinator()
    @State private var remaining = 5
    @State private var didFinish = false

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
                finish()
            } label: {
                Text("跳过 \(remaining)s")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .onAppear {
            remaining = coordinator.countdownSeconds
            coordinator.onFinish = { finish() }
            coordinator.load()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !didFinish else { return }
            if remaining > 0 { remaining -= 1 }
            if remaining <= 0 { finish() }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
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
