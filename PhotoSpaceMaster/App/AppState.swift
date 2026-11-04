import SwiftUI
import CoreData
import Combine

// MARK: - 主题 / 排序枚举

enum ThemeMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case ascending, descending
    var id: String { rawValue }

    var title: String { self == .ascending ? "正序" : "倒序" }
    var icon: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

/// 首页显示方式：按日期分组（显示日期标题）/ 平铺显示 / 统一方块（原生相册式固定三列网格）
enum HomeLayout: String, CaseIterable, Identifiable {
    case byDate, flat, unified
    var id: String { rawValue }

    var title: String {
        switch self {
        case .byDate: return "按日期分组"
        case .flat: return "平铺显示"
        case .unified: return "统一方块"
        }
    }

    var icon: String {
        switch self {
        case .byDate: return "calendar"
        case .flat: return "square.grid.3x3"
        case .unified: return "rectangle.grid.3x3"
        }
    }
}

// MARK: - 语言（默认跟随系统）

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// 注入 SwiftUI 环境的 locale；跟随系统时用自动更新的当前语言
    var resolvedLocale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }
}

// MARK: - 设置（持久化到 UserDefaults）

@MainActor
final class SettingsStore: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var theme: ThemeMode {
        didSet { ud.set(theme.rawValue, forKey: "settings.theme") }
    }
    @Published var sortOrder: SortOrder {
        didSet { ud.set(sortOrder.rawValue, forKey: "settings.sortOrder") }
    }
    /// 批量删除时自动排除免删除项目
    @Published var skipProtectedItems: Bool {
        didSet { ud.set(skipProtectedItems, forKey: "settings.skipProtected") }
    }
    /// 浏览（大图上一张/下一张）时自动跳过已加入垃圾箱的项目
    @Published var skipTrashedItems: Bool {
        didSet { ud.set(skipTrashedItems, forKey: "settings.skipTrashed") }
    }
    /// 首页缩略图缩放（双指捏合调整，0.6...2.2，1 = 默认大小）
    @Published var thumbnailScale: CGFloat {
        didSet { ud.set(thumbnailScale, forKey: "settings.thumbnailScale") }
    }
    /// 定位书签：在照片详情页设置，筛选面板「转到定位」跳转
    @Published var bookmarkAssetId: String {
        didSet { ud.set(bookmarkAssetId, forKey: "settings.bookmarkAssetId") }
    }
    /// 大视频 / 大图片阈值（MB）
    @Published var largeVideoThresholdMB: Int {
        didSet { ud.set(largeVideoThresholdMB, forKey: "stats.largeVideoMB") }
    }
    @Published var largePhotoThresholdMB: Int {
        didSet { ud.set(largePhotoThresholdMB, forKey: "stats.largePhotoMB") }
    }
    /// 首页显示方式：按日期分组 / 平铺
    @Published var homeLayout: HomeLayout {
        didSet { ud.set(homeLayout.rawValue, forKey: "settings.homeLayout") }
    }

    /// 界面语言（默认跟随系统）
    @Published var language: AppLanguage {
        didSet { ud.set(language.rawValue, forKey: "settings.language") }
    }

    init() {
        theme = ThemeMode(rawValue: ud.string(forKey: "settings.theme") ?? "") ?? .auto
        sortOrder = SortOrder(rawValue: ud.string(forKey: "settings.sortOrder") ?? "") ?? .descending
        skipProtectedItems = ud.object(forKey: "settings.skipProtected") as? Bool ?? true
        skipTrashedItems = ud.object(forKey: "settings.skipTrashed") as? Bool ?? true
        let savedScale = ud.object(forKey: "settings.thumbnailScale") as? CGFloat ?? 1
        thumbnailScale = min(2.2, max(0.6, savedScale))
        bookmarkAssetId = ud.string(forKey: "settings.bookmarkAssetId") ?? ""
        largeVideoThresholdMB = ud.object(forKey: "stats.largeVideoMB") as? Int ?? 200
        largePhotoThresholdMB = ud.object(forKey: "stats.largePhotoMB") as? Int ?? 10
        homeLayout = HomeLayout(rawValue: ud.string(forKey: "settings.homeLayout") ?? "") ?? .byDate
        language = AppLanguage(rawValue: ud.string(forKey: "settings.language") ?? "") ?? .system
    }

    /// 恢复默认设置（入口有二次确认）
    func resetToDefaults() {
        theme = .auto
        sortOrder = .descending
        skipProtectedItems = true
        skipTrashedItems = true
        thumbnailScale = 1
        bookmarkAssetId = ""
        largeVideoThresholdMB = 200
        largePhotoThresholdMB = 10
        homeLayout = .byDate
        language = .system
    }
}

// MARK: - 全局状态

/// 主 Tab（供跨页跳转，如「按日期占用」点击日期回到首页）
enum AppTab: Hashable {
    case home, albums, stats
}

@MainActor
final class AppState: ObservableObject {
    var settings = SettingsStore()

    /// 把 SettingsStore 的变更转发到 AppState，保证主题等设置全局生效
    private var settingsCancellable: AnyCancellable?

    init() {
        settingsCancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// 当前 Tab
    @Published var selectedTab: AppTab = .home

    /// 筛选状态：会话内保持（切 Tab、进出子页不重置），App 冷启动后恢复默认
    @Published var filter = PhotoFilter()

    @Published var trashIds: Set<String> = []
    @Published var protectedIds: Set<String> = []

    /// 「转到定位」请求计数器：筛选面板点击后 +1，首页监听后跳转到书签位置
    @Published var bookmarkJumpToken = 0

    /// 「跳转到某天」请求：目标日期 + 计数器，首页监听后定位到该日期第一张照片
    @Published var homeJumpDate: Date?
    @Published var homeJumpToken = 0

    /// 从其他页面跳回首页并定位到指定日期
    func jumpToHome(date: Date) {
        homeJumpDate = date
        homeJumpToken += 1
        selectedTab = .home
    }

    func isProtected(_ id: String) -> Bool { protectedIds.contains(id) }
    func isTrashed(_ id: String) -> Bool { trashIds.contains(id) }

    /// 启动时从 Core Data 恢复垃圾箱与免删除集合
    func loadMarkers() {
        let context = PersistenceController.shared.container.viewContext

        let trashRequest = NSFetchRequest<TrashItem>(entityName: "TrashItem")
        let trashItems = (try? context.fetch(trashRequest)) ?? []
        trashIds = Set(trashItems.map(\.localAssetId))

        let protectedRequest = NSFetchRequest<ProtectedItem>(entityName: "ProtectedItem")
        let protectedItems = (try? context.fetch(protectedRequest)) ?? []
        protectedIds = Set(protectedItems.map(\.localAssetId))
    }
}
