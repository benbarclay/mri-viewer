import CoreGraphics
import MRICore

enum SliceRenderer {
    /// Window/level a slice into an RGBA image, optionally tinting `overlay` voxels.
    static func image(_ s: Slice2D, center: Float, width: Float, overlay: [UInt8]? = nil, colors: [SIMD3<Float>?]? = nil) -> CGImage? {
        let n = s.width * s.height
        var rgba = [UInt8](repeating: 255, count: n * 4)
        let lo = center - width / 2
        let scale = 255 / max(1e-6, width)
        for i in 0 ..< n {
            let g = UInt8(clamping: Int(((s.pixels[i] - lo) * scale).rounded()))
            var r = g, gg = g, b = g
            if let o = overlay, o[i] != 0 {
                // 40% orange tint
                r = UInt8(min(255, Int(Double(g) * 0.6 + 255 * 0.4)))
                gg = UInt8(min(255, Int(Double(g) * 0.6 + 140 * 0.4)))
                b = UInt8(Double(g) * 0.6)
            }
            if let cs = colors, let c = cs[i] {
                // 45% tint with the region colour
                r = UInt8(min(255, Double(g) * 0.55 + Double(c.x) * 255 * 0.45))
                gg = UInt8(min(255, Double(g) * 0.55 + Double(c.y) * 255 * 0.45))
                b = UInt8(min(255, Double(g) * 0.55 + Double(c.z) * 255 * 0.45))
            }
            rgba[4 * i] = r; rgba[4 * i + 1] = gg; rgba[4 * i + 2] = b
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

import Foundation
