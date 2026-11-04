import SwiftUI
import Photos

/// 人物模块数据层（纯本地）：
/// - 扫描：Vision 检测每张照片的人脸并对人脸裁剪区域计算 pHash
/// - 聚类：汉明距离 ≤ 阈值的人脸用并查集归为同一人
/// - 持久化：扫描结果（人脸矩形 + 哈希）存到 Documents/people_faces.json，
///   下次进入直接加载聚类结果，无需重扫；人脸头像按需生成并缓存在内存。
@MainActor
final class PeopleStore: ObservableObject {
    static let shared = PeopleStore()

    enum Phase: Equatable { case idle, scanning, done }

    @Published var phase: Phase = .idle
    /// 0...1 扫描进度
    @Published var progress: Double = 0
    /// 聚类结果：按照片数从多到少
    @Published private(set) var people: [Person] = []

    struct Person: Identifiable, Equatable {
        let id: Int
        var faces: [DetectedFace]

        /// 去重后的照片 id（同一张照片可能有多张人脸）
        var assetIds: [String] {
            var seen = Set<String>()
            return faces.compactMap { face in
                guard seen.insert(face.assetId).inserted else { return nil }
                return face.assetId
            }
        }

        /// 代表头像：取区域最大的人脸
        var representative: DetectedFace? {
            faces.max { $0.area < $1.area }
        }
    }

    /// 人脸聚类阈值：人脸裁剪图整体相似（肤色/背景占比高），阈值取「比较像」级别
    nonisolated static let clusterThreshold = 10

    private var scanTask: Task<Void, Never>?
    /// person id → 头像（内存缓存）
    private var faceImageCache: [Int: UIImage] = [:]

    private static var persistenceURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("people_faces.json")
    }

    private init() {
        loadPersisted()
    }

    // MARK: - 对外操作

    /// 启动扫描（只扫描照片类资产，排除已入垃圾箱）
    func startScan(assets: [AssetInfo], excludeTrashed: Set<String>) {
        guard phase != .scanning else { return }
        let targets = assets.filter {
            $0.kind != .video && !excludeTrashed.contains($0.id)
        }
        phase = .scanning
        progress = 0
        faceImageCache.removeAll()
        scanTask?.cancel()
        scanTask = Task { await scan(targets) }
    }

    /// 取消扫描（保留已完成部分不落库，避免半成品）
    func cancelScan() {
        scanTask?.cancel()
        phase = people.isEmpty ? .idle : .done
    }

    /// 人物头像（缓存）
    func faceImage(for person: Person) async -> UIImage? {
        if let hit = faceImageCache[person.id] { return hit }
        guard let face = person.representative else { return nil }
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [face.assetId], options: nil).firstObject,
                  let loaded = FaceScanner.loadImage(asset: asset, side: 400),
                  let cg = loaded.cgImage
            else { return nil }
            return FaceScanner.crop(cg: cg, box: CGRect(x: face.x, y: face.y, width: face.width, height: face.height))
        }.value
        if let image { faceImageCache[person.id] = image }
        return image
    }

    // MARK: - 扫描

    private func scan(_ assets: [AssetInfo]) async {
        var faces: [DetectedFace] = []
        let total = max(1, assets.count)
        var done = 0

        var index = 0
        while index < assets.count, !Task.isCancelled {
            let chunk = Array(assets[index..<min(index + 6, assets.count)])
            let chunkFaces = await withTaskGroup(of: [DetectedFace].self) { group in
                for info in chunk {
                    group.addTask { FaceScanner.detectFaces(assetId: info.id) }
                }
                var out: [DetectedFace] = []
                for await r in group { out.append(contentsOf: r) }
                return out
            }
            faces.append(contentsOf: chunkFaces)

            done += chunk.count
            progress = Double(done) / Double(total)
            index += 6
        }

        guard !Task.isCancelled else { return }
        people = Self.cluster(faces: faces)
        persist(faces: faces)
        phase = .done
    }

    // MARK: - 聚类（并查集）

    /// 按人脸哈希汉明距离聚类；单人脸也保留（对应只出现过一次的人物）
    nonisolated static func cluster(faces: [DetectedFace], threshold: Int = PeopleStore.clusterThreshold) -> [Person] {
        guard !faces.isEmpty else { return [] }
        var parent = Array(0..<faces.count)
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

        // 相同哈希先并组（同组重复人脸），其余分带倒排索引加速（同 SimilarityService）
        var indicesByHash: [UInt64: [Int]] = [:]
        for (i, face) in faces.enumerated() {
            indicesByHash[face.hash, default: []].append(i)
        }
        for group in indicesByHash.values where group.count > 1 {
            for j in group.dropFirst() { union(group[0], j) }
        }
        let distinct = indicesByHash.map { (hash: $0.key, index: $0.value[0]) }

        if threshold <= 15 && distinct.count > 64 {
            var bandIndex: [[UInt64: [Int]]] = (0..<8).map { _ in [:] }
            func variants(_ v: UInt64) -> [UInt64] {
                var out = [v]
                out.reserveCapacity(9)
                for bit in 0..<8 { out.append(v ^ (1 << UInt64(bit))) }
                return out
            }
            for (i, item) in distinct.enumerated() {
                if i > 0 {
                    for b in 0..<8 {
                        let v = (item.hash >> UInt64(b * 8)) & 0xFF
                        for cand in variants(v) {
                            guard let bucket = bandIndex[b][cand] else { continue }
                            for j in bucket where PerceptualHash.distance(item.hash, distinct[j].hash) <= threshold {
                                union(i, distinct[j].index)
                            }
                        }
                    }
                }
                for b in 0..<8 {
                    bandIndex[b][(item.hash >> UInt64(b * 8)) & 0xFF, default: []].append(i)
                }
            }
        } else {
            for i in 0..<distinct.count {
                for j in (i + 1)..<distinct.count
                where PerceptualHash.distance(distinct[i].hash, distinct[j].hash) <= threshold {
                    union(i, distinct[j].index)
                }
            }
        }

        var buckets: [Int: [DetectedFace]] = [:]
        for (i, face) in faces.enumerated() {
            buckets[find(i), default: []].append(face)
        }
        return buckets.values
            .sorted { $0.count > $1.count }
            .enumerated()
            .map { Person(id: $0.offset, faces: $0.element) }
    }

    // MARK: - 持久化

    private func loadPersisted() {
        guard let url = Self.persistenceURL,
              let data = try? Data(contentsOf: url),
              let faces = try? JSONDecoder().decode([DetectedFace].self, from: data),
              !faces.isEmpty
        else { return }
        people = Self.cluster(faces: faces)
        phase = .done
    }

    private func persist(faces: [DetectedFace]) {
        guard let url = Self.persistenceURL,
              let data = try? JSONEncoder().encode(faces)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
