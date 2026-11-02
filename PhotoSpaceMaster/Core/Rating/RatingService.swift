import CoreData
import Foundation

/// 评分服务：PhotoKit 无用户评分 API，数据存 RatingItem 表。
@MainActor
final class RatingService: ObservableObject {
    static let shared = RatingService()
    private init() {}

    @Published private(set) var ratings: [String: Int] = [:]

    private var context: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    func load() {
        let request = NSFetchRequest<RatingItem>(entityName: "RatingItem")
        let items = (try? context.fetch(request)) ?? []
        ratings = Dictionary(uniqueKeysWithValues: items.map { ($0.localAssetId, Int($0.stars)) })
    }

    func setRating(_ stars: Int, for id: String) {
        guard (1...5).contains(stars) else { return }
        upsert(stars: Int16(stars), id: id)
        ratings[id] = stars
    }

    func removeRating(for id: String) {
        for item in fetchRatingItems(id: id) { context.delete(item) }
        PersistenceController.save(context)
        ratings.removeValue(forKey: id)
    }

    private func upsert(stars: Int16, id: String) {
        if let existing = fetchRatingItems(id: id).first {
            existing.stars = stars
        } else {
            let item = RatingItem(context: context)
            item.localAssetId = id
            item.stars = stars
        }
        PersistenceController.save(context)
    }

    private func fetchRatingItems(id: String) -> [RatingItem] {
        let request = NSFetchRequest<RatingItem>(entityName: "RatingItem")
        request.predicate = NSPredicate(format: "localAssetId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request)) ?? []
    }
}
