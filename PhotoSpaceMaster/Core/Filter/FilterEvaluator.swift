import Foundation

/// 筛选求值器：组间为「与」（每组要么未启用，要么命中），组内为「或」。
enum FilterEvaluator {
    static func matches(
        _ asset: AssetInfo,
        filter: PhotoFilter,
        rating: Int,
        inAlbum: Bool
    ) -> Bool {
        // 分组2 标记：收藏 OR 评分星级
        if filter.favorite || !filter.ratings.isEmpty {
            let favHit = filter.favorite && asset.isFavorite
            let rateHit = !filter.ratings.isEmpty && filter.ratings.contains(rating)
            if !(favHit || rateHit) { return false }
        }
        // 分组3 来源
        if !filter.sources.isEmpty {
            let cameraHit = filter.sources.contains(.cameraShot) && asset.isCameraShot
            let otherHit = filter.sources.contains(.other) && !asset.isCameraShot
            if !(cameraHit || otherHit) { return false }
        }
        // 分组4 类型
        if !filter.types.isEmpty {
            let kindHit = filter.types.contains { $0.kind == asset.kind }
            if !kindHit { return false }
        }
        // 分组5 相簿归属
        if !filter.albumMembership.isEmpty {
            let inHit = filter.albumMembership.contains(.inAlbum) && inAlbum
            let notInHit = filter.albumMembership.contains(.notInAlbum) && !inAlbum
            if !(inHit || notInHit) { return false }
        }
        return true
    }
}
