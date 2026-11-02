import Foundation

// MARK: - 媒体类型（与 Core Data mediaType 字段对应）

enum MediaKind: Int16, CaseIterable, Hashable {
    case photo = 0
    case video = 1
    case screenshot = 2
    case livePhoto = 3

    var title: String {
        switch self {
        case .photo: return "图片"
        case .video: return "视频"
        case .screenshot: return "截屏"
        case .livePhoto: return "实况照片"
        }
    }

    var icon: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video.fill"
        case .screenshot: return "camera.viewfinder"
        case .livePhoto: return "livephoto"
        }
    }

    /// 存储分析占比条用色（固定，不随主题变化）
    var barColorHex: String {
        switch self {
        case .photo: return "#378ADD"
        case .video: return "#7F77DD"
        case .screenshot: return "#D85A30"
        case .livePhoto: return "#1D9E75"
        }
    }
}

// MARK: - 资产轻量元数据

struct AssetInfo: Identifiable, Hashable {
    let id: String                 // PHAsset.localIdentifier
    let kind: MediaKind
    let byteSize: Int64
    let durationSeconds: Double
    let isFavorite: Bool
    let creationDate: Date?
    let isLivePhoto: Bool
    let isScreenRecording: Bool
    /// 近似口径：非截屏、非录屏、存在拍摄日期即视为本相机拍摄
    let isCameraShot: Bool

    static func == (lhs: AssetInfo, rhs: AssetInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 相簿摘要

struct AlbumSummary: Identifiable, Hashable {
    let id: String       // PHAssetCollection.localIdentifier
    let title: String
    let count: Int

    var icon: String {
        switch title {
        case "相机胶卷", "最近项目", "Recents": return "photo.stack"
        case "个人收藏", "Favorites": return "heart.fill"
        case "截屏", "Screenshots": return "camera.viewfinder"
        case "视频", "Videos": return "video.fill"
        case "实况照片", "Live Photos": return "livephoto"
        case "自拍", "Selfies": return "person.crop.square"
        default: return "folder.fill"
        }
    }
}
