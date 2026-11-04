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

    /// 后台全量加载：fetchAllAssets / albumMemberIds 对上万张照片可能耗时数秒，
    /// 必须离开主线程执行，完成后回主线程一次性赋值（AssetInfo / Set<String> 均为值类型）。
    private var reloadGeneration = 0

    func reload() {
        // 代数计数：并发/连续触发多次 reload 时，只有最新一次的结果生效，旧的直接丢弃
        reloadGeneration += 1
        let generation = reloadGeneration
        let service = self.service
        Task.detached(priority: .userInitiated) {
            let assets = service.fetchAllAssets(sortAscending: false)
            let assetMap = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let memberIds = service.albumMemberIds()
            await MainActor.run {
                guard generation == self.reloadGeneration else { return }
                self.assets = assets
                self.assetMap = assetMap
                self.albumMemberIds = memberIds
            }
        }
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
    /// 注：已入垃圾箱的照片仍然显示（带红色 X 角标），由用户在垃圾箱中决定去留
    func filteredAssets(state: AppState, ratings: RatingService) -> [AssetInfo] {
        let members = albumMemberIds
        return sorted(
            assets
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
