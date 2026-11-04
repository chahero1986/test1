import CoreData
import Foundation
import Photos

/// 真删进度与结果摘要（真删耗时长，避免界面"看起来卡死"）
/// 注意：属性只在主线程读写（服务层在 MainActor、观察者经 Task { @MainActor } 回报）。
final class DeletionProgress: ObservableObject {
    @Published var isActive = false
    @Published var deleted = 0
    @Published var total = 0
    /// 已统计过移除事件的资产 id，防止观察者重复计数
    let counted = NSMutableSet()
    /// 删除完成后的摘要；nil = 未显示
    @Published var summary: DeletionSummary?
}

struct DeletionSummary {
    let count: Int
    let bytes: Int64
    let cumulativeBytes: Int64

    var bytesText: String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// 累计节省空间（GB 展示，不足 1 GB 时退回 MB）
    var cumulativeText: String {
        if cumulativeBytes >= 1_000_000_000 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: cumulativeBytes)
        }
        return ByteCountFormatter.string(fromByteCount: max(0, cumulativeBytes), countStyle: .file)
    }
}

/// 清理操作唯一入口：移入垃圾箱 / 恢复 / 真删 / 免删除。
/// 同步维护 TrashItem、ProtectedItem、CleanupRecord 与 AppState 内的内存集合。
@MainActor
enum CleanupService {

    /// 真删进度（垃圾箱等页面观察此对象显示进度与摘要）；nonisolated 供 View 属性初始化访问
    nonisolated static let deletionProgress = DeletionProgress()

    static var context: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    // MARK: - 移入垃圾箱（逻辑删除）

    static func moveToTrash(_ infos: [AssetInfo], state: AppState) {
        // 「跳过免删除项目」开关：开启时批量操作自动排除免删除项
        let skipped = state.settings.skipProtectedItems
            ? infos.filter { !state.protectedIds.contains($0.id) }
            : infos
        guard !skipped.isEmpty else { return }

        // 一次性预取已存在的垃圾箱项与清理记录，循环内只查内存
        let ids = skipped.map(\.id)
        let existingTrash = fetchTrashItems(ids: ids)
        let existingRecords = fetchCleanupRecords(ids: ids)

        let now = Date()
        for info in skipped {
            if existingTrash[info.id] != nil { continue }
            let item = TrashItem(context: context)
            item.localAssetId = info.id
            item.addedDate = now
            item.mediaType = info.kind.rawValue
            item.byteSize = info.byteSize
            item.durationSeconds = info.durationSeconds
            item.pixelWidth = 0
            item.pixelHeight = 0
            upsertCleanupRecord(id: info.id, kind: info.kind, bytes: info.byteSize, status: 0, existing: existingRecords)
        }
        PersistenceController.save(context)
        state.trashIds.formUnion(ids)
    }

    // MARK: - 恢复

    static func restore(ids: [String], state: AppState) {
        let existingTrash = fetchTrashItems(ids: ids)
        let existingRecords = fetchCleanupRecords(ids: ids)
        for id in ids {
            if let item = existingTrash[id] { context.delete(item) }
            existingRecords[id]?.status = 2
        }
        PersistenceController.save(context)
        state.trashIds.subtract(ids)
    }

    // MARK: - 真正删除（调用 PhotoKit，走系统「最近删除」）

    /// - Parameter bytes: 本次删除项目的总字节数（用于完成摘要）
    static func realDelete(ids: [String], state: AppState, library: LibraryStore? = nil, bytes: Int64 = 0) async throws {
        // 显示"正在删除"进度（系统确认弹窗出现前就位，删除全程可见）
        let progress = deletionProgress
        progress.isActive = true
        progress.summary = nil
        progress.deleted = 0
        progress.total = ids.count
        progress.counted.removeAllObjects()
        defer { progress.isActive = false }

        try await PhotoLibraryService.shared.systemDelete(ids: ids, progress: progress)

        let existingTrash = fetchTrashItems(ids: ids)
        let existingRecords = fetchCleanupRecords(ids: ids)
        for id in ids {
            if let item = existingTrash[id] { context.delete(item) }
            existingRecords[id]?.status = 1
        }
        PersistenceController.save(context)
        state.trashIds.subtract(ids)
        // 关键：重新加载相册，让已删除的照片从所有列表中消失
        library?.reload()

        // 完成摘要：本次删除数 / 节省空间 / 累计节省空间
        progress.summary = DeletionSummary(
            count: ids.count,
            bytes: bytes,
            cumulativeBytes: StatsRecorder.totals().totalBytes
        )
    }

    // MARK: - 免删除

    static func toggleProtected(_ ids: [String], state: AppState) {
        let existing = fetchProtectedItems(ids: ids)
        for id in ids {
            if state.protectedIds.contains(id) {
                if let item = existing[id] { context.delete(item) }
                state.protectedIds.remove(id)
            } else {
                let item = ProtectedItem(context: context)
                item.localAssetId = id
                item.addedDate = Date()
                state.protectedIds.insert(id)
            }
        }
        PersistenceController.save(context)
    }

    // MARK: - 统计（内部）

    /// 批量按 id 集合拉取（分块 IN 查询）。
    /// 批量勾选几百张时，逐条 fetch 意味着上千次 Core Data 查询；批量拉取后循环只查内存字典。
    private static func fetchTrashItems(ids: [String]) -> [String: TrashItem] {
        var result: [String: TrashItem] = [:]
        for chunk in ids.chunked(into: 500) {
            let request = NSFetchRequest<TrashItem>(entityName: "TrashItem")
            request.predicate = NSPredicate(format: "localAssetId IN %@", chunk)
            for item in (try? context.fetch(request)) ?? [] {
                result[item.localAssetId] = item
            }
        }
        return result
    }

    private static func fetchProtectedItems(ids: [String]) -> [String: ProtectedItem] {
        var result: [String: ProtectedItem] = [:]
        for chunk in ids.chunked(into: 500) {
            let request = NSFetchRequest<ProtectedItem>(entityName: "ProtectedItem")
            request.predicate = NSPredicate(format: "localAssetId IN %@", chunk)
            for item in (try? context.fetch(request)) ?? [] {
                result[item.localAssetId] = item
            }
        }
        return result
    }

    private static func fetchCleanupRecords(ids: [String]) -> [String: CleanupRecord] {
        var result: [String: CleanupRecord] = [:]
        for chunk in ids.chunked(into: 500) {
            let request = NSFetchRequest<CleanupRecord>(entityName: "CleanupRecord")
            request.predicate = NSPredicate(format: "localAssetId IN %@", chunk)
            for record in (try? context.fetch(request)) ?? [] {
                result[record.localAssetId] = record
            }
        }
        return result
    }

    private static func upsertCleanupRecord(id: String, kind: MediaKind, bytes: Int64, status: Int16, existing: [String: CleanupRecord]? = nil) {
        let record: CleanupRecord
        if let found = existing?[id] ?? fetchCleanupRecord(id: id) {
            record = found
            record.eventDate = Date()
            record.status = status
            record.byteSize = bytes
            record.mediaType = kind.rawValue
        } else {
            record = CleanupRecord(context: context)
            record.localAssetId = id
            record.eventDate = Date()
            record.mediaType = kind.rawValue
            record.byteSize = bytes
            record.status = status
        }
    }

    private static func fetchCleanupRecord(id: String) -> CleanupRecord? {
        let request = NSFetchRequest<CleanupRecord>(entityName: "CleanupRecord")
        request.predicate = NSPredicate(format: "localAssetId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}

private extension Array {
    /// 按 size 分块（用于 Core Data IN 谓词，避开 SQLite 变量数上限）
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - 统计读取

struct CleanupTotals {
    var totalBytes: Int64 = 0
    var totalCount = 0
    var bytesByKind: [MediaKind: Int64] = [:]

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

enum StatsRecorder {
    /// 统计口径：status ∈ {0 已移入垃圾箱, 1 已真正删除}；2 已恢复不计入。
    /// 聚合查询：按 mediaType 分组返回 SUM/COUNT（每类型一行），
    /// 避免清理记录积累数千条后把全表拉进内存求和。查询异常时退回全表遍历。
    static func totals() -> CleanupTotals {
        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<NSDictionary>(entityName: "CleanupRecord")
        request.predicate = NSPredicate(format: "status IN %@", [0, 1])
        request.resultType = .dictionaryResultType

        let kindDesc = NSExpressionDescription()
        kindDesc.name = "mediaType"
        kindDesc.expression = NSExpression(forKeyPath: "mediaType")
        kindDesc.expressionResultType = .integer16AttributeType

        let sumDesc = NSExpressionDescription()
        sumDesc.name = "byteSum"
        sumDesc.expression = NSExpression(forFunction: "sum:", arguments: [NSExpression(forKeyPath: "byteSize")])
        sumDesc.expressionResultType = .integer64AttributeType

        let countDesc = NSExpressionDescription()
        countDesc.name = "recordCount"
        countDesc.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "localAssetId")])
        countDesc.expressionResultType = .integer64AttributeType

        request.propertiesToFetch = [kindDesc, sumDesc, countDesc]
        request.propertiesToGroupBy = ["mediaType"]

        do {
            let rows = try context.fetch(request)
            var totals = CleanupTotals()
            for row in rows {
                let kindRaw = (row["mediaType"] as? NSNumber)?.int16Value
                    ?? (row["mediaType"] as? Int16) ?? 0
                let kind = MediaKind(rawValue: kindRaw) ?? .photo
                let bytes = (row["byteSum"] as? Int64)
                    ?? (row["byteSum"] as? NSNumber)?.int64Value ?? 0
                let count = (row["recordCount"] as? Int)
                    ?? (row["recordCount"] as? NSNumber)?.intValue ?? 0
                totals.totalBytes += bytes
                totals.totalCount += count
                totals.bytesByKind[kind, default: 0] += bytes
            }
            return totals
        } catch {
            return totalsByFullScan(context: context)
        }
    }

    /// 兜底：全表拉取求和（聚合查询失败时使用）
    private static func totalsByFullScan(context: NSManagedObjectContext) -> CleanupTotals {
        let request = NSFetchRequest<CleanupRecord>(entityName: "CleanupRecord")
        request.predicate = NSPredicate(format: "status IN %@", [0, 1])
        let records = (try? context.fetch(request)) ?? []

        var totals = CleanupTotals()
        for record in records {
            totals.totalBytes += record.byteSize
            totals.totalCount += 1
            let kind = MediaKind(rawValue: record.mediaType) ?? .photo
            totals.bytesByKind[kind, default: 0] += record.byteSize
        }
        return totals
    }

    /// 当前相册内各类型占用（存储分析图）
    static func currentLibraryBytesByKind(_ assets: [AssetInfo]) -> [MediaKind: Int64] {
        var map: [MediaKind: Int64] = [:]
        for asset in assets {
            map[asset.kind, default: 0] += asset.byteSize
        }
        return map
    }
}
