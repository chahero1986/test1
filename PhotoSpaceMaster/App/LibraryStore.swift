import Foundation
import Photos

/// 相册元数据仓库：一次性加载全部资产元数据，视图层只面向 [AssetInfo]。
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var assets: [AssetInfo] = []
    @Published private(set) var assetMap: [String: AssetInfo] = [:]
    @Published private(set) var albumMemberIds: Set<String> = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined

    private let service = PhotoLibraryService.shared

    func requestAccessAndReload() async {
        authorizationStatus = await service.requestAccess()
        guard service.hasAccess else { return }
        reload()
    }

    func reload() {
        assets = service.fetchAllAssets(sortAscending: false)
        assetMap = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumMemberIds = service.albumMemberIds()
    }

    func infos(for ids: Set<String>) -> [AssetInfo] {
        ids.compactMap { assetMap[$0] }
    }

    func infos(for ids: [String]) -> [AssetInfo] {
        ids.compactMap { assetMap[$0] }
    }

    /// 按当前设置排序
    func sorted(_ infos: [AssetInfo], settings: SettingsStore) -> [AssetInfo] {
        let asc = settings.sortOrder == .ascending
        return infos.sorted {
            let l = $0.creationDate ?? .distantPast
            let r = $1.creationDate ?? .distantPast
            return asc ? l < r : l > r
        }
    }

    /// 应用筛选后的列表（供首页 / 相册等复用）
    func filteredAssets(state: AppState, ratings: RatingService) -> [AssetInfo] {
        let trashed = state.trashIds
        let members = albumMemberIds
        return sorted(
            assets
                .filter { !trashed.contains($0.id) }
                .filter {
                    FilterEvaluator.matches(
                        $0,
                        filter: state.filter,
                        rating: ratings.ratings[$0.id] ?? 0,
                        inAlbum: members.contains($0.id)
                    )
                },
            settings: state.settings
        )
    }
}
