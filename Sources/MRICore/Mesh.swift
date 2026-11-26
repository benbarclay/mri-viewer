import Foundation
import simd

/// Indexed triangle mesh in patient space (mm).
public struct Mesh {
    public var vertices: [SIMD3<Float>]
    public var triangles: [UInt32]   // 3 indices per triangle, counter-clockwise seen from outside
    public init(vertices: [SIMD3<Float>] = [], triangles: [UInt32] = []) {
        self.vertices = vertices; self.triangles = triangles
    }
    public var triangleCount: Int { triangles.count / 3 }
}

// MARK: - Iso-surface extraction

public enum Isosurface {
    /// Marching tetrahedra (Freudenthal 6-tet split) on a scalar field. Voxels with value >= iso are inside.
    ///
    /// Chosen over marching cubes because the consistent tetrahedral split makes the output a closed
    /// 2-manifold whenever the inside region does not touch the grid border — what a 3D printer needs.
    /// The field is padded internally so surfaces touching the border are closed as well.
    /// Output vertices are in patient mm via `toPatient` (voxel coordinates → mm).
    public static func extract(_ field: [Float], _ g: Grid, iso: Float, toPatient: (SIMD3<Double>) -> SIMD3<Double>, flipWinding: Bool = false) -> Mesh {
        // Pad by one voxel of "outside" on every side.
        let px = g.nx + 2, py = g.ny + 2, pz = g.nz + 2
        let low = iso - 1
        var f = [Float](repeating: low, count: px * py * pz)
        for z in 0 ..< g.nz { for y in 0 ..< g.ny {
            let src = (z * g.ny + y) * g.nx
            let dst = ((z + 1) * py + (y + 1)) * px + 1
            for x in 0 ..< g.nx { f[dst + x] = field[src + x] }
        } }
        let sxy = px * py
        // Corner c (bit0 = +x, bit1 = +y, bit2 = +z) offsets in the padded grid.
        let cornerOffset = (0 ..< 8).map { c in (c & 1) + ((c >> 1) & 1) * px + ((c >> 2) & 1) * sxy }
        // Six tetrahedra: walk 0 → 7 along each axis permutation.
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let tets: [[Int]] = perms.map { p in
            let a = 1 << p[0], b = a | (1 << p[1])
            return [0, a, b, 7]
        }

        var vertexMap: [Int: UInt32] = [:]
        vertexMap.reserveCapacity(1 << 20)
        var verts: [SIMD3<Float>] = []
        var tris: [UInt32] = []

        @inline(__always) func edgeVertex(_ base: Int, _ ca: Int, _ cb: Int) -> UInt32 {
            // Edge between corners ca and cb; tet edges always connect a corner to a superset corner.
            let (lo, hi) = (ca & cb) == ca ? (ca, cb) : (cb, ca)
            let i0 = base + cornerOffset[lo]
            let key = i0 &* 8 &+ (hi ^ lo)
            if let v = vertexMap[key] { return v }
            let va = f[i0], vb = f[base + cornerOffset[hi]]
            var t = (iso - va) / (vb - va)
            if !t.isFinite { t = 0.5 }
            t = min(0.999, max(0.001, t)) // keep vertices off grid corners (avoids zero-area faces)
            let x0 = i0 % px, y0 = (i0 / px) % py, z0 = i0 / sxy
            let d = hi ^ lo
            let p = SIMD3<Double>(Double(x0) + Double(d & 1) * Double(t) - 1,
                                  Double(y0) + Double((d >> 1) & 1) * Double(t) - 1,
                                  Double(z0) + Double((d >> 2) & 1) * Double(t) - 1)
            let q = toPatient(p)
            let idx = UInt32(verts.count)
            verts.append(SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z)))
            vertexMap[key] = idx
            return idx
        }

        func cornerPos(_ c: Int) -> SIMD3<Float> { SIMD3(Float(c & 1), Float((c >> 1) & 1), Float((c >> 2) & 1)) }

        // Emit a triangle on edge vertices, oriented so its normal points from inside to outside.
        func emit(_ a: UInt32, _ b: UInt32, _ c: UInt32, insideC: SIMD3<Float>, outsideC: SIMD3<Float>, local: [UInt32: SIMD3<Float>]) {
            let pa = local[a]!, pb = local[b]!, pc = local[c]!
            let n = simd_cross(pb - pa, pc - pa)
            var ccw = simd_dot(n, outsideC - insideC) > 0
            if flipWinding { ccw.toggle() }
            if ccw { tris += [a, b, c] } else { tris += [a, c, b] }
        }

        for z in 0 ..< pz - 1 { for y in 0 ..< py - 1 { for x in 0 ..< px - 1 {
            let base = (z * py + y) * px + x
            var inside = 0
            for c in 0 ..< 8 where f[base + cornerOffset[c]] >= iso { inside |= 1 << c }
            if inside == 0 || inside == 0xFF { continue }
            for tet in tets {
                var ins: [Int] = [], outs: [Int] = []
                for c in tet { if inside & (1 << c) != 0 { ins.append(c) } else { outs.append(c) } }
                if ins.isEmpty || outs.isEmpty { continue }
                // Local (cell-space) positions of the interpolated vertices, used only for orientation.
                var local: [UInt32: SIMD3<Float>] = [:]
                func ev(_ a: Int, _ b: Int) -> UInt32 {
                    let id = edgeVertex(base, a, b)
                    let va = f[base + cornerOffset[a]], vb = f[base + cornerOffset[b]]
                    var t = (iso - va) / (vb - va)
                    if !t.isFinite { t = 0.5 }
                    t = min(0.999, max(0.001, t))
                    local[id] = cornerPos(a) + (cornerPos(b) - cornerPos(a)) * t
                    return id
                }
                let inC = ins.map(cornerPos).reduce(.zero, +) / Float(ins.count)
                let outC = outs.map(cornerPos).reduce(.zero, +) / Float(outs.count)
                switch ins.count {
                case 1, 3:
                    let apex = ins.count == 1 ? ins[0] : outs[0]
                    let others = ins.count == 1 ? outs : ins
                    let a = ev(apex, others[0]), b = ev(apex, others[1]), c = ev(apex, others[2])
                    emit(a, b, c, insideC: inC, outsideC: outC, local: local)
                default: // 2 inside, 2 outside → quad
                    let (i0, i1, o0, o1) = (ins[0], ins[1], outs[0], outs[1])
                    let p00 = ev(i0, o0), p01 = ev(i0, o1), p11 = ev(i1, o1), p10 = ev(i1, o0)
                    if p00 != p01 && p01 != p11 && p00 != p11 { emit(p00, p01, p11, insideC: inC, outsideC: outC, local: local) }
                    if p00 != p11 && p11 != p10 && p00 != p10 { emit(p00, p11, p10, insideC: inC, outsideC: outC, local: local) }
                }
            }
        } } }
        var mesh = Mesh(vertices: verts, triangles: tris)
        MeshOps.removeDegenerate(&mesh)
        return mesh
    }
}

// MARK: - Mesh operations

public enum MeshOps {
    /// Drops triangles that reference the same vertex twice or have (near) zero area.
    public static func removeDegenerate(_ m: inout Mesh) {
        var out: [UInt32] = []
        out.reserveCapacity(m.triangles.count)
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.triangles[t], b = m.triangles[t + 1], c = m.triangles[t + 2]
            if a == b || b == c || a == c { continue }
            out += [a, b, c]
        }
        m.triangles = out
    }

    /// Vertex → neighbour lists (CSR).
    static func adjacency(_ m: Mesh) -> (offsets: [Int], neighbours: [UInt32]) {
        let n = m.vertices.count
        var sets = [Set<UInt32>](repeating: [], count: n)
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.triangles[t], b = m.triangles[t + 1], c = m.triangles[t + 2]
            sets[Int(a)].insert(b); sets[Int(a)].insert(c)
            sets[Int(b)].insert(a); sets[Int(b)].insert(c)
            sets[Int(c)].insert(a); sets[Int(c)].insert(b)
        }
        var offsets = [0]
        var nb: [UInt32] = []
        for s in sets { nb.append(contentsOf: s); offsets.append(nb.count) }
        return (offsets, nb)
    }

    /// Taubin λ/μ smoothing: removes voxel stair-steps without shrinking the model.
    public static func taubinSmooth(_ m: inout Mesh, iterations: Int, lambda: Float = 0.5, mu: Float = -0.53) {
        guard iterations > 0, !m.vertices.isEmpty else { return }
        let (off, nb) = adjacency(m)
        var v = m.vertices
        var tmp = v
        for _ in 0 ..< iterations {
            for factor in [lambda, mu] {
                v.withUnsafeBufferPointer { src in
                    tmp.withUnsafeMutableBufferPointer { dst in
                        DispatchQueue.concurrentPerform(iterations: 16) { chunk in
                            let n = src.count
                            let lo = chunk * n / 16, hi = (chunk + 1) * n / 16
                            for i in lo ..< hi {
                                let s = off[i], e = off[i + 1]
                                if s == e { dst[i] = src[i]; continue }
                                var c = SIMD3<Float>.zero
                                for j in s ..< e { c += src[Int(nb[j])] }
                                c /= Float(e - s)
                                dst[i] = src[i] + factor * (c - src[i])
                            }
                        }
                    }
                }
                swap(&v, &tmp)
            }
        }
        m.vertices = v
    }

    /// Connected components of triangles (via shared vertices); returns component id per triangle and sizes.
    public static func components(_ m: Mesh) -> (ids: [Int32], sizes: [Int]) {
        var parent = Array(0 ..< m.vertices.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = find(Int(m.triangles[t])), b = find(Int(m.triangles[t + 1])), c = find(Int(m.triangles[t + 2]))
            parent[b] = a; parent[find(c)] = find(a)
        }
        var compOf: [Int: Int32] = [:]
        var ids: [Int32] = []
        var sizes: [Int] = []
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let r = find(Int(m.triangles[t]))
            let id: Int32
            if let e = compOf[r] { id = e } else { id = Int32(sizes.count); compOf[r] = id; sizes.append(0) }
            sizes[Int(id)] += 1
            ids.append(id)
        }
        return (ids, sizes)
    }

    /// Keeps only the largest connected piece (drops floating specks that would print as debris).
    public static func keepLargestComponent(_ m: inout Mesh) {
        let (ids, sizes) = components(m)
        guard sizes.count > 1, let best = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return }
        var tris: [UInt32] = []
        for (t, id) in ids.enumerated() where Int(id) == best {
            tris += [m.triangles[3 * t], m.triangles[3 * t + 1], m.triangles[3 * t + 2]]
        }
        m.triangles = tris
        compact(&m)
    }

    /// Drops connected pieces smaller than `fraction` of the largest piece (printing debris).
    public static func dropSmallComponents(_ m: inout Mesh, fraction: Double) {
        let (ids, sizes) = components(m)
        guard sizes.count > 1, let big = sizes.max() else { return }
        let keep = sizes.map { Double($0) >= Double(big) * fraction }
        var tris: [UInt32] = []
        for (t, id) in ids.enumerated() where keep[Int(id)] {
            tris += [m.triangles[3 * t], m.triangles[3 * t + 1], m.triangles[3 * t + 2]]
        }
        m.triangles = tris
        compact(&m)
    }

    /// Removes unreferenced vertices.
    public static func compact(_ m: inout Mesh) {
        var remap = [UInt32](repeating: .max, count: m.vertices.count)
        var verts: [SIMD3<Float>] = []
        for (k, i) in m.triangles.enumerated() {
            if remap[Int(i)] == .max { remap[Int(i)] = UInt32(verts.count); verts.append(m.vertices[Int(i)]) }
            m.triangles[k] = remap[Int(i)]
        }
        m.vertices = verts
    }

    /// Translates the mesh so its bounding box sits on z = 0, centred in x/y (convenient for slicers).
    public static func placeOnBuildPlate(_ m: inout Mesh) {
        guard let b = bounds(m) else { return }
        let shift = SIMD3<Float>(-(b.min.x + b.max.x) / 2, -(b.min.y + b.max.y) / 2, -b.min.z)
        for i in m.vertices.indices { m.vertices[i] += shift }
    }

    public static func scale(_ m: inout Mesh, by s: Float) {
        for i in m.vertices.indices { m.vertices[i] *= s }
    }

    /// Number of triangles a ray from `origin` along `dir` crosses (Möller–Trumbore).
    public static func rayHits(_ m: Mesh, from origin: SIMD3<Float>, dir: SIMD3<Float>) -> Int {
        var hits = 0
        let d = simd_normalize(dir)
        for t in Swift.stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.vertices[Int(m.triangles[t])], b = m.vertices[Int(m.triangles[t + 1])], c = m.vertices[Int(m.triangles[t + 2])]
            let e1 = b - a, e2 = c - a, h = simd_cross(d, e2), det = simd_dot(e1, h)
            if abs(det) < 1e-9 { continue }
            let f = 1 / det, s = origin - a, u = f * simd_dot(s, h)
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1), w = f * simd_dot(d, q)
            if w < 0 || u + w > 1 { continue }
            if f * simd_dot(e2, q) > 0 { hits += 1 }
        }
        return hits
    }

    /// Point-in-closed-mesh by ray parity (slightly skewed ray to avoid edge/vertex hits).
    public static func contains(_ m: Mesh, _ p: SIMD3<Float>) -> Bool {
        rayHits(m, from: p, dir: SIMD3<Float>(1, 0.000123, 0.000457)) % 2 == 1
    }

    public static func bounds(_ m: Mesh) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = m.vertices.first else { return nil }
        var hi = lo
        for v in m.vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }

    /// Converts DICOM patient LPS coordinates to RAS (x = right, y = anterior, z = superior), the frame
    /// most mesh tools expect. LPS → RAS is a 180° rotation about z, so the model is never mirrored.
    public static func lpsToPrintFrame(_ m: inout Mesh) {
        for i in m.vertices.indices { m.vertices[i] = SIMD3(-m.vertices[i].x, -m.vertices[i].y, m.vertices[i].z) }
    }
}

// MARK: - Validation

public enum MeshMetrics {
    /// Fraction of surface area whose face normal lies within `degrees` of ±one of `axes`.
    /// Voxel stair-steps show up as a large value; a smooth organic surface scores ≈ 5 % at 10°
    /// (the solid-angle share of six 10° caps for uniformly distributed normals).
    /// `excludeNearBoundsMM` skips faces within that distance of the bounding box (flat cuts made by the
    /// scan's field of view are genuinely flat and are not stair-steps).
    public static func axisAlignedFraction(_ m: Mesh, axes: [SIMD3<Float>], degrees: Float = 10, excludeNearBoundsMM: Float = 0) -> Double {
        let c = cos(degrees * .pi / 180)
        let bb = MeshOps.bounds(m)
        let units = axes.map { simd_normalize($0) }
        var aligned = 0.0, total = 0.0
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.vertices[Int(m.triangles[t])], b = m.vertices[Int(m.triangles[t + 1])], cc = m.vertices[Int(m.triangles[t + 2])]
            let n = simd_cross(b - a, cc - a)
            let area = Double(simd_length(n)) / 2
            guard area > 0 else { continue }
            let u = simd_normalize(n)
            if excludeNearBoundsMM > 0, let bb {
                let ctr = (a + b + cc) / 3
                let near = simd_min(ctr - bb.min, bb.max - ctr)
                if near.min() < excludeNearBoundsMM { continue }
            }
            total += area
            if units.contains(where: { abs(simd_dot($0, u)) >= c }) { aligned += area }
        }
        return total > 0 ? aligned / total : 0
    }
}

public struct MeshReport: CustomStringConvertible {
    public let vertices: Int
    public let triangles: Int
    public let boundaryEdges: Int        // edges used by exactly one triangle (holes)
    public let nonManifoldEdges: Int     // edges used by more than two triangles
    public let inconsistentEdges: Int    // edges traversed in the same direction twice (flipped faces)
    public let components: Int
    public let eulerCharacteristic: Int
    public let volumeMM3: Double         // signed; positive = outward-facing normals
    public let areaMM2: Double
    public let size: SIMD3<Float>

    public var isWatertight: Bool { boundaryEdges == 0 && nonManifoldEdges == 0 && inconsistentEdges == 0 }

    public var description: String {
        var s = "\(triangles) triangles, \(vertices) vertices, \(components) component(s)\n"
        s += String(format: "size %.1f x %.1f x %.1f mm, volume %.1f mL, area %.1f cm²\n",
                    size.x, size.y, size.z, volumeMM3 / 1000, areaMM2 / 100)
        s += "watertight: \(isWatertight ? "yes" : "NO") (boundary edges \(boundaryEdges), non-manifold \(nonManifoldEdges), "
        s += "inconsistent \(inconsistentEdges)); Euler characteristic \(eulerCharacteristic)"
        return s
    }

    public static func analyze(_ m: Mesh) -> MeshReport {
        var directed: [UInt64: Int32] = [:]
        directed.reserveCapacity(m.triangles.count)
        var vol = 0.0, area = 0.0
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let ids = [m.triangles[t], m.triangles[t + 1], m.triangles[t + 2]]
            for k in 0 ..< 3 {
                let a = UInt64(ids[k]), b = UInt64(ids[(k + 1) % 3])
                directed[a << 32 | b, default: 0] += 1
            }
            let p0 = SIMD3<Double>(m.vertices[Int(ids[0])]), p1 = SIMD3<Double>(m.vertices[Int(ids[1])]), p2 = SIMD3<Double>(m.vertices[Int(ids[2])])
            vol += simd_dot(p0, simd_cross(p1, p2)) / 6
            area += simd_length(simd_cross(p1 - p0, p2 - p0)) / 2
        }
        var boundary = 0, nonManifold = 0, inconsistent = 0, undirected = 0
        for (key, n) in directed {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            let rev = directed[b << 32 | a] ?? 0
            if n > 1 { inconsistent += 1 }
            if a < b || rev == 0 {
                undirected += 1
                let total = Int(n) + Int(rev)
                if total == 1 { boundary += 1 } else if total > 2 { nonManifold += 1 }
            }
        }
        let comps = MeshOps.components(m).sizes.count
        let size = MeshOps.bounds(m).map { $0.max - $0.min } ?? .zero
        return MeshReport(vertices: m.vertices.count, triangles: m.triangleCount, boundaryEdges: boundary,
                          nonManifoldEdges: nonManifold, inconsistentEdges: inconsistent, components: comps,
                          eulerCharacteristic: m.vertices.count - undirected + m.triangleCount,
                          volumeMM3: vol, areaMM2: area, size: size)
    }
}

// MARK: - Export

public enum STL {
    /// Writes a binary STL (units: mm).
    public static func write(_ m: Mesh, to url: URL, header: String = "mri-viewer mesh (mm)") throws {
        var d = Data(capacity: 84 + m.triangleCount * 50)
        var h = Array(header.utf8.prefix(80))
        h += [UInt8](repeating: 0, count: 80 - h.count)
        d.append(contentsOf: h)
        var n = UInt32(m.triangleCount).littleEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        func put(_ v: SIMD3<Float>) {
            for c in [v.x, v.y, v.z] { var b = c.bitPattern.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        }
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = m.vertices[Int(m.triangles[t])], b = m.vertices[Int(m.triangles[t + 1])], c = m.vertices[Int(m.triangles[t + 2])]
            let nrm = simd_cross(b - a, c - a)
            let len = simd_length(nrm)
            put(len > 0 ? nrm / len : .zero)
            put(a); put(b); put(c)
            d.append(contentsOf: [0, 0])
        }
        try d.write(to: url, options: .atomic)
    }

    /// Reads a binary STL back (used by tests and `mritool check-stl`).
    public static func read(_ url: URL) throws -> Mesh {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count >= 84 else { throw DICOMError.truncated(at: d.count) }
        func u32(_ i: Int) -> UInt32 { UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24 }
        func f32(_ i: Int) -> Float { Float(bitPattern: u32(i)) }
        let n = Int(u32(80))
        guard d.count >= 84 + n * 50 else { throw DICOMError.truncated(at: d.count) }
        var map: [SIMD3<Float>: UInt32] = [:]
        var m = Mesh()
        for t in 0 ..< n {
            let o = 84 + t * 50 + 12
            for k in 0 ..< 3 {
                let p = SIMD3(f32(o + 12 * k), f32(o + 12 * k + 4), f32(o + 12 * k + 8))
                if let i = map[p] { m.triangles.append(i) } else {
                    let i = UInt32(m.vertices.count); map[p] = i; m.vertices.append(p); m.triangles.append(i)
                }
            }
        }
        return m
    }
}
