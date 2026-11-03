import SwiftUI

/// 启动引导：每次启动都显示 4 页引导图。
/// 倒计时由 App 层统一管理（引导页 + 开屏广告共享 8 秒），本视图只展示剩余秒数与跳过。
struct OnboardingView: View {
    let remaining: Int          // 共享倒计时剩余秒数
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
                onFinish()
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
    }

    private var buttonTitle: String {
        let action = page == guides.count - 1 ? "开始使用" : "跳过"
        return remaining > 0 ? "\(action) \(remaining)s" : action
    }
}
