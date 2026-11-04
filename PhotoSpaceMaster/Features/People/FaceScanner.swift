import UIKit
import Photos
import Vision

/// 一张照片上检测到的单张人脸（可持久化）
struct DetectedFace: Codable, Equatable {
    let assetId: String
    /// 人脸区域（Vision 归一化坐标：左下角原点）
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// 人脸裁剪区域的感知哈希（用于跨照片聚类）
    let hash: UInt64

    var area: CGFloat { width * height }
}

/// 人脸扫描器：Vision 检测人脸 + 对裁剪人脸计算 pHash（纯本地，无网络）。
/// 说明：iOS PhotoKit 不公开系统相册的人物数据，因此这里用本机算法自建
/// 人物聚类，结果与系统相册的「人物」不会完全一致。
enum FaceScanner {
    /// 检测用的小图边长（越小越快，400px 足够人脸检测）
    private static let detectSide: CGFloat = 400

    /// 单张照片 → 全部人脸（含哈希）；照片加载失败返回空数组
    static func detectFaces(assetId: String) -> [DetectedFace] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let image = loadImage(asset: asset, side: detectSide),
              let cg = image.cgImage
        else { return [] }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        guard let observations = request.results else { return [] }

        return observations.compactMap { observation in
            let box = observation.boundingBox
            // 裁剪人脸区域后计算感知哈希（聚类依据）
            guard let faceImage = crop(cg: cg, box: box), let hash = PerceptualHash.phash(of: faceImage) else { return nil }
            return DetectedFace(
                assetId: assetId,
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height,
                hash: hash
            )
        }
    }

    /// 按边长加载小图（同步请求，供扫描任务组在后台线程调用）
    static func loadImage(asset: PHAsset, side: CGFloat) -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .fastFormat
        opts.resizeMode = .fast
        var image: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            options: opts
        ) { img, _ in image = img }
        return image
    }

    /// 按归一化 Vision 坐标裁剪 CGImage（返回人脸小图）
    static func crop(cg: CGImage, box: CGRect) -> UIImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        // Vision 坐标系左下角原点 → 位图左上角原点
        let rect = CGRect(
            x: box.origin.x * w,
            y: (1 - box.origin.y - box.height) * h,
            width: box.width * w,
            height: box.height * h
        )
        // 稍微外扩 8%，包含发型轮廓，提升聚类区分度
        let expanded = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
        guard let cropped = cg.cropping(to: expanded.integral) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
