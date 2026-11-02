import Foundation

// MARK: - 筛选项枚举（组间「与」、组内「或」）

enum FilterSource: String, CaseIterable, Identifiable {
    case cameraShot
    case other
    var id: String { rawValue }
    var title: String { self == .cameraShot ? "本相机拍摄" : "其他" }
}

enum FilterType: String, CaseIterable, Identifiable {
    case photo, video, screenshot, livePhoto
    var id: String { rawValue }
    var kind: MediaKind {
        switch self {
        case .photo: return .photo
        case .video: return .video
        case .screenshot: return .screenshot
        case .livePhoto: return .livePhoto
        }
    }
    var title: String { kind.title }
    var icon: String { kind.icon }
}

enum FilterAlbumMembership: String, CaseIterable, Identifiable {
    case notInAlbum
    case inAlbum
    var id: String { rawValue }
    var title: String { self == .inAlbum ? "在相簿中" : "不在相簿中" }
}

// MARK: - 筛选状态（会话内保持）

struct PhotoFilter: Equatable {
    /// 分组2 标记：收藏
    var favorite = false
    /// 分组2 标记：评分星级（1...5 多选）
    var ratings: Set<Int> = []
    /// 分组3 来源
    var sources: Set<FilterSource> = []
    /// 分组4 类型
    var types: Set<FilterType> = []
    /// 分组5 相簿归属
    var albumMembership: Set<FilterAlbumMembership> = []

    /// 「项目范围：所有项目」= 无任何附加条件的默认态
    var isDefault: Bool { self == PhotoFilter() }

    var hasActiveConditions: Bool { !isDefault }
}
