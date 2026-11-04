import UIKit

/// 感知哈希（pHash）：32×32 灰度 → DCT → 左上 8×8（去 DC）→ 中位数二值化 → 64 位指纹。
/// 用于相似/重复照片判定，纯本地计算，不访问网络。
enum PerceptualHash {

    /// DCT 余弦表：纯常量，进程内只计算一次（原实现每张图重建 32×32 表，纯浪费）
    private static let cosTable: [[Double]] = {
        let size = 32
        return (0..<size).map { u in
            (0..<size).map { x in
                cos((2 * Double(x) + 1) * Double(u) * Double.pi / (2 * Double(size)))
            }
        }
    }()

    /// 计算一张图片的 64 位 pHash
    static func phash(of image: UIImage) -> UInt64? {
        guard let cg = image.cgImage else { return nil }
        let size = 32
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // 转灰度
        var gray = [Double](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let r = Double(ptr[i * 4])
            let g = Double(ptr[i * 4 + 1])
            let b = Double(ptr[i * 4 + 2])
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        let cosTable = Self.cosTable

        // 分离式 DCT-II：先按行、再按列
        var tmp = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for u in 0..<size {
                var sum = 0.0
                for x in 0..<size { sum += gray[y * size + x] * cosTable[u][x] }
                tmp[y * size + u] = sum
            }
        }
        var dct = [Double](repeating: 0, count: size * size)
        for v in 0..<size {
            for u in 0..<size {
                var sum = 0.0
                for y in 0..<size { sum += tmp[y * size + v] * cosTable[u][y] }
                dct[u * size + v] = sum
            }
        }

        // 左上 8×8（跳过 DC 分量），以中位数二值化
        var lows: [Double] = []
        lows.reserveCapacity(63)
        for u in 0..<8 {
            for v in 0..<8 where !(u == 0 && v == 0) {
                lows.append(dct[u * size + v])
            }
        }
        lows.sort()
        let median = lows[lows.count / 2]

        var bits: UInt64 = 0
        var idx: UInt64 = 0
        for u in 0..<8 {
            for v in 0..<8 {
                if u == 0 && v == 0 { continue }
                if dct[u * size + v] > median { bits |= (1 << idx) }
                idx += 1
            }
        }
        return bits
    }

    /// 两个指纹的汉明距离（0 = 完全一致）
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
