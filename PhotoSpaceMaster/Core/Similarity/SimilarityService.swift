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
    ///
    /// 性能：两两汉明比较是 O(n²)，2 万张约 2 亿次比较。这里改用 8×8bit 分带倒排索引：
    /// 鸽笼原理保证「距离 ≤ 15 的两个哈希至少有一个 8bit 分带差异 ≤ 1 位」，
    /// 因此只需在每个分带内查「原值 + 8 个单 bit 翻转」的候选（每张约 72 次字典查询），
    /// 候选对再用完整距离校验，结果与 O(n²) 完全一致。threshold > 15 或哈希去重后数量很少时退回全量比较。
    nonisolated static func makeGroups(hashes: [String: UInt64], threshold: Int, candidates: [AssetInfo]) -> [[AssetInfo]] {
        let idToAsset = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = candidates.map(\.id).filter { hashes[$0] != nil }
        guard ids.count > 1 else { return [] }

        var parent = Array(0..<ids.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // 1) 相同哈希去重：完全相同的指纹直接并组，不参与后续候选查找
        var indicesByHash: [UInt64: [Int]] = [:]
        for (i, id) in ids.enumerated() {
            indicesByHash[hashes[id]!, default: []].append(i)
        }
        for group in indicesByHash.values where group.count > 1 {
            for j in group.dropFirst() { union(group[0], j) }
        }
        let distinct = indicesByHash.map { (hash: $0.key, indices: $0.value) }

        func unionDistinct(_ i: Int, _ j: Int) {
            union(distinct[i].indices[0], distinct[j].indices[0])
        }

        if threshold <= 15 && distinct.count > 64 {
            // 2) 分带倒排索引：bandIndex[带序号][带值] = 已插入的哈希下标（渐进插入，避免同对重复比较）
            var bandIndex: [[UInt64: [Int]]] = (0..<8).map { _ in [:] }
            // 带值 + 8 个单 bit 翻转 = 该带差异 ≤ 1 的所有可能取值
            func variants(_ v: UInt64) -> [UInt64] {
                var out = [v]
                out.reserveCapacity(9)
                for bit in 0..<8 { out.append(v ^ (1 << UInt64(bit))) }
                return out
            }
            for (i, item) in distinct.enumerated() {
                if i > 0 {
                    let h = item.hash
                    for b in 0..<8 {
                        let v = (h >> UInt64(b * 8)) & 0xFF
                        for cand in variants(v) {
                            guard let bucket = bandIndex[b][cand] else { continue }
                            for j in bucket where PerceptualHash.distance(h, distinct[j].hash) <= threshold {
                                unionDistinct(i, j)
                            }
                        }
                    }
                }
                for b in 0..<8 {
                    let v = ((item.hash >> UInt64(b * 8)) & 0xFF)
                    bandIndex[b][v, default: []].append(i)
                }
            }
        } else {
            // 去重后数量少，直接全量两两比较更简单也更快
            for i in 0..<distinct.count {
                for j in (i + 1)..<distinct.count
                where PerceptualHash.distance(distinct[i].hash, distinct[j].hash) <= threshold {
                    unionDistinct(i, j)
                }
            }
        }

        var buckets: [Int: [AssetInfo]] = [:]
        for (i, id) in ids.enumerated() {
            if let asset = idToAsset[id] {
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
