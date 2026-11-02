import Photos
import UIKit

/// 异步缩略图加载 + 内存缓存（PHCachingImageManager）。
final class ThumbnailManager {
    static let shared = ThumbnailManager()
    private init() {
        cache.countLimit = 3000
    }

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    func thumbnail(for info: AssetInfo, side: CGFloat) async -> UIImage? {
        let key = "\(info.id)-\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [info.id], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 图库按需取图
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let scale = UIScreen.main.scale
        let target = CGSize(width: side * scale, height: side * scale)

        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, _ in
                if let image {
                    self.cache.setObject(image, forKey: key)
                }
                continuation.resume(returning: image)
            }
        }
    }
}
