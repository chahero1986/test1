import SwiftUI

/// 首次启动引导：4 页引导图横滑浏览；末页「开始使用」或任意页「跳过」进入开屏广告。
/// 已完成过引导的用户不再显示（UserDefaults 持久化）。
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0

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
                Text(page == guides.count - 1 ? "开始使用" : "跳过")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        onFinish()
    }
}
