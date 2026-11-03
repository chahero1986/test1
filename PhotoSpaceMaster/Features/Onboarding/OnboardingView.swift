import SwiftUI

/// 启动引导：每次启动都显示 4 页引导图，页面内即开始 8 秒倒计时；
/// 倒计时结束或点「跳过 / 开始使用」后进入开屏广告，再进主界面。
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0
    @State private var remaining = 8
    @State private var didFinish = false

    private let guides = ["Guide1", "Guide2", "Guide3", "Guide4"]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            TabView(selection: $page) {
                ForEach(Array(guides.enumerated()), id: \.offset) { pair in
                    Image(pair.element)
                        .resizable()
                        .scaledToFit()
                        .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut(duration: 0.25), value: page)

            Button {
                complete()
            } label: {
                Text(buttonTitle)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !didFinish else { return }
            if remaining > 0 { remaining -= 1 }
            if remaining <= 0 { complete() }
        }
    }

    private var buttonTitle: String {
        let action = page == guides.count - 1 ? "开始使用" : "跳过"
        return didFinish ? action : "\(action) \(remaining)s"
    }

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
    }
}
