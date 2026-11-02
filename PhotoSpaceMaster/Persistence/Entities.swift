import CoreData

// MARK: - 垃圾箱（逻辑删除标记）

@objc(TrashItem)
final class TrashItem: NSManagedObject {
    @NSManaged var localAssetId: String
    @NSManaged var addedDate: Date
    @NSManaged var mediaType: Int16
    @NSManaged var byteSize: Int64
    @NSManaged var durationSeconds: Double
    @NSManaged var fileName: String?
    @NSManaged var pixelWidth: Int32
    @NSManaged var pixelHeight: Int32
}

// MARK: - 免删除项目

@objc(ProtectedItem)
final class ProtectedItem: NSManagedObject {
    @NSManaged var localAssetId: String
    @NSManaged var addedDate: Date
}

// MARK: - 应用内评分（PhotoKit 无评分 API，需自建）

@objc(RatingItem)
final class RatingItem: NSManagedObject {
    @NSManaged var localAssetId: String
    @NSManaged var stars: Int16
}

// MARK: - 清理统计
// status: 0 已移入垃圾箱 / 1 已真正删除 / 2 已恢复（恢复不计入累计释放空间）

@objc(CleanupRecord)
final class CleanupRecord: NSManagedObject {
    @NSManaged var localAssetId: String
    @NSManaged var eventDate: Date
    @NSManaged var mediaType: Int16
    @NSManaged var byteSize: Int64
    @NSManaged var status: Int16
}
