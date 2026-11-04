import Foundation
import Photos
import ImageIO
import CoreLocation
import AVFoundation
import UIKit

/// 大图查看器的详情元数据：拍摄地点/海拔（反向地理编码）、相机参数（EXIF）、视频播放项。
final class AssetDetailProvider {
    static let shared = AssetDetailProvider()
    private init() {}

    private let cameraCache = NSCache<NSString, NSString>()
    private let locationCache = NSCache<NSString, NSString>()

    // MARK: - 视频播放项

    /// AVPlayerItem 缓存：左右滑动到视频时直接复用预取结果，避免黑屏等待
    private var playerItemCache: [String: AVPlayerItem] = [:]
    private let playerItemQueue = DispatchQueue(label: "detail.playeritem")

    private func cachedPlayerItem(for id: String) -> AVPlayerItem? {
        playerItemQueue.sync { playerItemCache[id] }
    }

    private func storePlayerItem(_ item: AVPlayerItem, for id: String) {
        playerItemQueue.sync {
            // 上限保护：详情页浏览跨度可能很大，只保留最近 20 条
            if playerItemCache.count >= 20 { playerItemCache.removeAll() }
            playerItemCache[id] = item
        }
    }

    func playerItem(for info: AssetInfo) async -> AVPlayerItem? {
        guard info.kind == .video else { return nil }
        if let hit = cachedPlayerItem(for: info.id) { return hit }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [info.id], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
        if let item { storePlayerItem(item, for: info.id) }
        return item
    }

    /// 预取相邻视频的播放项（幻灯片翻页前调用），使滑到视频时立即可播
    func preloadPlayerItem(for info: AssetInfo) {
        guard info.kind == .video, cachedPlayerItem(for: info.id) == nil else { return }
        Task { _ = await self.playerItem(for: info) }
    }

    // MARK: - 地点 · 海拔

    func locationText(for info: AssetInfo) async -> String? {
        if let hit = locationCache.object(forKey: info.id as NSString) { return hit as String }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [info.id], options: nil)
        guard let asset = fetch.firstObject, let location = asset.location else { return nil }

        var parts: [String] = []
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location), let place = placemarks.first {
            let name = [place.locality, place.subLocality, place.name]
                .compactMap { $0 }
                .joined(separator: " ")
            if !name.isEmpty { parts.append(name) }
        }
        parts.append(String(format: "海拔 %.0f 米", location.altitude))
        guard !parts.isEmpty else { return nil }

        let text = parts.joined(separator: " · ")
        locationCache.setObject(text as NSString, forKey: info.id as NSString)
        return text
    }

    // MARK: - 相机参数（EXIF：机型 · 焦距 · 光圈 · 快门 · ISO）

    func cameraParamsText(for info: AssetInfo) async -> String? {
        guard info.kind != .video else { return nil }
        if let hit = cameraCache.object(forKey: info.id as NSString) { return hit as String }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [info.id], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })
        else { return nil }

        // 写到临时文件再读 EXIF
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-\(UUID().uuidString)")
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]

        var parts: [String] = []
        if let model = tiff?[kCGImagePropertyTIFFModel as String] as? String {
            parts.append(model)
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength as String] as? Double {
            parts.append(String(format: "%.0fmm", focal))
        }
        if let fNumber = exif?[kCGImagePropertyExifFNumber as String] as? Double {
            parts.append(String(format: "ƒ/%.1f", fNumber))
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime as String] as? Double {
            parts.append(exposure >= 1 ? String(format: "%.0fs", exposure) : String(format: "1/%.0fs", 1 / exposure))
        }
        if let isoList = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let iso = isoList.first {
            parts.append("ISO \(iso)")
        }
        guard !parts.isEmpty else { return nil }

        let text = parts.joined(separator: " · ")
        cameraCache.setObject(text as NSString, forKey: info.id as NSString)
        return text
    }
}
