import SwiftUI

/// Pangle（穿山甲）开屏广告实现。
/// SDK 通过 `#if canImport(BUAdSDK)` 守卫：未集成 SDK 时编译通过，
/// load 恒返回 false，Splash 层自动走兜底（直接进入主界面，不阻塞用户）。
///
/// 接入步骤（集成时）：
/// 1. CocoaPods / SPM 引入 Ads-CN（BUAdSDK）；
/// 2. 在穿山甲后台申请 App ID 与开屏广告位 ID，填入 slotID；
/// 3. Info.plist 增加 Pangle 隐私相关配置（Pangle 不需要 ATT 也能跑非个性化广告，
///    已在 Info.plist 声明 NSUserTrackingUsageDescription 用于个性化优化）；
/// 4. 儿童类目：如上架儿童分区，配置 setChildDirected 并关闭个性化推荐。
final class PangleSplashProvider: SplashAdProvider {

    let countdownSeconds = 8
    var isReady = false

    #if canImport(BUAdSDK)
    private var splashView: BUAdSDK.BUSplashAdView?
    private var onFinish: (() -> Void)?
    private static let slotID = "YOUR_PANGLE_SPLASH_SLOT_ID"   // TODO: 替换为穿山甲后台申请的广告位 ID
    #endif

    func load(completion: @escaping (_ ok: Bool) -> Void) {
        #if canImport(BUAdSDK)
        let view = BUAdSDK.BUSplashAdView(slotID: Self.slotID, frame: UIScreen.main.bounds)
        view.delegate = self
        self.splashView = view
        view.loadAdData()
        // 加载结果经 delegate 通知后置 isReady；此处以超时兜底避免阻塞开屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            completion(self?.isReady ?? false)
        }
        #else
        // 未集成 SDK：立即返回失败，开屏页直接进主界面
        completion(false)
        #endif
    }

    func makeAdView(onFinish: @escaping () -> Void) -> AnyView? {
        #if canImport(BUAdSDK)
        guard let splashView else { return nil }
        self.onFinish = onFinish
        return AnyView(
            UIViewControllerRepresentedAd { splashView }
        )
        #else
        _ = onFinish
        return nil
        #endif
    }
}

#if canImport(BUAdSDK)
extension PangleSplashProvider: BUSplashAdDelegate {
    func splashAdDidLoad(_ splashAd: BUSplashAdView) {
        isReady = true
    }

    func splashAdDidClose(_ splashAd: BUSplashAdView) {
        onFinish?()
    }

    func splashAd(_ splashAd: BUSplashAdView, didFailWithError error: Error) {
        isReady = false
        onFinish?()   // 失败直接关开屏，不阻塞用户
    }
}
#endif

/// 把 SDK 的 UIView 包成 SwiftUI 视图的桥接器
#if canImport(BUAdSDK)
import BUAdSDK

struct UIViewControllerRepresentedAd: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
