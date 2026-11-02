import Photos
import Foundation

/// PhotoKit 唯一封装层：业务代码不得直接接触 PHPhotoLibrary / PHAsset。
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    private init() {}

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var hasAccess: Bool {
        [.authorized, .limited].contains(authorizationStatus)
    }

    @discardableResult
    func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - 全量资产（元数据加载，缩略图由 ThumbnailManager 异步处理）

    func fetchAllAssets(sortAscending: Bool) -> [AssetInfo] {
        guard hasAccess else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: sortAscending)]
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: options)
        var list: [AssetInfo] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            list.append(Self.info(from: asset))
        }
        return list
    }

    func infos(forIds ids: [String]) -> [AssetInfo] {
        guard !ids.isEmpty, hasAccess else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [AssetInfo] = []
        list.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            list.append(Self.info(from: asset))
        }
        return list
    }

    func infos(inCollectionId collectionId: String, sortAscending: Bool) -> [AssetInfo] {
        guard hasAccess else { return [] }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionId], options: nil)
        guard let collection = collections.firstObject else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: sortAscending)]
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var list: [AssetInfo] = []
        list.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            list.append(Self.info(from: asset))
        }
        return list
    }

    /// 相册列表预览缩略图：取相册内最新的前 N 项
    func previewInfos(inCollectionId collectionId: String, limit: Int) -> [AssetInfo] {
        guard hasAccess else { return [] }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionId], options: nil)
        guard let collection = collections.firstObject else { return [] }
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var list: [AssetInfo] = []
        assets.enumerateObjects { asset, _, _ in
            list.append(Self.info(from: asset))
        }
        return list
    }

    // MARK: - 元数据归一化

    static func info(from asset: PHAsset) -> AssetInfo {
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let isLive = asset.mediaSubtypes.contains(.photoLive)
        let screenRec = asset.mediaType == .video && isScreenRecording(asset)
        let kind: MediaKind
        switch asset.mediaType {
        case .video: kind = .video
        case .image: kind = isScreenshot ? .screenshot : (isLive ? .livePhoto : .photo)
        default: kind = .photo
        }
        return AssetInfo(
            id: asset.localIdentifier,
            kind: kind,
            byteSize: byteSize(of: asset),
            durationSeconds: asset.duration,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite,
            creationDate: asset.creationDate,
            isLivePhoto: isLive,
            isScreenRecording: screenRec,
            isCameraShot: kind != .screenshot && !screenRec && asset.creationDate != nil
        )
    }

    /// 文件大小：通过 PHAssetResource 的 fileSize（KVC）获取
    private static func byteSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .reduce(Int64(0)) { $0 + Int64($1.value(forKey: "fileSize") as? Int ?? 0) }
    }

    /// 大录屏识别（已确认的近似方案）：UTI + 文件名特征
    static func isScreenRecording(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { resource in
            let name = resource.originalFilename.lowercased()
            return name.contains("screen")
                || resource.originalFilename.contains("屏幕录制")
                || resource.originalFilename.contains("录屏")
                || resource.uniformTypeIdentifier == "com.apple.screenrecording"
        }
    }

    // MARK: - 相簿

    func userAlbums() -> [AlbumSummary] {
        guard hasAccess else { return [] }
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var list: [AlbumSummary] = []
        fetch.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > 0 {
                list.append(AlbumSummary(id: collection.localIdentifier,
                                         title: collection.localizedTitle ?? "未命名",
                                         count: count))
            }
        }
        return list
    }

    /// 智能相簿：相机胶卷、收藏、截屏、视频、自拍、实况照片
    func smartAlbums() -> [AlbumSummary] {
        guard hasAccess else { return [] }
        let wanted: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumScreenshots,
            .smartAlbumVideos, .smartAlbumSelfPortraits, .smartAlbumLivePhotos
        ]
        let fetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: nil)
        var list: [AlbumSummary] = []
        fetch.enumerateObjects { collection, _, _ in
            guard wanted.contains(collection.assetCollectionSubtype) else { return }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > 0 {
                list.append(AlbumSummary(id: collection.localIdentifier,
                                         title: collection.localizedTitle ?? "未命名",
                                         count: count))
            }
        }
        return list
    }

    /// 「相簿归属」筛选依据：所有用户相簿内资产的 localIdentifier 集合（智能相簿不参与）
    func albumMemberIds() -> Set<String> {
        guard hasAccess else { return [] }
        var ids = Set<String>()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    // MARK: - 删除（走系统「最近删除」，30 天内可恢复）

    func systemDelete(ids: [String]) async throws {
        guard !ids.isEmpty, hasAccess else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
    }
}
