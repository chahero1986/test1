import CoreData
import Foundation

/// 清理操作唯一入口：移入垃圾箱 / 恢复 / 真删 / 免删除。
/// 同步维护 TrashItem、ProtectedItem、CleanupRecord 与 AppState 内的内存集合。
@MainActor
enum CleanupService {

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

        let now = Date()
        for info in skipped {
            if fetchTrashItem(id: info.id) != nil { continue }
            let item = TrashItem(context: context)
            item.localAssetId = info.id
            item.addedDate = now
            item.mediaType = info.kind.rawValue
            item.byteSize = info.byteSize
            item.durationSeconds = info.durationSeconds
            item.pixelWidth = 0
            item.pixelHeight = 0
            upsertCleanupRecord(id: info.id, kind: info.kind, bytes: info.byteSize, status: 0)
        }
        PersistenceController.save(context)
        state.trashIds.formUnion(skipped.map(\.id))
    }

    // MARK: - 恢复

    static func restore(ids: [String], state: AppState) {
        for id in ids {
            if let item = fetchTrashItem(id: id) { context.delete(item) }
            updateCleanupRecords(id: id, status: 2)
        }
        PersistenceController.save(context)
        state.trashIds.subtract(ids)
    }

    // MARK: - 真正删除（调用 PhotoKit，走系统「最近删除」）

    /// - Parameter library: 传入后删除成功会立即重新加载相册元数据，首页/相册等页面即时更新
    static func realDelete(ids: [String], state: AppState, library: LibraryStore? = nil) async throws {
        try await PhotoLibraryService.shared.systemDelete(ids: ids)
        for id in ids {
            if let item = fetchTrashItem(id: id) { context.delete(item) }
            updateCleanupRecords(id: id, status: 1)
        }
        PersistenceController.save(context)
        state.trashIds.subtract(ids)
        // 关键：重新加载相册，让已删除的照片从所有列表中消失
        library?.reload()
    }

    // MARK: - 免删除

    static func toggleProtected(_ ids: [String], state: AppState) {
        for id in ids {
            if state.protectedIds.contains(id) {
                if let item = fetchProtectedItem(id: id) { context.delete(item) }
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

    private static func upsertCleanupRecord(id: String, kind: MediaKind, bytes: Int64, status: Int16) {
        if let record = fetchCleanupRecord(id: id) {
            record.eventDate = Date()
            record.status = status
            record.byteSize = bytes
            record.mediaType = kind.rawValue
        } else {
            let record = CleanupRecord(context: context)
            record.localAssetId = id
            record.eventDate = Date()
            record.mediaType = kind.rawValue
            record.byteSize = bytes
            record.status = status
        }
    }

    private static func updateCleanupRecords(id: String, status: Int16) {
        fetchCleanupRecord(id: id)?.status = status
    }

    private static func fetchTrashItem(id: String) -> TrashItem? {
        let request = NSFetchRequest<TrashItem>(entityName: "TrashItem")
        request.predicate = NSPredicate(format: "localAssetId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func fetchProtectedItem(id: String) -> ProtectedItem? {
        let request = NSFetchRequest<ProtectedItem>(entityName: "ProtectedItem")
        request.predicate = NSPredicate(format: "localAssetId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func fetchCleanupRecord(id: String) -> CleanupRecord? {
        let request = NSFetchRequest<CleanupRecord>(entityName: "CleanupRecord")
        request.predicate = NSPredicate(format: "localAssetId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
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
    static func totals() -> CleanupTotals {
        let context = PersistenceController.shared.container.viewContext
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
