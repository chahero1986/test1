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

    // MARK: - 本地快照缓存（解决冷启动首页空窗）

    private struct LibraryCache: Codable {
        var assets: [AssetInfo]
        var albumMemberIds: Set<String>
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("library_cache.json")
    }

    init() {
        loadSnapshot()
    }

    /// 启动时先加载上次的元数据快照：首页立即可浏览，
    /// 随后 reload() 在后台刷新并以最新数据覆盖（快照仅本机缓存，不涉及隐私上传）。
    private func loadSnapshot() {
        guard let url = Self.cacheURL,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(LibraryCache.self, from: data),
              !cache.assets.isEmpty
        else { return }
        assets = cache.assets
        assetMap = Dictionary(cache.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumMemberIds = cache.albumMemberIds
        // 有快照说明此前已授权；同步查询当前授权状态，避免权限页闪现
        authorizationStatus = PHPhotoLibrary.authorizationStatus()
    }

    /// 写本地快照（nonisolated：仅文件操作，可在后台线程调用）
    nonisolated private func writeSnapshot(assets: [AssetInfo], memberIds: Set<String>) {
        guard let url = Self.cacheURL,
              let data = try? JSONEncoder().encode(LibraryCache(assets: assets, albumMemberIds: memberIds))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

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
            // 刷新完成后更新本地快照，供下次冷启动秒开
            self.writeSnapshot(assets: assets, memberIds: memberIds)
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
