# 相册空间大师（iOS）

纯本地运行的照片清理 App：无后端、无账号、无网络请求（仅广告 SDK 与 iCloud 照片按需加载）。

## 无开发者账号：GitHub Actions 云端出 IPA

工程自带 `.github/workflows/build-ipa.yml`，在 GitHub 免费云服务器（macOS runner，公开仓库免费）上编译出**未签名 IPA**：

1. 在 GitHub 新建仓库（public），把本目录所有文件推上去（含 `.github/` 和 `Scripts/`）。
2. 仓库页 → **Actions** → 等待/手动触发 `Build Unsigned IPA`（每次 push 到 main 也会自动跑）。
3. 跑完后在本次运行页面底部 **Artifacts** 下载 `PhotoSpaceMaster-unsigned-ipa`，解压得到未签名 IPA。
4. 安装到 iPhone（无需付费开发者账号，用免费 Apple ID 自签）：
   - **Sideloadly**（Windows/Mac 均可）：数据线连接 iPhone → 拖入 IPA → 输入 Apple ID → 自动签名安装；有效期 **7 天**，到期重签。
   - **AltStore / SideStore**：同样用免费 Apple ID，可在手机上自动续签（需同一 Wi-Fi 下的 AltServer）。
   - 已有 Mac 也可直接 `bash Scripts/build_ipa.sh` 本地出包，或用 Xcode 直连运行（Xcode 里登录免费 Apple ID 即可真机调试）。

注意事项：
- 未签名 IPA **不能直接安装**，必须经上述工具用 Apple ID 签名后安装。
- 免费账号限制：单设备最多 3 个自签 App、每个 7 天有效、部分能力（推送等）不可用——本 App 均不受影响。
- 仓库需 public，否则消耗 Actions 免费额度（每月 2000 分钟，本工程单次约 10 分钟内）。

## 如何构建（本地 Mac + XcodeGen）

需要在 macOS + Xcode 15 及以上环境（Windows 下无法编译 iOS 工程，本目录交付完整源码与工程定义）。

```bash
# 1. 安装 XcodeGen（若未安装）
brew install xcodegen

# 2. 生成 Xcode 工程
cd PhotoSpaceMaster
xcodegen generate

# 3. 打开并运行
open PhotoSpaceMaster.xcodeproj
```

最低部署目标 iOS 16.0，仅支持 iPhone 竖屏。

## 广告 SDK

- 默认接入 **Pangle（穿山甲）** 开屏（国内市场），实现在 `PhotoSpaceMaster/Ad/PangleSplashProvider.swift`。
- SDK 未集成时（当前状态）以 `#if canImport(BUAdSDK)` 守卫，`load` 恒返回失败，开屏页显示 App Logo 并 5 秒自动关闭或点「跳过」，**不阻塞用户**。
- 集成 SDK：引入 `Ads-CN`，替换 `PangleSplashProvider.slotID` 即可。
- **后期切换**：实现 `SplashAdProvider` 协议（如 `AdMobSplashProvider`），在 `AdProviderFactory.splashProvider()` 返回新实现，业务层零改动。

## 目录结构

```
PhotoSpaceMaster/
├── project.yml                 XcodeGen 工程定义
└── PhotoSpaceMaster/
    ├── App/                    入口 / AppState / LibraryStore / RootTabView
    ├── Ad/                     SplashAdProvider 协议 + Pangle 实现 + 开屏页
    ├── Core/
    │   ├── PhotoKit/           PhotoLibraryService / AssetInfo / ThumbnailManager
    │   ├── Filter/             PhotoFilter + FilterEvaluator（组间与、组内或）
    │   ├── Rating/             RatingService（应用内评分，存 RatingItem）
    │   └── Stats/              CleanupService + StatsRecorder（统计口径见方案文档）
    ├── Persistence/            Core Data（TrashItem/ProtectedItem/RatingItem/CleanupRecord）
    ├── Features/
    │   ├── Grid/               共用网格组件（多选/分页/长按菜单）
    │   ├── Home/  Albums/      首页时间线 / 相册分组
    │   ├── FilterPanel/  Trash/  Protected/  Settings/
    │   ├── Stats/              统计卡片、存储占比条、大视频/大录屏/大图片
    │   └── Permission/         权限被拒引导页
    ├── UI/  Support/           主题与隐私清单（PrivacyInfo.xcprivacy）
```

## 需求对照与已知事项

- **大图查看器（Features/Detail/PhotoDetailView）**：点击照片打开。顶部 4 行信息（日期时间 / 类型·分辨率·大小 / 地点·海拔 / 相机参数 EXIF）；左上角返回；右上角垃圾箱·免删除·设置三按钮（带数量角标）；双指缩放、双击复位。**幻灯片式左右滑动**：照片跟手移动，左右可见上一张/下一张，松手滑入切换；**上滑照片变红飞出 = 移入垃圾箱（免确认）**，**下滑变绿飞出 = 免删除**；标记后按当前浏览方向自动前进，且自动跳过免删除照片（可在筛选面板"浏览"组关闭）。浏览方向规则：默认新→旧，操作过"上一张"后沿用旧→新。**底部操作栏**：收藏（写回系统相册 isFavorite）、评分按钮（点开 1–5 星评分面板）。
- **真删即时刷新**：垃圾箱点删除成功后自动重新加载相册元数据，首页/相册等列表立即移除已删除照片（`CleanupService.realDelete(library:)`）。
- **排序 / 首页显示方式在筛选面板**：设置页已移除排序；筛选面板新增「排序」（正序/倒序）与「首页显示方式」（按日期分组显示日期标题 / 平铺显示）两组，均持久化。
- **外观设置**：主题（自动/浅色/深色）即时生效（AppState 转发 SettingsStore 变更）。
- **相册列表预览**：每个相册行显示最新 3 张缩略图预览。

- **App 图标与引导页**：AppIcon 在 `Resources/Assets.xcassets/AppIcon.appiconset`（1024×1024 单尺寸）；**每次启动都显示 4 页引导图（Guide1–4），引导页内即开始 8 秒倒计时**，倒计时结束或点击跳过后进入开屏广告（8 秒）；筛选面板胶囊使用 `FlowLayout`（iOS 16 Layout 协议）自动换行。
- **垃圾箱可见性**：已入垃圾箱的照片在首页/相册仍显示（右上角红 X 角标），由用户在垃圾箱中决定恢复或真删。
- **评分**：PhotoKit 无评分 API，自建 `RatingItem` 表；打星入口在首页网格**长按菜单**与**大图查看器底部评分按钮**。
- **本相机拍摄 / 大录屏**：按已确认的近似口径实现（见方案文档第 7 节决策记录）。
- **垃圾箱**：真删调用 `PHAssetChangeRequest.deleteAssets`，走系统「最近删除」；移入垃圾箱为逻辑删除并计入统计，恢复后不计入。
- **统计口径**：`CleanupRecord.status ∈ {已移入垃圾箱, 已真正删除}` 计入累计释放空间；已恢复不计入。
- **关于页（设置内）**：红色隐私声明、版本 V2026.1103 + 检查更新、邮箱 386047639@qq.com、微信 graphite1、京ICP备占位（上线前替换真实备案号）。
- **性能**：元数据一次性加载 + 缩略图 `PHCachingImageManager` 异步缓存 + 每页 120 项分页。
- 代码为一次性生成的工程骨架，未在真实 Xcode 环境编译过；如遇少量编译告警/小错误，按 Xcode 提示修正即可（多为 API 签名或 Pangle delegate 名称随 SDK 版本差异）。
