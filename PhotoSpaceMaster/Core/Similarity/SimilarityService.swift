import SwiftUI
import Photos

/// 相似/重复照片扫描服务（纯本地）：
/// - 为每张照片计算 pHash（视频取海报帧）
/// - 汉明距离分级：重复 ≤2 / 非常像 ≤6 / 比较像 ≤10
/// - 并查集把相邻距离 ≤ 阈值的照片归为一组
/// - 结果缓存在内存；照片库变化后重新进入页面会自动重扫
@MainActor
final class SimilarityStore: ObservableObject {
    static let shared = SimilarityStore()

    enum Phase: Equatable { case idle, scanning, done }

    @Published var phase: Phase = .idle
    /// 0...1 扫描进度
    @Published var progress: Double = 0
    /// 汇总统计（最宽松阈值「比较像」口径）：组数、可清理张数（每组保留一张）、预计可释放空间
    @Published var stats: GroupStats?

    struct GroupStats: Equatable {
        var groups = 0
        var extraCount = 0
        var freeBytes: Int64 = 0
    }

    // 相似度阈值（nonisolated：供非隔离上下文引用，消除 Swift 6 隔离警告）
    nonisolated static let duplicateThreshold = 2
    nonisolated static let verySimilarThreshold = 6
    nonisolated static let similarThreshold = 10

    /// asset id → pHash
    private var hashes: [String: UInt64] = [:]
    /// 最近一次扫描的候选资产（供分组与统计使用）
    private var scannedAssets: [AssetInfo] = []
    private var scanTask: Task<Void, Never>?

    /// 需要时启动扫描（已在扫描中或哈希已覆盖全部资产则跳过）
    func scanIfNeeded(assets: [AssetInfo]) {
        if phase == .scanning { return }
        if hashes.count >= assets.count && !assets.isEmpty {
            phase = .done
            recomputeStats(assets: assets)
            return
        }
        phase = .scanning
        progress = 0
        scanTask?.cancel()
        scanTask = Task { await scan(assets: assets) }
    }

    private func scan(assets: [AssetInfo]) async {
        hashes.removeAll()
        let manager = PHImageManager.default()
        let total = max(1, assets.count)
        var done = 0

        var index = 0
        while index < assets.count, !Task.isCancelled {
            let chunk = Array(assets[index..<min(index + 8, assets.count)])
            let results = await withTaskGroup(of: (String, UInt64?).self) { group in
                for info in chunk {
                    group.addTask {
                        guard let asset = PHAsset.fetchAssets(
                            withLocalIdentifiers: [info.id], options: nil
                        ).firstObject else { return (info.id, nil) }

                        let opts = PHImageRequestOptions()
                        opts.isSynchronous = true
                        opts.isNetworkAccessAllowed = false
                        opts.deliveryMode = .fastFormat
                        opts.resizeMode = .fast
                        var image: UIImage?
                        manager.requestImage(
                            for: asset,
                            targetSize: CGSize(width: 64, height: 64),
                            contentMode: .aspectFill,
                            options: opts
                        ) { img, _ in image = img }
                        return (info.id, image.flatMap { PerceptualHash.phash(of: $0) })
                    }
                }
                var out: [(String, UInt64?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, hash) in results where hash != nil {
                hashes[id] = hash
            }
            done += chunk.count
            progress = Double(done) / Double(total)
            index += 8
        }

        phase = .done
        recomputeStats(assets: assets)
    }

    /// 重新计算汇总统计（阈值 = 「比较像」，每组保留一张估算可释放空间）
    func recomputeStats(assets: [AssetInfo]) {
        guard !hashes.isEmpty else { stats = nil; return }
        scannedAssets = assets
        let grouped = Self.makeGroups(hashes: hashes, threshold: Self.similarThreshold, candidates: assets)
        var extra = 0
        var bytes: Int64 = 0
        for group in grouped {
            extra += group.count - 1
            let sorted = group.sorted { $0.byteSize > $1.byteSize }
            bytes += sorted.dropFirst().reduce(0) { $0 + $1.byteSize }
        }
        stats = GroupStats(groups: grouped.count, extraCount: extra, freeBytes: bytes)
    }

    /// 按阈值把候选资产分组（并查集），返回组内按文件大小降序排列、组间按张数降序的分组结果
    nonisolated static func makeGroups(hashes: [String: UInt64], threshold: Int, candidates: [AssetInfo]) -> [[AssetInfo]] {
        let idToAsset = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = candidates.map(\.id).filter { hashes[$0] != nil }
        let arr = ids.map { hashes[$0]! }
        guard arr.count > 1 else { return [] }

        var parent = Array(0..<arr.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in 0..<arr.count {
            for j in (i + 1)..<arr.count where PerceptualHash.distance(arr[i], arr[j]) <= threshold {
                parent[find(i)] = find(j)
            }
        }
        var buckets: [Int: [AssetInfo]] = [:]
        for i in 0..<arr.count {
            if let asset = idToAsset[ids[i]] {
                buckets[find(i), default: []].append(asset)
            }
        }
        return buckets.values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.byteSize > $1.byteSize } }
            .sorted { $0.count > $1.count }
    }

    /// 供视图调用：按当前候选与阈值分组
    func groups(for candidates: [AssetInfo], threshold: Int) -> [[AssetInfo]] {
        Self.makeGroups(hashes: hashes, threshold: threshold, candidates: candidates)
    }
}
