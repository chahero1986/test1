import Photos
import UIKit

/// 异步缩略图加载 + 内存缓存（PHCachingImageManager）。
/// 性能要点：
/// - PHAsset 查询结果缓存，避免每个格子都 fetchAssets（滚动卡顿的主因之一）
/// - 缩略图按 2x 采样生成正方形裁切图（aspectFill），SwiftUI 端零缩放开销
/// - 提供批量预取接口，配合网格分页提前预热缓存
final class ThumbnailManager {
    static let shared = ThumbnailManager()
    private init() {
        cache.countLimit = 4000
    }

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    private var assetCache: [String: PHAsset] = [:]
    private let assetCacheQueue = DispatchQueue(label: "thumbnail.assetcache")

    private func asset(for id: String) -> PHAsset? {
        // 读写都必须走串行队列：网格 cell 并发触发加载，直接访问字典存在数据竞争
        if let hit = assetCacheQueue.sync(execute: { assetCache[id] }) { return hit }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        assetCacheQueue.sync {
            // 上限保护：超大图库下 PHAsset 字典只增不减会持续吃内存，超过后清空重缓存
            if assetCache.count > 8000 { assetCache.removeAll() }
            assetCache[id] = asset
        }
        return asset
    }

    /// 正方形裁切缩略图（网格用）：渐进式流 —— 缓存命中直接产出；
    /// 未命中时先产出快速低清帧（秒出），随后产出高清帧并写入缓存。
    func thumbnailStream(for info: AssetInfo, side: CGFloat) -> AsyncStream<UIImage> {
        let key = "sq-\(info.id)-\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) {
            return AsyncStream { $0.yield(hit); $0.finish() }
        }
        guard let asset = asset(for: info.id) else {
            return AsyncStream { $0.finish() }
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 图库按需取图
        options.deliveryMode = .opportunistic   // 先给低清帧再给高清帧
        options.resizeMode = .fast
        // 网格缩略图 2x 采样足够清晰，显存/解码开销比 3x 低 44%
        let scale: CGFloat = 2
        let target = CGSize(width: side * scale, height: side * scale)

        return AsyncStream { continuation in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, info in
                guard let image else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // 预解码：避免首次显示时在主线程解码造成掉帧（闪烁）；低清帧不进缓存
                let decoded = image.preparingForDisplay() ?? image
                if !degraded {
                    self.cache.setObject(decoded, forKey: key)
                    continuation.yield(decoded)
                    continuation.finish()
                } else {
                    continuation.yield(decoded)
                }
            }
        }
    }

    /// 正方形裁切缩略图：等待最终高清帧（供相簿封面等非网格场景使用）
    func thumbnail(for info: AssetInfo, side: CGFloat) async -> UIImage? {
        var result: UIImage?
        for await image in thumbnailStream(for: info, side: side) {
            result = image
        }
        return result
    }

    /// 大图查看器用（非正方形裁切，按适配缩放）
    func largeImage(for info: AssetInfo, side: CGFloat) async -> UIImage? {
        let key = "lg-\(info.id)-\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let asset = asset(for: info.id) else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let scale: CGFloat = 2
        let aspect = info.pixelWidth > 0 ? CGFloat(info.pixelHeight) / CGFloat(info.pixelWidth) : 1.5
        let target = CGSize(width: side * scale, height: side * scale * aspect)

        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
                guard let image else { continuation.resume(returning: nil); return }
                // 预解码只做一次：解码结果进缓存并直接返回
                let decoded = image.preparingForDisplay() ?? image
                self.cache.setObject(decoded, forKey: key)
                continuation.resume(returning: decoded)
            }
        }
    }

    /// 批量预取：在照片进入屏幕前预热缓存（PHCachingImageManager 原生批量接口）
    func prefetch(_ infos: [AssetInfo], side: CGFloat) {
        let assets = infos.compactMap { asset(for: $0.id) }
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let scale: CGFloat = 2
        let target = CGSize(width: side * scale, height: side * scale)
        manager.startCachingImages(for: assets, targetSize: target, contentMode: .aspectFill, options: options)
    }
}
