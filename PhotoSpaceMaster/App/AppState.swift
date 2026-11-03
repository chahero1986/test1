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

/// 首页显示方式：按日期分组（显示日期标题）/ 平铺显示
enum HomeLayout: String, CaseIterable, Identifiable {
    case byDate, flat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .byDate: return "按日期分组"
        case .flat: return "平铺显示"
        }
    }

    var icon: String {
        switch self {
        case .byDate: return "calendar"
        case .flat: return "square.grid.3x3"
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

    init() {
        theme = ThemeMode(rawValue: ud.string(forKey: "settings.theme") ?? "") ?? .auto
        sortOrder = SortOrder(rawValue: ud.string(forKey: "settings.sortOrder") ?? "") ?? .descending
        skipProtectedItems = ud.object(forKey: "settings.skipProtected") as? Bool ?? true
        bookmarkAssetId = ud.string(forKey: "settings.bookmarkAssetId") ?? ""
        largeVideoThresholdMB = ud.object(forKey: "stats.largeVideoMB") as? Int ?? 200
        largePhotoThresholdMB = ud.object(forKey: "stats.largePhotoMB") as? Int ?? 10
        homeLayout = HomeLayout(rawValue: ud.string(forKey: "settings.homeLayout") ?? "") ?? .byDate
    }

    /// 恢复默认设置（入口有二次确认）
    func resetToDefaults() {
        theme = .auto
        sortOrder = .descending
        skipProtectedItems = true
        bookmarkAssetId = ""
        largeVideoThresholdMB = 200
        largePhotoThresholdMB = 10
        homeLayout = .byDate
    }
}

// MARK: - 全局状态

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

    /// 筛选状态：会话内保持（切 Tab、进出子页不重置），App 冷启动后恢复默认
    @Published var filter = PhotoFilter()

    @Published var trashIds: Set<String> = []
    @Published var protectedIds: Set<String> = []

    /// 「转到定位」请求计数器：筛选面板点击后 +1，首页监听后跳转到书签位置
    @Published var bookmarkJumpToken = 0

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
