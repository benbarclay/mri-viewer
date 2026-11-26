import Foundation

/// Scalar fields whose zero level set is a surface (positive = inside). Combining fields with
/// `min` / `max` gives intersection / union, which is how print parts, cavities and cuts are built.
public enum Fields {
    /// Approximate signed distance (mm) to the boundary of a binary mask: positive inside.
    /// The zero crossing lies half-way between inside and outside voxel centres.
    public static func signedDistance(_ mask: [UInt8], _ g: Grid) -> [Float] {
        let dIn = Filters.distanceSquared(mask, g, to: 0, outsideIsTarget: true)   // inside → nearest outside
        let dOut = Filters.distanceSquared(mask, g, to: 1, outsideIsTarget: false) // outside → nearest inside
        let half = Float(0.5 * min(g.sx, g.sy, g.sz))
        var out = [Float](repeating: 0, count: g.count)
        for i in 0 ..< g.count {
            out[i] = mask[i] != 0 ? sqrt(dIn[i]) - half : -(sqrt(dOut[i]) - half)
        }
        return out
    }

    /// Smooth signed field (mm) for a binary mask: signed distance with a light blur, so the surface
    /// has no voxel terraces even where no intensity edge exists (e.g. cuts between brain regions).
    public static func smoothMaskField(_ mask: [UInt8], _ g: Grid, blurMM: Double? = nil) -> [Float] {
        let sd = signedDistance(mask, g)
        return Filters.gaussian(sd, g, sigmaMM: blurMM ?? 0.75 * min(g.sx, g.sy, g.sz))
    }

    /// Intensity-guided field: the surface follows the smoothed intensity's crossing of `threshold`
    /// (sub-voxel accurate, so no stair-steps), but only within `bandMM` of the segmentation mask's
    /// boundary. Deeper inside the mask the field is forced positive, further outside forced negative,
    /// so the segmentation still decides *what* is included while the intensity decides *where* the
    /// surface lies. Output is in mm (intensity scaled by its typical edge gradient).
    public static func guided(intensity s: [Float], threshold t: Float, mask: [UInt8], _ g: Grid,
                              bandMM: Double = 1.5, contrast: Float, maskBlurMM: Double? = nil) -> [Float] {
        let d = smoothMaskField(mask, g, blurMM: maskBlurMM)
        let b = Float(bandMM)
        // Convert intensity difference to approximate mm: `contrast` is the intensity change across
        // ~2 mm of boundary (half the tissue/background difference per mm).
        let perMM = max(1e-6, contrast / 2)
        var out = [Float](repeating: 0, count: g.count)
        for i in 0 ..< g.count {
            let fi = (s[i] - t) / perMM
            out[i] = max(min(fi, d[i] + b), d[i] - b)
        }
        return out
    }

    public static func intersect(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { min($0, $1) } }
    public static func union(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { max($0, $1) } }
    public static func subtract(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { min($0, -$1) } }
    public static func offset(_ a: [Float], by mm: Float) -> [Float] { a.map { $0 + mm } }
}
