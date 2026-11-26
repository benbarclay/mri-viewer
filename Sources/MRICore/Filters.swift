import Foundation

/// Grid shape + physical spacing shared by the volume filters. Data is x-fastest, then y, then z.
public struct Grid: Equatable {
    public let nx: Int, ny: Int, nz: Int
    public let sx: Double, sy: Double, sz: Double
    public init(nx: Int, ny: Int, nz: Int, sx: Double = 1, sy: Double = 1, sz: Double = 1) {
        self.nx = nx; self.ny = ny; self.nz = nz; self.sx = sx; self.sy = sy; self.sz = sz
    }
    public init(_ v: Volume) { self.init(nx: v.nx, ny: v.ny, nz: v.nz, sx: v.spacing.x, sy: v.spacing.y, sz: v.spacing.z) }
    public var count: Int { nx * ny * nz }
    public var voxelVolume: Double { sx * sy * sz }
    @inline(__always) public func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
}

public enum Filters {
    // MARK: smoothing / resampling

    /// Separable Gaussian blur, sigma in mm. Edges are clamped.
    public static func gaussian(_ data: [Float], _ g: Grid, sigmaMM: Double) -> [Float] {
        guard sigmaMM > 0 else { return data }
        var a = data
        var b = [Float](repeating: 0, count: data.count)
        for axis in 0 ..< 3 {
            let s = [g.sx, g.sy, g.sz][axis]
            let sigma = sigmaMM / s
            if sigma < 0.2 { continue }
            let r = max(1, Int(ceil(3 * sigma)))
            var k = (-r ... r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
            let sum = k.reduce(0, +)
            k = k.map { $0 / sum }
            let n = [g.nx, g.ny, g.nz][axis]
            let stride = [1, g.nx, g.nx * g.ny][axis]
            let lines = g.count / n
            a.withUnsafeBufferPointer { src in
                b.withUnsafeMutableBufferPointer { dst in
                    DispatchQueue.concurrentPerform(iterations: lines) { line in
                        // Start index of this 1-D line.
                        let start: Int
                        switch axis {
                        case 0: start = line * g.nx
                        case 1: start = (line / g.nx) * g.nx * g.ny + (line % g.nx)
                        default: start = line
                        }
                        for i in 0 ..< n {
                            var acc: Float = 0
                            for j in -r ... r {
                                let ii = min(n - 1, max(0, i + j))
                                acc += k[j + r] * src[start + ii * stride]
                            }
                            dst[start + i * stride] = acc
                        }
                    }
                }
            }
            swap(&a, &b)
        }
        return a
    }

    /// Box-average downsampling by an integer factor.
    public static func downsample(_ v: Volume, factor f: Int) -> Volume {
        guard f > 1 else { return v }
        let nx = v.nx / f, ny = v.ny / f, nz = v.nz / f
        var out = [Float](repeating: 0, count: nx * ny * nz)
        let inv = 1 / Float(f * f * f)
        for z in 0 ..< nz { for y in 0 ..< ny { for x in 0 ..< nx {
            var acc: Float = 0
            for dz in 0 ..< f { for dy in 0 ..< f { for dx in 0 ..< f {
                acc += v.value(x * f + dx, y * f + dy, z * f + dz)
            } } }
            out[(z * ny + y) * nx + x] = acc * inv
        } } }
        // Voxel centres shift by (f-1)/2 original voxels.
        let shift = Double(f - 1) / 2
        let origin = v.patient(SIMD3(shift, shift, shift))
        let r = Volume(nx: nx, ny: ny, nz: nz, spacing: v.spacing * Double(f), origin: origin, axes: v.axes, data: out)
        r.warnings = v.warnings
        return r
    }

    // MARK: thresholds

    /// Otsu threshold over values (optionally only those above `above`).
    public static func otsu(_ data: [Float], above: Float = -.greatestFiniteMagnitude) -> Float {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var n = 0
        for v in data where v > above { lo = min(lo, v); hi = max(hi, v); n += 1 }
        guard n > 0, hi > lo else { return lo }
        let bins = 1024
        var hist = [Double](repeating: 0, count: bins)
        let scale = Float(bins - 1) / (hi - lo)
        for v in data where v > above { hist[Int((v - lo) * scale)] += 1 }
        let total = Double(n)
        var sumAll = 0.0
        for i in 0 ..< bins { sumAll += Double(i) * hist[i] }
        var wB = 0.0, sumB = 0.0, best = 0.0, bestI = 0
        for i in 0 ..< bins {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i) * hist[i]
            let mB = sumB / wB, mF = (sumAll - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; bestI = i }
        }
        return lo + (Float(bestI) + 0.5) / scale
    }

    public static func threshold(_ data: [Float], _ t: Float) -> [UInt8] { data.map { $0 >= t ? 1 : 0 } }

    // MARK: distance transforms and morphology

    /// Squared Euclidean distance (mm²) from every voxel to the nearest voxel where `mask == target`.
    /// Voxels outside the grid are treated as `outside` (true = they count as targets).
    public static func distanceSquared(_ mask: [UInt8], _ g: Grid, to target: UInt8, outsideIsTarget: Bool) -> [Float] {
        let inf: Float = 1e20
        // Pad by one voxel so the "outside" condition is represented explicitly.
        let px = g.nx + 2, py = g.ny + 2, pz = g.nz + 2
        var f = [Float](repeating: outsideIsTarget ? 0 : inf, count: px * py * pz)
        for z in 0 ..< g.nz { for y in 0 ..< g.ny { for x in 0 ..< g.nx {
            f[((z + 1) * py + (y + 1)) * px + (x + 1)] = mask[g.index(x, y, z)] == target ? 0 : inf
        } } }
        let pg = Grid(nx: px, ny: py, nz: pz, sx: g.sx, sy: g.sy, sz: g.sz)
        for axis in 0 ..< 3 { edt1D(&f, pg, axis: axis) }
        var out = [Float](repeating: 0, count: g.count)
        for z in 0 ..< g.nz { for y in 0 ..< g.ny { for x in 0 ..< g.nx {
            out[g.index(x, y, z)] = f[((z + 1) * py + (y + 1)) * px + (x + 1)]
        } } }
        return out
    }

    /// Felzenszwalb–Huttenlocher 1-D squared distance transform along one axis, in place.
    static func edt1D(_ f: inout [Float], _ g: Grid, axis: Int) {
        let n = [g.nx, g.ny, g.nz][axis]
        let stride = [1, g.nx, g.nx * g.ny][axis]
        let w = Float([g.sx, g.sy, g.sz][axis] * [g.sx, g.sy, g.sz][axis])
        let lines = g.count / n
        f.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: lines) { line in
                let start: Int
                switch axis {
                case 0: start = line * g.nx
                case 1: start = (line / g.nx) * g.nx * g.ny + (line % g.nx)
                default: start = line
                }
                var src = [Float](repeating: 0, count: n)
                for i in 0 ..< n { src[i] = buf[start + i * stride] }
                var v = [Int](repeating: 0, count: n)
                var zb = [Float](repeating: 0, count: n + 1)
                var k = 0
                // Skip leading infinities so parabola intersections stay finite.
                var first = -1
                for i in 0 ..< n where src[i] < 1e19 { first = i; break }
                if first < 0 { return }
                v[0] = first; zb[0] = -.greatestFiniteMagnitude; zb[1] = .greatestFiniteMagnitude
                if first + 1 < n {
                    for q in (first + 1) ..< n where src[q] < 1e19 {
                        var s: Float
                        repeat {
                            let p = v[k]
                            s = ((src[q] + w * Float(q * q)) - (src[p] + w * Float(p * p))) / (2 * w * Float(q - p))
                            if s <= zb[k] { k -= 1 } else { break }
                        } while k >= 0
                        k += 1
                        v[k] = q; zb[k] = s; zb[k + 1] = .greatestFiniteMagnitude
                    }
                }
                k = 0
                for q in 0 ..< n {
                    while zb[k + 1] < Float(q) { k += 1 }
                    let d = Float(q - v[k])
                    buf[start + q * stride] = w * d * d + src[v[k]]
                }
            }
        }
    }

    /// Euclidean erosion by `radiusMM`. Outside the grid counts as background unless
    /// `keepCutFaces` (then an object clipped by the field of view keeps its cut faces).
    public static func erode(_ mask: [UInt8], _ g: Grid, radiusMM: Double, keepCutFaces: Bool = false) -> [UInt8] {
        guard radiusMM > 0 else { return mask }
        let d = distanceSquared(mask, g, to: 0, outsideIsTarget: !keepCutFaces)
        let r2 = Float(radiusMM * radiusMM)
        return d.map { $0 > r2 ? 1 : 0 }
    }

    /// Euclidean dilation by `radiusMM`.
    public static func dilate(_ mask: [UInt8], _ g: Grid, radiusMM: Double) -> [UInt8] {
        guard radiusMM > 0 else { return mask }
        let d = distanceSquared(mask, g, to: 1, outsideIsTarget: false)
        let r2 = Float(radiusMM * radiusMM)
        return d.map { $0 <= r2 ? 1 : 0 }
    }

    // MARK: connectivity

    /// 6-connected component labels (0 = background) and component sizes (index = label).
    public static func components(_ mask: [UInt8], _ g: Grid) -> (labels: [Int32], sizes: [Int]) {
        var labels = [Int32](repeating: 0, count: g.count)
        var sizes = [0]
        var stack: [Int] = []
        let sxy = g.nx * g.ny
        for seed in 0 ..< g.count where mask[seed] != 0 && labels[seed] == 0 {
            let label = Int32(sizes.count)
            var size = 0
            labels[seed] = label
            stack.append(seed)
            while let i = stack.popLast() {
                size += 1
                let x = i % g.nx, y = (i / g.nx) % g.ny, z = i / sxy
                @inline(__always) func visit(_ j: Int) {
                    if mask[j] != 0 && labels[j] == 0 { labels[j] = label; stack.append(j) }
                }
                if x > 0 { visit(i - 1) }
                if x < g.nx - 1 { visit(i + 1) }
                if y > 0 { visit(i - g.nx) }
                if y < g.ny - 1 { visit(i + g.nx) }
                if z > 0 { visit(i - sxy) }
                if z < g.nz - 1 { visit(i + sxy) }
            }
            sizes.append(size)
        }
        return (labels, sizes)
    }

    public static func largestComponent(_ mask: [UInt8], _ g: Grid) -> [UInt8] {
        let (labels, sizes) = components(mask, g)
        guard sizes.count > 1, let best = sizes.indices.dropFirst().max(by: { sizes[$0] < sizes[$1] }) else {
            return [UInt8](repeating: 0, count: g.count)
        }
        return labels.map { $0 == Int32(best) ? 1 : 0 }
    }

    /// Fills background regions not connected (6-conn) to the grid border.
    public static func fillHoles(_ mask: [UInt8], _ g: Grid) -> [UInt8] {
        var outside = [UInt8](repeating: 0, count: g.count)
        var stack: [Int] = []
        let sxy = g.nx * g.ny
        func seed(_ i: Int) { if mask[i] == 0 && outside[i] == 0 { outside[i] = 1; stack.append(i) } }
        for z in 0 ..< g.nz { for y in 0 ..< g.ny { for x in 0 ..< g.nx
            where x == 0 || y == 0 || z == 0 || x == g.nx - 1 || y == g.ny - 1 || z == g.nz - 1 {
            seed(g.index(x, y, z))
        } } }
        while let i = stack.popLast() {
            let x = i % g.nx, y = (i / g.nx) % g.ny, z = i / sxy
            if x > 0 { seed(i - 1) }
            if x < g.nx - 1 { seed(i + 1) }
            if y > 0 { seed(i - g.nx) }
            if y < g.ny - 1 { seed(i + g.nx) }
            if z > 0 { seed(i - sxy) }
            if z < g.nz - 1 { seed(i + sxy) }
        }
        return outside.map { $0 == 0 ? 1 : 0 }
    }

    /// Fills holes independently in every 2-D slice perpendicular to voxel axis `axis` (4-connected).
    /// Closes regions a 3-D fill cannot, e.g. a head whose top is clipped by the field of view.
    public static func fillHoles2D(_ mask: [UInt8], _ g: Grid, axis: Int) -> [UInt8] {
        let dims = [g.nx, g.ny, g.nz]
        let (ua, va) = axis == 0 ? (1, 2) : axis == 1 ? (0, 2) : (0, 1)
        let w = dims[ua], h = dims[va]
        var out = mask
        out.withUnsafeMutableBufferPointer { dst in
            DispatchQueue.concurrentPerform(iterations: dims[axis]) { k in
                var c = [0, 0, 0]
                c[axis] = k
                func idx(_ u: Int, _ v: Int) -> Int {
                    var cc = c; cc[ua] = u; cc[va] = v
                    return g.index(cc[0], cc[1], cc[2])
                }
                var outside = [UInt8](repeating: 0, count: w * h)
                var stack: [Int] = []
                func seed(_ u: Int, _ v: Int) {
                    let j = v * w + u
                    if outside[j] == 0 && mask[idx(u, v)] == 0 { outside[j] = 1; stack.append(j) }
                }
                for u in 0 ..< w { seed(u, 0); seed(u, h - 1) }
                for v in 0 ..< h { seed(0, v); seed(w - 1, v) }
                while let j = stack.popLast() {
                    let u = j % w, v = j / w
                    if u > 0 { seed(u - 1, v) }
                    if u < w - 1 { seed(u + 1, v) }
                    if v > 0 { seed(u, v - 1) }
                    if v < h - 1 { seed(u, v + 1) }
                }
                for v in 0 ..< h { for u in 0 ..< w where outside[v * w + u] == 0 { dst[idx(u, v)] = 1 } }
            }
        }
        return out
    }

    /// 3-D hole fill for an object clipped by the field of view: the cross-section on each of the six
    /// grid faces is hole-filled in 2-D first, so interior regions that touch a cut face (e.g. skull and
    /// CSF where the scan clips the side or top of the head) are not mistaken for outside air.
    public static func fillHolesClosingCutFaces(_ mask: [UInt8], _ g: Grid) -> [UInt8] {
        var m = mask
        let dims = [g.nx, g.ny, g.nz]
        for axis in 0 ..< 3 {
            let (ua, va) = axis == 0 ? (1, 2) : axis == 1 ? (0, 2) : (0, 1)
            let w = dims[ua], h = dims[va]
            for k in [0, dims[axis] - 1] {
                func idx(_ u: Int, _ v: Int) -> Int {
                    var c = [0, 0, 0]; c[axis] = k; c[ua] = u; c[va] = v
                    return g.index(c[0], c[1], c[2])
                }
                var outside = [UInt8](repeating: 0, count: w * h)
                var stack: [Int] = []
                func seed(_ u: Int, _ v: Int) {
                    let j = v * w + u
                    if outside[j] == 0 && m[idx(u, v)] == 0 { outside[j] = 1; stack.append(j) }
                }
                for u in 0 ..< w { seed(u, 0); seed(u, h - 1) }
                for v in 0 ..< h { seed(0, v); seed(w - 1, v) }
                while let j = stack.popLast() {
                    let u = j % w, v = j / w
                    if u > 0 { seed(u - 1, v) }
                    if u < w - 1 { seed(u + 1, v) }
                    if v > 0 { seed(u, v - 1) }
                    if v < h - 1 { seed(u, v + 1) }
                }
                for v in 0 ..< h { for u in 0 ..< w where outside[v * w + u] == 0 { m[idx(u, v)] = 1 } }
            }
        }
        return fillHoles(m, g)
    }

    public static func and(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 & $1 } }
    public static func count(_ m: [UInt8]) -> Int { m.reduce(0) { $0 + Int($1) } }
}
