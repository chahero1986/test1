import SwiftUI

/// 开屏广告协议：业务层只依赖此协议，可随时替换 SDK（Pangle / AdMob / 聚合中介）。
protocol SplashAdProvider: AnyObject {
    /// 倒计时秒数（需求：5 秒自动关闭）
    var countdownSeconds: Int { get }
    /// 广告是否已加载成功可展示
    var isReady: Bool { get }
    /// 预加载广告；ok=false 表示加载失败，调用方应直接进入主界面（不阻塞）
    func load(completion: @escaping (_ ok: Bool) -> Void)
    /// 构造广告视图；onFinish 在广告自然结束（倒计时完成/用户关闭）时回调
    func makeAdView(onFinish: @escaping () -> Void) -> AnyView?
}

/// 广告提供者工厂 —— 换 SDK 只需要改这一处。
/// 当前主投国内市场 → 默认 Pangle（穿山甲）；
/// 后期如需切 AdMob 或接聚合中介（如 GroMore / AdMob Mediation），新增实现并在此返回即可。
enum AdProviderFactory {
    static func splashProvider() -> SplashAdProvider {
        PangleSplashProvider()
    }
}
