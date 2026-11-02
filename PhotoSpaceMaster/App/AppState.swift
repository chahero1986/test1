import SwiftUI
import CoreData

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
    /// 定位到上次操作位置
    @Published var resumeToLastPosition: Bool {
        didSet { ud.set(resumeToLastPosition, forKey: "settings.resume") }
    }
    /// 批量删除时自动排除免删除项目
    @Published var skipProtectedItems: Bool {
        didSet { ud.set(skipProtectedItems, forKey: "settings.skipProtected") }
    }
    /// 最后浏览的 asset id（首页定位用）
    @Published var lastViewedAssetId: String {
        didSet { ud.set(lastViewedAssetId, forKey: "settings.lastViewedAssetId") }
    }
    /// 大视频 / 大图片阈值（MB）
    @Published var largeVideoThresholdMB: Int {
        didSet { ud.set(largeVideoThresholdMB, forKey: "stats.largeVideoMB") }
    }
    @Published var largePhotoThresholdMB: Int {
        didSet { ud.set(largePhotoThresholdMB, forKey: "stats.largePhotoMB") }
    }

    init() {
        theme = ThemeMode(rawValue: ud.string(forKey: "settings.theme") ?? "") ?? .auto
        sortOrder = SortOrder(rawValue: ud.string(forKey: "settings.sortOrder") ?? "") ?? .descending
        resumeToLastPosition = ud.object(forKey: "settings.resume") as? Bool ?? true
        skipProtectedItems = ud.object(forKey: "settings.skipProtected") as? Bool ?? true
        lastViewedAssetId = ud.string(forKey: "settings.lastViewedAssetId") ?? ""
        largeVideoThresholdMB = ud.object(forKey: "stats.largeVideoMB") as? Int ?? 200
        largePhotoThresholdMB = ud.object(forKey: "stats.largePhotoMB") as? Int ?? 10
    }

    /// 恢复默认设置（入口有二次确认）
    func resetToDefaults() {
        theme = .auto
        sortOrder = .descending
        resumeToLastPosition = true
        skipProtectedItems = true
        lastViewedAssetId = ""
        largeVideoThresholdMB = 200
        largePhotoThresholdMB = 10
    }
}

// MARK: - 全局状态

@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()

    /// 筛选状态：会话内保持（切 Tab、进出子页不重置），App 冷启动后恢复默认
    @Published var filter = PhotoFilter()

    @Published var trashIds: Set<String> = []
    @Published var protectedIds: Set<String> = []

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
